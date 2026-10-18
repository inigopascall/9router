#!/usr/bin/env bash
# update.sh: update the 9router fork to the latest upstream 9router release. See README.md.
#
# Usage: update.sh [--check]
#   --check  read-only: fetch the release tags from upstream, and print the release the fork is
#            based on, the latest upstream release, and whether the fork's commits rebase cleanly
#            onto it (tried in a temporary git worktree, removed afterwards).
#   (none)   rebase the fork's commits onto the latest release, build and test it, and swap the new
#            build in for FORK_APP; if it is not healthy, put the previous build and the data back.
#            From a shell it runs itself in the transient systemd user unit
#            9router-update-<timestamp> and follows it, as cutover.sh does.
# Settings, from the environment, as for cutover.sh: UNIT, DATA, PORT, FORK_APP, HEALTH_TIMEOUT,
# PORT_FREE_TIMEOUT. Also:
#   FORCE=1       rebuild and swap even when the fork is already on the latest release
#   UPDATE_WORK   DATA_DIR and HOME for the build and the tests
#                 (default /home/inigo/.local/state/9router-fork/work)
# Exit status: 0 done, or already up to date; 1 the build or the tests failed and nothing was
# swapped, or the new build was not healthy and the previous one was put back; 2 refused, or the
# rebase conflicts: nothing was changed. With --check: 0 up to date or rebases cleanly, 1 conflicts.
set -Eeuo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
FORCE=${FORCE:-0}
UPDATE_WORK=${UPDATE_WORK:-$STATE_DIR/work}
UPDATE_WORK=${UPDATE_WORK%/}
REPO=$(cd "$ZBOOK_DIR/.." && pwd)
BRANCH=otterly-provider
FORWARD_VARS="UNIT DATA PORT FORK_APP OVERRIDE_ENV HEALTH_TIMEOUT PORT_FREE_TIMEOUT FORCE UPDATE_WORK"

usage() { echo "usage: $0 [--check]" >&2; exit 2; }
g() { git -C "$REPO" "$@"; }
app_version() { jq -r '.version // "unknown"' "$1/package.json" 2>/dev/null || echo unknown; }
fetch_tags() { log "fetching the release tags from upstream"; g fetch -q upstream 'refs/tags/v*:refs/tags/v*'; }
# The release the branch is based on, and the latest upstream release (x.y.z only).
base_tag() { g describe --tags --abbrev=0 --match 'v[0-9]*' "$BRANCH"; }
latest_tag() { g tag -l 'v[0-9]*' --sort=-v:refname | grep -xE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p; }

check() {
  local base latest n tmp conflicts rc=0
  fetch_tags
  base=$(base_tag)
  latest=$(latest_tag)
  n=$(g rev-list --count "$base..$BRANCH")
  echo "fork branch:             $BRANCH at $(g rev-parse --short "$BRANCH"): $base + $n commits"
  echo "deployed fork build:     version $(app_version "$FORK_APP") at $FORK_APP"
  echo "latest upstream release: $latest"
  if [ "$base" = "$latest" ]; then
    echo "result: already on the latest release; update.sh has nothing to do (FORCE=1 rebuilds and swaps anyway)"
    return 0
  fi
  tmp=$(mktemp -d "$XDG_RUNTIME_DIR/9router-update-check.XXXXXX")
  g worktree add -q --detach "$tmp/wt" "$BRANCH"
  if git -C "$tmp/wt" rebase -q --onto "$latest" "$base" >"$tmp/rebase.out" 2>&1; then
    echo "result: the $n commits rebase cleanly onto $latest; update.sh would update to it"
  else
    conflicts=$(git -C "$tmp/wt" diff --name-only --diff-filter=U | tr '\n' ' ')
    git -C "$tmp/wt" rebase --abort >/dev/null 2>&1 || true
    echo "result: the $n commits do NOT rebase cleanly onto $latest; conflicts in: ${conflicts:-see below}"
    sed 's/^/  /' "$tmp/rebase.out"
    rc=1
  fi
  g worktree remove --force "$tmp/wt"
  rm -rf "$tmp"
  return $rc
}

case $# in
  0) ;;
  1) [ "$1" = --check ] || usage; check; exit 0 ;;
  *) usage ;;
esac

start_in_unit update
unit_io_setup
TS=$(date +%Y%m%d-%H%M%S)
refuse() { log "REFUSED: $*"; log "nothing was changed"; exit 2; }

log "update of the fork that $UNIT runs (data $DATA, port $PORT, build $FORK_APP), from $REPO"

# 1. Refuse unless the repository is clean and on the branch, and the unit runs the fork.
[ "$(g rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || refuse "$REPO is not on the branch $BRANCH"
[ -z "$(g status --porcelain)" ] || refuse "$REPO has uncommitted changes"
DROPINS=$(systemctl --user show -p DropInPaths --value "$UNIT")
[[ " $DROPINS " == *" $DROPIN "* ]] || refuse "$UNIT does not run the fork: the drop-in $DROPIN is not installed (cutover.sh installs it)"
[ -f "$FORK_APP/custom-server.js" ] || refuse "missing $FORK_APP/custom-server.js"
[ -d "$DATA" ] || refuse "no data directory $DATA"
[ ! -e "$DATA.pre-update-$TS" ] || refuse "$DATA.pre-update-$TS already exists"

# 2. The releases.
fetch_tags
BASE=$(base_tag)
LATEST=$(latest_tag)
TIP=$(g rev-parse --short HEAD)
VER_BEFORE=$(app_version "$FORK_APP")
log "the fork is $BASE + $(g rev-list --count "$BASE..HEAD") commits ($TIP), build version $VER_BEFORE; the latest upstream release is $LATEST"
if [ "$BASE" = "$LATEST" ] && [ "$FORCE" != 1 ]; then
  log "already on the latest release; nothing to do (FORCE=1 rebuilds and swaps anyway)"
  exit 0
fi

# 3. Tag the branch tip, and rebase the fork's commits onto the latest release.
PRE_TAG="pre-update-$TS"
g tag "$PRE_TAG" HEAD
log "tagged the branch tip $TIP as $PRE_TAG"
if [ "$BASE" = "$LATEST" ]; then
  log "already on $LATEST: no rebase (FORCE=1)"
elif g rebase -q --onto "$LATEST" "$BASE" "$BRANCH"; then
  log "rebased onto $LATEST: $BRANCH is now at $(g rev-parse --short HEAD)"
else
  CONFLICTS=$(g diff --name-only --diff-filter=U | tr '\n' ' ')
  g rebase --abort || true
  g reset -q --hard "$PRE_TAG"
  g tag -d "$PRE_TAG" >/dev/null
  log "the rebase onto $LATEST conflicts in: ${CONFLICTS:-see above}"
  log "nothing was changed: the rebase was aborted and $BRANCH is back at $TIP"
  exit 2
fi
REPO_NOTE="$REPO is now on $LATEST ($BRANCH at $(g rev-parse --short HEAD)). To put it back: git -C $REPO reset --hard $PRE_TAG"
build_fail() { log "FAILED before the swap: $*"; log "$UNIT, $FORK_APP and $DATA were not changed"; log "$REPO_NOTE"; exit 1; }

# 4. Build and test, with DATA_DIR and HOME in UPDATE_WORK.
mkdir -p "$UPDATE_WORK/build-data" "$UPDATE_WORK/build-home"
BENV=(env "DATA_DIR=$UPDATE_WORK/build-data" "HOME=$UPDATE_WORK/build-home" NEXT_TELEMETRY_DISABLED=1 nice -n 10)
log "npm install"
(cd "$REPO" && "${BENV[@]}" npm install --no-audit --no-fund) || build_fail "npm install"
log "npm run build"
(cd "$REPO" && "${BENV[@]}" npm run build) || build_fail "npm run build"
log "the Otterly unit tests"
(cd "$REPO/tests" && "${BENV[@]}" npm install --legacy-peer-deps --no-audit --no-fund) || build_fail "npm install in tests/"
(cd "$REPO/tests" && "${BENV[@]}" ./node_modules/.bin/vitest run --config ./vitest.config.js unit/otterly-provider.test.js unit/zbook-fork-update-notice.test.js) || build_fail "the Otterly unit tests"
for f in verify-alias verify-oauth-urls verify-providers; do
  log "tests/__baseline__/$f.mjs"
  (cd "$REPO" && "${BENV[@]}" node "tests/__baseline__/$f.mjs") || build_fail "tests/__baseline__/$f.mjs"
done
[ -z "$(g status --porcelain)" ] || build_fail "the build or the tests changed files in $REPO: $(g status --porcelain | tr '\n' ' ')"

# 5. Copy the standalone build beside the running one.
rm -rf "$FORK_APP.new"
mkdir -p "$FORK_APP.new"
rsync -a --delete "$REPO/.next/standalone/" "$FORK_APP.new/" || build_fail "copying the build to $FORK_APP.new"
[ -f "$FORK_APP.new/custom-server.js" ] && [ -f "$FORK_APP.new/server.js" ] || build_fail "the build in $FORK_APP.new has no custom-server.js or server.js"
VER_NEW=$(app_version "$FORK_APP.new")
log "new build: version $VER_NEW at $FORK_APP.new"
rm -rf "$FORK_APP.prev"

# 6. The swap. From the stop until the new build is healthy, any failure, error or signal puts the
#    previous build back, and the data as it was before the update once the new build has run.
DATA_BACKUP="$DATA.pre-update-$TS"
STAGE=0   # 1 stopped, 2 data backed up, 3 FORK_APP moved to .prev, 4 the new build is FORK_APP
put_back() {
  trap '' INT TERM HUP
  trap - ERR
  log "$1: putting the previous build back"
  systemctl --user stop "$UNIT" || true
  if [ "$STAGE" -ge 4 ]; then
    mv "$FORK_APP" "$FORK_APP.failed-$TS" && log "moved the new build aside to $FORK_APP.failed-$TS" || log "could not move $FORK_APP aside"
  fi
  if [ "$STAGE" -ge 3 ] && [ ! -e "$FORK_APP" ]; then
    mv "$FORK_APP.prev" "$FORK_APP" && log "put $FORK_APP.prev back at $FORK_APP" || log "could not move $FORK_APP.prev back"
  fi
  if [ "$STAGE" -ge 4 ]; then
    if mv "$DATA" "$DATA.failed-update-$TS" && cp -a "$DATA_BACKUP" "$DATA"; then
      log "moved $DATA aside to $DATA.failed-update-$TS and restored $DATA_BACKUP"
    else
      log "could not restore $DATA_BACKUP to $DATA"
    fi
  fi
  if ! wait_port_free; then
    log "$UNIT is STOPPED: the programs above still hold port $PORT. Restarting them (for example AiderDesk) frees it; then: systemctl --user start $UNIT"
    log "$REPO_NOTE"
    exit 1
  fi
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  systemctl --user start "$UNIT" || log "start reported an error; the health check decides"
  if wait_healthy fork; then
    log "the previous build (version $VER_BEFORE) is running again$([ "$STAGE" -ge 4 ] && echo ", on the data as it was before the update")"
  else
    log "PUTTING BACK FAILED: $UNIT is not healthy. To return to the npm package: UNIT=$UNIT DATA=$DATA PORT=$PORT FORK_APP=$FORK_APP $ZBOOK_DIR/rollback.sh"
  fi
  log "$REPO_NOTE"
  exit 1
}
trap 'put_back "error at line $LINENO"' ERR
trap 'put_back "interrupted by SIGTERM"' TERM
trap 'put_back "interrupted by SIGINT"' INT
trap 'put_back "interrupted by SIGHUP"' HUP
STAGE=1
log "stopping $UNIT"
systemctl --user stop "$UNIT"
cp -a "$DATA" "$DATA_BACKUP"
STAGE=2
log "backup: $DATA_BACKUP"
mv "$FORK_APP" "$FORK_APP.prev"
STAGE=3
mv "$FORK_APP.new" "$FORK_APP"
STAGE=4
log "swapped: the previous build is at $FORK_APP.prev, the new one at $FORK_APP"
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
log "starting $UNIT on the new build"
systemctl --user start "$UNIT" || log "start reported an error; the health check decides"
wait_healthy fork || put_back "health check failed"
trap - ERR INT TERM HUP

# 7. The summary.
echo
echo "Update succeeded: version $VER_BEFORE ($BASE, $TIP) -> version $VER_NEW ($LATEST, $(g rev-parse --short HEAD))"
echo "Backup of the data directory: $DATA_BACKUP"
echo "The previous build: $FORK_APP.prev"
echo "Undo: systemctl --user stop $UNIT && mv $FORK_APP $FORK_APP.undone-$TS && mv $FORK_APP.prev $FORK_APP && mv $DATA $DATA.undone-$TS && cp -a $DATA_BACKUP $DATA && systemctl --user start $UNIT && git -C $REPO reset --hard $PRE_TAG"

#!/usr/bin/env bash
# cutover.sh: switch a 9router systemd user unit (by default the live nine-router.service) to the
# 9router fork with the otterly provider. See README.md.
#
# Settings, from the environment (the defaults are the live targets):
#   UNIT=nine-router.service   DATA=/home/inigo/.9router   PORT=20128
#   FORK_APP=/home/inigo/.local/share/9router-fork/app
#   OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env   HEALTH_TIMEOUT=90
#   SKIP_OTTERLY_CHECK=1   skip the check that otterly@acct1 and otterly@acct2 are up and logged in
#   ALIASES="claude-opus-5-5 claude-fable-5-1"   the model ids in the printed alias commands
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SKIP_OTTERLY_CHECK=${SKIP_OTTERLY_CHECK:-0}
ALIASES=${ALIASES:-claude-opus-5-5 claude-fable-5-1}
JAR="$XDG_RUNTIME_DIR/9router-session.jar"

preflight_fail() { log "PREFLIGHT FAILED: $*"; log "nothing was changed"; exit 2; }

log "cutover of $UNIT (data $DATA, port $PORT) to the fork at $FORK_APP"

# 1. Preflight. Read-only: a failure stops the script before anything is touched.
systemctl --user cat "$UNIT" >/dev/null 2>&1 || preflight_fail "no unit $UNIT"
[ -d "$DATA" ] || preflight_fail "no data directory $DATA"
[ -f "$FORK_APP/custom-server.js" ] || preflight_fail "missing $FORK_APP/custom-server.js"
[ -f "$FORK_APP/server.js" ] || preflight_fail "missing $FORK_APP/server.js"
[ -f "$DROPIN_SRC" ] || preflight_fail "missing drop-in source $DROPIN_SRC"
[ ! -e "$DROPIN" ] || preflight_fail "a drop-in is already installed: $DROPIN"
[ -f "$OVERRIDE_ENV" ] || preflight_fail "missing $OVERRIDE_ENV"
grep -qx "PORT=$PORT" "$OVERRIDE_ENV" || preflight_fail "$OVERRIDE_ENV does not set PORT=$PORT"
grep -qx "HOSTNAME=127.0.0.1" "$OVERRIDE_ENV" || preflight_fail "$OVERRIDE_ENV does not set HOSTNAME=127.0.0.1"
if [ "$SKIP_OTTERLY_CHECK" = 1 ]; then
  log "preflight: Otterly check skipped (SKIP_OTTERLY_CHECK=1)"
else
  for acct in acct1 acct2; do
    systemctl --user is-active --quiet "otterly@$acct.service" || preflight_fail "otterly@$acct.service is not active"
    envf="$HOME/.config/otterly/$acct.env"
    [ -f "$envf" ] || preflight_fail "missing $envf"
    oport=$(sed -n 's/^OTTERLY_PORT=//p' "$envf")
    email=$(curl -s -m 15 "http://127.0.0.1:$oport/api/quota" | jq -r '.otterly.account.email // empty' 2>/dev/null || true)
    [ -n "$email" ] || preflight_fail "otterly@$acct (port $oport): /api/quota has no otterly.account.email; is the account logged in?"
    log "preflight: otterly@$acct on port $oport is logged in as $email"
  done
fi
log "preflight passed"

# 2. Stop the unit.
log "stopping $UNIT"
systemctl --user stop "$UNIT"

# 3. Back up the data directory while nothing writes to it.
BACKUP="$DATA.pre-fork-$(date +%Y%m%d-%H%M%S)"
if [ -e "$BACKUP" ] || ! cp -a "$DATA" "$BACKUP"; then
  log "backup to $BACKUP failed; starting $UNIT again unchanged"
  systemctl --user start "$UNIT"
  exit 1
fi
log "backup: $BACKUP"
UNDO="UNIT=$UNIT DATA=$DATA PORT=$PORT FORK_APP=$FORK_APP $ZBOOK_DIR/rollback.sh --restore $BACKUP"
trap 'log "unexpected error at line $LINENO; $UNIT may be stopped. To undo: $UNDO"' ERR

# 4. Install the drop-in, with this run's port, fork directory and override file, and start.
mkdir -p "$DROPIN_DIR"
sed -e "s|^Environment=PORT=20128\$|Environment=PORT=$PORT|" \
    -e "s|/home/inigo/.local/share/9router-fork/app|$FORK_APP|g" \
    -e "s|^EnvironmentFile=/home/inigo/.config/9router-fork/override.env\$|EnvironmentFile=$OVERRIDE_ENV|" \
    "$DROPIN_SRC" > "$DROPIN"
log "installed $DROPIN"
systemctl --user daemon-reload
log "starting $UNIT on the fork"
systemctl --user start "$UNIT" || log "start reported an error; the health check decides"

# 5. Health check. 6. If it fails, roll back to the backup and fail.
if ! wait_healthy fork; then
  log "health check failed: rolling back"
  trap - ERR
  "$ZBOOK_DIR/rollback.sh" --restore "$BACKUP" || log "ROLLBACK FAILED as well: see above"
  exit 1
fi

# 7. Success.
log "cutover succeeded"
if [ "$UNIT" = nine-router.service ]; then
  systemctl --user enable otterly@acct1.service otterly@acct2.service
  log "enabled otterly@acct1.service and otterly@acct2.service"
  if systemctl --user cat nine-router-staging.service >/dev/null 2>&1; then
    systemctl --user stop nine-router-staging.service
    systemctl --user disable nine-router-staging.service
    log "stopped and disabled nine-router-staging.service"
  fi
fi
trap - ERR

cat <<EOF

Backup of the data directory: $BACKUP

Next, in the 9router dashboard (http://127.0.0.1:$PORT/dashboard): Providers, "Otterly (Claude)",
add two connections:
  1. name "Claude account 1 (Otterly :11445)", base URL http://127.0.0.1:11445/v1, priority 1
  2. name "Claude account 2 (Otterly :11446)", base URL http://127.0.0.1:11446/v1, priority 2
  The API key field must be filled in but is not used: enter anything, e.g. unused.

So that clients can go on sending bare model ids, give each id an alias that points at otterly/<id>.
The alias API needs a dashboard session. Log in with the dashboard password:
  read -rsp 'dashboard password: ' PW; echo
  printf '%s' "\$PW" | jq -Rs '{password: .}' | curl -s -c $JAR -X POST http://127.0.0.1:$PORT/api/auth/login -H 'Content-Type: application/json' -d @-; unset PW
then set the aliases:
EOF
for id in $ALIASES; do
  echo "  curl -s -b $JAR -X PUT http://127.0.0.1:$PORT/api/models/alias -H 'Content-Type: application/json' -d '{\"model\":\"otterly/$id\",\"alias\":\"$id\"}'"
done
cat <<EOF
and remove the session: rm $JAR

Undo: stops $UNIT, removes the drop-in, puts this backup back and starts the original ExecStart.
Changes made since the cutover are lost; leave out --restore to keep the data as it is now.
  $UNDO
EOF

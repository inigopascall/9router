#!/usr/bin/env bash
# cutover.sh: switch a 9router systemd user unit (by default the live nine-router.service) to the
# 9router fork with the otterly provider. See README.md.
#
# From a shell, the script runs itself in the transient systemd user unit 9router-cutover-<timestamp>
# and follows its output, so a closed terminal or Ctrl+C cannot cut it short. The output is also
# appended to /home/inigo/.local/state/9router-fork/<unit>.log. From the moment the unit is stopped
# until the fork passes its health check, any error, SIGTERM, SIGINT or SIGHUP runs rollback.sh
# (with --restore once the backup exists) and the script exits 1.
#
# Settings, from the environment (the defaults are the live targets):
#   UNIT=nine-router.service   DATA=/home/inigo/.9router   PORT=20128
#   FORK_APP=/home/inigo/.local/share/9router-fork/app
#   OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env
#   HEALTH_TIMEOUT=120   PORT_FREE_TIMEOUT=30
#   SKIP_OTTERLY_CHECK=1   skip the check that otterly@airship and otterly@iwd are up and logged in
# Exit status: 0 done; 1 the cutover failed and was rolled back (the output says whether the
# rollback succeeded); 2 preflight failed, nothing was changed.
set -Eeuo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SKIP_OTTERLY_CHECK=${SKIP_OTTERLY_CHECK:-0}
FORWARD_VARS="UNIT DATA PORT FORK_APP OVERRIDE_ENV HEALTH_TIMEOUT PORT_FREE_TIMEOUT SKIP_OTTERLY_CHECK"
[ $# = 0 ] || { echo "usage: $0" >&2; exit 2; }
start_in_unit cutover
unit_io_setup

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
  for acct in airship iwd; do
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

# From the stop until the health check passes, any error or signal rolls back: with --restore once
# the backup is complete; before that the data is unchanged, and rollback.sh starts the original on it.
BACKUP=""
BACKUP_OK=0
roll_back() {
  trap '' INT TERM HUP
  trap - ERR
  log "$1: rolling back, so that $UNIT does not stay stopped"
  if [ "$BACKUP_OK" = 1 ]; then
    "$ZBOOK_DIR/rollback.sh" --restore "$BACKUP" || log "ROLLBACK FAILED as well: see above"
  else
    "$ZBOOK_DIR/rollback.sh" || log "ROLLBACK FAILED as well: see above"
  fi
  exit 1
}
trap 'roll_back "error at line $LINENO"' ERR
trap 'roll_back "interrupted by SIGTERM"' TERM
trap 'roll_back "interrupted by SIGINT"' INT
trap 'roll_back "interrupted by SIGHUP"' HUP

# 2. Stop the unit.
log "stopping $UNIT"
systemctl --user stop "$UNIT"

# 3. Back up the data directory while nothing writes to it.
BACKUP="$DATA.pre-fork-$(date +%Y%m%d-%H%M%S)"
[ ! -e "$BACKUP" ] || roll_back "the backup directory $BACKUP already exists"
cp -a "$DATA" "$BACKUP" || roll_back "the backup to $BACKUP failed"
BACKUP_OK=1
log "backup: $BACKUP"
UNDO="UNIT=$UNIT DATA=$DATA PORT=$PORT FORK_APP=$FORK_APP $ZBOOK_DIR/rollback.sh --restore $BACKUP"

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

# 5. Health check. If it fails, roll back to the backup and fail.
wait_healthy fork || roll_back "health check failed"
trap - ERR INT TERM HUP
log "cutover succeeded"

# 6. For the live unit: the Otterly units start at boot, and the staging instance is stopped.
if [ "$UNIT" = nine-router.service ]; then
  systemctl --user enable otterly@airship.service otterly@iwd.service && log "enabled otterly@airship.service and otterly@iwd.service" || log "could not enable otterly@airship.service and otterly@iwd.service"
  if systemctl --user cat nine-router-staging.service >/dev/null 2>&1; then
    systemctl --user stop nine-router-staging.service && systemctl --user disable nine-router-staging.service && log "stopped and disabled nine-router-staging.service" || log "could not stop and disable nine-router-staging.service"
  fi
fi

# 7. The summary.
echo
echo "Backup of the data directory: $BACKUP"
echo "Next, add the two Otterly connections in the dashboard, http://127.0.0.1:$PORT/dashboard: Providers → \"Otterly (Claude)\" → add a connection with the base URL $AIRSHIP_URL, and another with $IWD_URL. Any text will do as the API key. The priority sets the order: the lowest number is tried first."
echo "9router knows these models as otterly/<id>, for example otterly/claude-opus-5-5. In AiderDesk, either use those names, or give each id the alias <id> -> otterly/<id>. The dashboard has no page that sets model aliases; configure.sh sets them, and adds either connection if it is missing: $(configure_cmd)"
if [ "$UNIT" = nine-router.service ]; then
  echo "In AiderDesk, edit the provider otterly-claude: set its base URL to http://127.0.0.1:20128/v1 and its API key to the 9router API key your 9router provider uses. To go back, set the base URL to http://localhost:11435/v1."
fi
echo "Undo: $UNDO"

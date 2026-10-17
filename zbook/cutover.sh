#!/usr/bin/env bash
# cutover.sh: switch a 9router systemd user unit (by default the live nine-router.service) to the
# 9router fork with the otterly provider. See README.md.
#
# Settings, from the environment (the defaults are the live targets):
#   UNIT=nine-router.service   DATA=/home/inigo/.9router   PORT=20128
#   FORK_APP=/home/inigo/.local/share/9router-fork/app
#   OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env   HEALTH_TIMEOUT=90
#   SKIP_OTTERLY_CHECK=1   skip the check that otterly@airship and otterly@iwd are up and logged in
#   SKIP_CONFIGURE=1       do not run configure.sh after the cutover
#   AIRSHIP_URL, IWD_URL, ALIASES, DASHBOARD_PASSWORD_FILE   passed on to configure.sh; see there
# Exit status: 0 done; 1 the cutover failed (and was rolled back) or the backup failed; 2 preflight
# failed, nothing was changed; 3 the fork is running, but configure.sh failed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SKIP_OTTERLY_CHECK=${SKIP_OTTERLY_CHECK:-0}
SKIP_CONFIGURE=${SKIP_CONFIGURE:-0}

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
log "cutover succeeded"

# 7. Configure the otterly connections and the model aliases. If that fails, the fork keeps running.
CONFIGURE_RC=0
if [ "$SKIP_CONFIGURE" = 1 ]; then
  CONFIGURE_OUTCOME="skipped (SKIP_CONFIGURE=1). To run it: $(configure_cmd)"
  log "configure.sh skipped (SKIP_CONFIGURE=1)"
else
  log "running configure.sh"
  if "$ZBOOK_DIR/configure.sh"; then
    CONFIGURE_OUTCOME="succeeded"
  else
    CONFIGURE_RC=$?
    CONFIGURE_OUTCOME="FAILED (exit $CONFIGURE_RC). The fork is running; nothing was rolled back. To run it again: $(configure_cmd)"
    log "configure.sh failed (exit $CONFIGURE_RC); the fork stays running"
  fi
fi

# 8. For the live unit: the Otterly units start at boot, and the staging instance is stopped.
if [ "$UNIT" = nine-router.service ]; then
  systemctl --user enable otterly@airship.service otterly@iwd.service
  log "enabled otterly@airship.service and otterly@iwd.service"
  if systemctl --user cat nine-router-staging.service >/dev/null 2>&1; then
    systemctl --user stop nine-router-staging.service
    systemctl --user disable nine-router-staging.service
    log "stopped and disabled nine-router-staging.service"
  fi
fi
trap - ERR

# 9. The summary.
echo
echo "Backup of the data directory: $BACKUP"
echo "configure.sh: $CONFIGURE_OUTCOME"
if [ "$UNIT" = nine-router.service ]; then
  echo "In AiderDesk, edit the provider otterly-claude: set its base URL to http://127.0.0.1:20128/v1 and its API key to the 9router API key your 9router provider uses. To go back, set the base URL to http://localhost:11435/v1."
fi
echo "Undo: $UNDO"
[ "$CONFIGURE_RC" = 0 ] || exit 3

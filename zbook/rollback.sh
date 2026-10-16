#!/usr/bin/env bash
# rollback.sh: return a 9router systemd user unit (by default the live nine-router.service) from the
# 9router fork to its own ExecStart (for the live unit, the npm package). See README.md.
#
# Usage: rollback.sh [--restore <backup dir>]
#   --restore  move the data directory aside to <DATA>.failed-fork-<timestamp> and copy the backup
#              made by cutover.sh into its place
# Settings, from the environment, as for cutover.sh: UNIT, DATA, PORT, FORK_APP, HEALTH_TIMEOUT.
# The Otterly units are left as they are.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { echo "usage: $0 [--restore <backup dir>]" >&2; exit 2; }
RESTORE=""
case $# in
  0) ;;
  2) [ "$1" = --restore ] || usage; RESTORE=${2%/} ;;
  *) usage ;;
esac
if [ -n "$RESTORE" ]; then
  [ -d "$RESTORE" ] || { log "no backup directory $RESTORE; nothing was changed"; exit 2; }
  [ "$(readlink -f "$RESTORE")" != "$(readlink -f "$DATA")" ] || { log "$RESTORE is the data directory itself; nothing was changed"; exit 2; }
fi

log "rollback of $UNIT (data $DATA, port $PORT)${RESTORE:+, restoring $RESTORE}"

# 1. Stop the unit, remove the drop-in, reload.
systemctl --user stop "$UNIT"
if [ -e "$DROPIN" ]; then
  rm -f "$DROPIN"
  log "removed $DROPIN"
else
  log "no drop-in at $DROPIN"
fi
rmdir "$DROPIN_DIR" 2>/dev/null || true
systemctl --user daemon-reload

# 2. With --restore: move the data aside and put the backup in its place.
if [ -n "$RESTORE" ]; then
  if [ -e "$DATA" ]; then
    FAILED="$DATA.failed-fork-$(date +%Y%m%d-%H%M%S)"
    mv "$DATA" "$FAILED"
    log "moved $DATA aside to $FAILED"
  fi
  cp -a "$RESTORE" "$DATA"
  log "restored $RESTORE to $DATA"
fi

# 3. Start the original and check it.
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
log "starting $UNIT"
systemctl --user start "$UNIT" || log "start reported an error; the health check decides"
if ! wait_healthy original; then
  log "ROLLBACK FAILED: $UNIT is not healthy"
  exit 1
fi
log "rollback succeeded"

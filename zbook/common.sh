# Settings and the health check shared by cutover.sh and rollback.sh. Sourced, not run.
# Every setting can be overridden from the environment; the defaults are the live targets.
UNIT=${UNIT:-nine-router.service}
DATA=${DATA:-/home/inigo/.9router}
DATA=${DATA%/}
PORT=${PORT:-20128}
FORK_APP=${FORK_APP:-/home/inigo/.local/share/9router-fork/app}
FORK_APP=${FORK_APP%/}
OVERRIDE_ENV=${OVERRIDE_ENV:-/home/inigo/.config/9router-fork/override.env}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-90}
export UNIT DATA PORT FORK_APP OVERRIDE_ENV HEALTH_TIMEOUT
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

ZBOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DROPIN_SRC="$ZBOOK_DIR/nine-router.service.d/otterly-fork.conf"
DROPIN_DIR="$HOME/.config/systemd/user/$UNIT.d"
DROPIN="$DROPIN_DIR/otterly-fork.conf"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# The argv and the pid of the unit's current ExecStart record.
exec_argv() { systemctl --user show -p ExecStart --value "$UNIT" | sed -n 's/.* argv[[][]]=\(.*\) ; ignore_errors=.*/\1/p' | head -n 1; }
exec_pid() { systemctl --user show -p ExecStart --value "$UNIT" | sed -n 's/.* ; pid=\([0-9]*\) ;.*/\1/p' | head -n 1; }

# wait_healthy fork|original
# Healthy: within HEALTH_TIMEOUT seconds, GET http://127.0.0.1:$PORT/v1/models returns 200 and the
# unit's main process is the expected program. A Next.js server renames its own process to
# "next-server (vX)", so /proc/<pid>/cmdline no longer shows the script it was started with. The
# check therefore reads the unit's ExecStart record and the main process's working directory, which
# the server sets to its own app directory. The record's pid= must be the unit's MainPID; a
# daemon-reload resets it to 0, and 0 is accepted.
#   fork:     the ExecStart runs $FORK_APP/custom-server.js and the working directory is $FORK_APP
#   original: neither refers to $FORK_APP
wait_healthy() {
  local want=$1 deadline code main argv epid cwd fork_real ok
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  fork_real=$(readlink -f "$FORK_APP" || echo "$FORK_APP")
  while :; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" || true)
    main=$(systemctl --user show -p MainPID --value "$UNIT")
    argv=$(exec_argv)
    epid=$(exec_pid)
    cwd=$(readlink "/proc/$main/cwd" 2>/dev/null || true)
    ok=0
    if [ "$code" = 200 ] && [ "${main:-0}" != 0 ] && { [ "${epid:-0}" = 0 ] || [ "$epid" = "$main" ]; }; then
      case $want in
        fork) if [[ $argv == *"$FORK_APP/custom-server.js"* && $cwd == "$fork_real" ]]; then ok=1; fi ;;
        original) if [[ $argv != *"$FORK_APP"* && $cwd != "$fork_real" ]]; then ok=1; fi ;;
      esac
    fi
    if [ "$ok" = 1 ]; then
      log "healthy ($want): GET /v1/models HTTP $code, MainPID $main"
      log "  ExecStart argv: $argv"
      log "  main process cwd: $cwd"
      log "  main process cmdline: $(tr '\0' ' ' 2>/dev/null < "/proc/$main/cmdline" | sed 's/ *$//')"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "NOT healthy ($want) after ${HEALTH_TIMEOUT}s: GET /v1/models HTTP $code, MainPID $main, ExecStart pid ${epid:-none}"
      log "  ExecStart argv: ${argv:-none}"
      log "  main process cwd: ${cwd:-none}"
      return 1
    fi
    sleep 2
  done
}

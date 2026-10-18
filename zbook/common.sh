# Settings and helpers shared by cutover.sh, rollback.sh, update.sh and configure.sh. Sourced, not run.
# Every setting can be overridden from the environment; the defaults are the live targets.
UNIT=${UNIT:-nine-router.service}
DATA=${DATA:-/home/inigo/.9router}
DATA=${DATA%/}
PORT=${PORT:-20128}
FORK_APP=${FORK_APP:-/home/inigo/.local/share/9router-fork/app}
FORK_APP=${FORK_APP%/}
OVERRIDE_ENV=${OVERRIDE_ENV:-/home/inigo/.config/9router-fork/override.env}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}
PORT_FREE_TIMEOUT=${PORT_FREE_TIMEOUT:-30}
# configure.sh: the two Otterly servers (priority 1 and 2) and the model ids that get an alias.
AIRSHIP_URL=${AIRSHIP_URL:-http://127.0.0.1:11445/v1}
IWD_URL=${IWD_URL:-http://127.0.0.1:11446/v1}
ALIASES=${ALIASES:-claude-opus-5-5 claude-fable-5-1}
export UNIT DATA PORT FORK_APP OVERRIDE_ENV HEALTH_TIMEOUT PORT_FREE_TIMEOUT AIRSHIP_URL IWD_URL ALIASES
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

ZBOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DROPIN_SRC="$ZBOOK_DIR/nine-router.service.d/otterly-fork.conf"
DROPIN_DIR="$HOME/.config/systemd/user/$UNIT.d"
DROPIN="$DROPIN_DIR/otterly-fork.conf"
# The script that sourced this file, and where the runs in transient units keep their logs (not synchronised).
SELF=$(readlink -f "$0")
STATE_DIR=/home/inigo/.local/state/9router-fork

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# The command line that runs configure.sh again with this run's settings.
configure_cmd() {
  printf '%sPORT=%s AIRSHIP_URL=%s IWD_URL=%s ALIASES='\''%s'\'' %s/configure.sh\n' \
    "${DASHBOARD_PASSWORD_FILE:+DASHBOARD_PASSWORD_FILE=$DASHBOARD_PASSWORD_FILE }" \
    "$PORT" "$AIRSHIP_URL" "$IWD_URL" "$ALIASES" "$ZBOOK_DIR"
}

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
    code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" || true)
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

# wait_port_free
# Before the original (npm) 9router starts, nothing may hold a TCP socket on $PORT: its launcher
# kill -9s the first PID that `lsof -ti:<port>` lists, whatever it is, and a client still connected
# to the port, such as AiderDesk, would be that PID. Polls every second, for up to PORT_FREE_TIMEOUT
# seconds. Returns 1, naming each process that still holds the port, if it never comes free.
wait_port_free() {
  local deadline pids p
  deadline=$(( $(date +%s) + PORT_FREE_TIMEOUT ))
  while :; do
    pids=$(lsof -nP -iTCP:"$PORT" -t 2>/dev/null | sort -u || true)
    if [ -z "$pids" ]; then
      log "port $PORT is free"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  log "port $PORT is still held after ${PORT_FREE_TIMEOUT}s by:"
  for p in $pids; do
    log "  PID $p: $(ps -o args= -p "$p" 2>/dev/null | cut -c1-200 || true)"
  done
  return 1
}

# start_in_unit <name> [args...]
# For cutover.sh and update.sh. From a shell: runs the calling script ($SELF) again with the same
# arguments in the transient systemd user unit 9router-<name>-<timestamp>, passing on the settings
# named in FORWARD_VARS; follows the unit's output with journalctl until the unit ends; and exits
# with the script's exit status. Ctrl+C stops only the following. Inside the unit: returns at once.
start_in_unit() {
  local name=$1 ts tunit logf rcf t0 v running jpid state rc
  shift
  [ -z "${NINEROUTER_FORK_UNIT:-}" ] || return 0
  running=$(systemctl --user list-units --plain --no-legend --state=active,activating,deactivating '9router-cutover-*' '9router-update-*' | awk '{print $1}')
  if [ -n "$running" ]; then
    log "another run is still going: $running"
    log "follow it with: journalctl --user -f -u ${running%%[[:space:]]*}"
    exit 2
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  tunit="9router-$name-$ts"
  mkdir -p "$STATE_DIR"
  logf="$STATE_DIR/$tunit.log"
  rcf="$STATE_DIR/$tunit.rc"
  local -a setenv=(--setenv="NINEROUTER_FORK_UNIT=$tunit" --setenv="NINEROUTER_FORK_LOG=$logf" --setenv="NINEROUTER_FORK_RC=$rcf" --setenv="PATH=$PATH")
  for v in $FORWARD_VARS; do
    [ -z "${!v+x}" ] || setenv+=(--setenv="$v=${!v}")
  done
  t0=$(date +%s)
  log "running in the transient unit $tunit"
  log "log file: $logf"
  # KillMode=mixed: stopping the unit sends SIGTERM to the script alone, whose trap then puts things
  # back; the timeout leaves it the time for that.
  systemd-run --user --quiet --collect --unit="$tunit" --description="9router fork: ${SELF##*/}" \
    -p KillMode=mixed -p TimeoutStopSec=600 "${setenv[@]}" "$SELF" "$@" || { log "systemd-run failed; nothing was started"; exit 1; }
  journalctl --user -u "$tunit" -f -o cat --since "@$t0" &
  jpid=$!
  trap 'kill "$jpid" 2>/dev/null; echo; log "stopped following. $tunit goes on running; follow it again with: journalctl --user -f -u $tunit (log file: $logf)"; exit 130' INT
  while :; do
    state=$(systemctl --user show -p ActiveState --value "$tunit" 2>/dev/null || true)
    case $state in
      active|activating|deactivating|reloading) sleep 1 ;;
      *) break ;;
    esac
  done
  sleep 2
  kill "$jpid" 2>/dev/null || true
  wait "$jpid" 2>/dev/null || true
  trap - INT
  rc=$(cat "$rcf" 2>/dev/null || true)
  rm -f "$rcf"
  if [ -z "$rc" ]; then
    log "$tunit ended without an exit status; see $logf"
    exit 1
  fi
  exit "$rc"
}

# unit_io_setup: inside the transient unit, append everything the script prints to the log file as
# well, and record its exit status for start_in_unit. Outside a unit it does nothing.
unit_io_setup() {
  [ -n "${NINEROUTER_FORK_UNIT:-}" ] || return 0
  exec > >(tee -a "$NINEROUTER_FORK_LOG") 2>&1
  UNIT_TEE_PID=$!
  trap 'unit_io_finish $?' EXIT
  log "running in the transient unit $NINEROUTER_FORK_UNIT; log file: $NINEROUTER_FORK_LOG"
}

unit_io_finish() {
  local rc=$1
  log "exit status $rc"
  printf '%s\n' "$rc" > "$NINEROUTER_FORK_RC" || true
  exec >&- 2>&-
  wait "$UNIT_TEE_PID" 2>/dev/null || true
}

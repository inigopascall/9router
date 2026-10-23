#!/usr/bin/env bash
# native-trial.sh: run otterly@iwd on Otterly's native client-tool trial build, or put it back on
# the usual build. See README.md.
#
# Usage: [INSTANCE=iwd|airship] native-trial.sh on|off|status
#   Each instance is switched on its own; switching one leaves the other as it is.
#   on      installs the drop-in otterly@iwd.service.d/native-trial.conf, which runs the trial
#           build in TRIAL_APP with OTTERLY_NATIVE_TOOLS=1, and restarts the unit. If the unit is
#           not healthy within HEALTH_TIMEOUT seconds, or the script is interrupted, it removes
#           the drop-in and starts the usual build again.
#   off     removes the drop-in and restarts the unit on the usual build in APP.
#   status  read-only: which build the unit runs, whether it answers, and both builds' commits.
# Healthy: the unit's main process runs the build asked for, GET /api/status answers 200,
# GET /api/quota names the account, and, for the trial build, the unit's log since the restart
# shows that its native startup check passed ("Client tools  : native (isolation verified)").
#
# on and off restart the unit, which ends every request running through it at that moment.
# Nothing is built or deleted: both builds stay on disk.
#
# Settings, from the environment: INSTANCE=iwd (the unit is otterly@$INSTANCE.service, and its
# port is OTTERLY_PORT in ~/.config/otterly/$INSTANCE.env), TRIAL_APP, HEALTH_TIMEOUT=180.
# Exit status: 0 done; 1 the switch failed (the output says which build runs now); 2 bad arguments
# or a failed preflight: nothing was changed.
set -uo pipefail

INSTANCE=${INSTANCE:-iwd}
UNIT="otterly@$INSTANCE.service"
APP=/home/inigo/.local/share/otterly-zbook/app
TRIAL_APP=${TRIAL_APP:-/home/inigo/.local/share/otterly-zbook/app-native}
TRIAL_APP=${TRIAL_APP%/}
DROPIN_DIR="$HOME/.config/systemd/user/$UNIT.d"
DROPIN="$DROPIN_DIR/native-trial.conf"
ENV_FILE="$HOME/.config/otterly/$INSTANCE.env"
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
NATIVE_BANNER="native (isolation verified)"
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
usage() { echo "usage: [INSTANCE=iwd|airship] $0 on|off|status" >&2; exit 2; }
preflight_fail() { log "PREFLIGHT FAILED: $*"; log "nothing was changed"; exit 2; }

[ $# = 1 ] || usage
case $1 in on|off|status) ;; *) usage ;; esac
case $INSTANCE in iwd|airship) ;; *) preflight_fail "INSTANCE must be iwd or airship" ;; esac
[ -f "$ENV_FILE" ] || preflight_fail "missing $ENV_FILE"
PORT=$(sed -n 's/^OTTERLY_PORT=//p' "$ENV_FILE" | head -n 1)
[[ $PORT =~ ^[0-9]+$ ]] || preflight_fail "$ENV_FILE sets no numeric OTTERLY_PORT"
OFF_CMD="$0 off"
[ "$INSTANCE" = iwd ] || OFF_CMD="INSTANCE=$INSTANCE $0 off"

main_pid() { systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null; }

# The command line of a PID, or nothing for PID 0.
main_cmd() {
  local pid=${1:-0}
  [ "$pid" != 0 ] || return 0
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//'
}

# Which build a command line runs: trial, usual, none or unknown.
build_of() {
  case $1 in
    "") echo none ;;
    *"$TRIAL_APP/dist/cli.js serve"*) echo trial ;;
    *"$APP/dist/cli.js serve"*) echo usual ;;
    *) echo unknown ;;
  esac
}

status_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$PORT/api/status" 2>/dev/null || true; }

# wait_healthy trial|usual <epoch seconds taken before the restart>
wait_healthy() {
  local want=$1 since=$2 deadline pid build code jlog checked email
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while :; do
    pid=$(main_pid)
    build=$(build_of "$(main_cmd "$pid")")
    code=$(status_code)
    jlog=$(journalctl --user -u "$UNIT" --since "@$since" -o cat --no-pager 2>/dev/null || true)
    checked=no
    if grep -qF "$NATIVE_BANNER" <<<"$jlog"; then checked=yes; fi
    if [ "$build" = "$want" ] && [ "$code" = 200 ] && { [ "$want" = usual ] || [ "$checked" = yes ]; }; then
      email=$(curl -s -m 70 "http://127.0.0.1:$PORT/api/quota" 2>/dev/null | jq -r '.otterly.account.email // empty' 2>/dev/null || true)
      if [ -n "$email" ]; then
        log "healthy: $UNIT runs the $want build (PID $pid); GET /api/status 200; logged in as $email"
        [ "$want" = usual ] || log "  its startup check passed: Client tools: $NATIVE_BANNER"
        return 0
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "NOT healthy after ${HEALTH_TIMEOUT}s: wanted the $want build; it runs: $build (PID ${pid:-0}); GET /api/status: $code; native startup check passed: $checked"
      log "  the unit's log since the restart, last 20 lines:"
      tail -n 20 <<<"$jlog" | sed 's/^/    /'
      return 1
    fi
    sleep 2
  done
}

write_dropin() {
  mkdir -p "$DROPIN_DIR" || return 1
  cat > "$DROPIN" <<EOF
# Installed by native-trial.sh on; native-trial.sh off removes it.
# $UNIT runs the native client-tool trial build in $TRIAL_APP.
[Service]
Environment=OTTERLY_NATIVE_TOOLS=1
ExecStart=
ExecStart=/usr/bin/node $TRIAL_APP/dist/cli.js serve --host 127.0.0.1 -p \${OTTERLY_PORT}
EOF
}

# Remove the drop-in and run the usual build. Returns 1 when that is not healthy.
put_back_usual() {
  local since
  trap '' INT TERM HUP
  since=$(date +%s)
  if [ -e "$DROPIN" ]; then
    rm -f "$DROPIN"
    log "removed $DROPIN"
  fi
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl --user daemon-reload
  log "restarting $UNIT on the usual build"
  systemctl --user restart "$UNIT" || log "the restart reported an error; the health check decides"
  if wait_healthy usual "$since"; then return 0; fi
  log "PUTTING BACK FAILED: $UNIT is not healthy on the usual build either. Its log: journalctl --user -u $UNIT -n 50 --no-pager"
  return 1
}

show_status() {
  local pid build code banner
  pid=$(main_pid)
  build=$(build_of "$(main_cmd "$pid")")
  code=$(status_code)
  banner=""
  if [ "${pid:-0}" != 0 ]; then
    banner=$(journalctl --user -u "$UNIT" _PID="$pid" -o cat --no-pager 2>/dev/null | grep -F 'Client tools' | tail -n 1 | sed 's/^ *//')
  fi
  echo "unit:            $UNIT, $(systemctl --user is-active "$UNIT" 2>/dev/null), PID ${pid:-0}"
  echo "runs:            the $build build"
  echo "drop-in:         $([ -e "$DROPIN" ] && echo "$DROPIN" || echo none)"
  echo "GET /api/status: $code"
  echo "startup line:    ${banner:-(no Client tools line: the usual build prints none)}"
  echo "trial build:     $TRIAL_APP at $(git -C "$TRIAL_APP" log --oneline -1 2>/dev/null || echo '(not built)')"
  echo "usual build:     $APP at $(git -C "$APP" log --oneline -1 2>/dev/null || echo '(missing)')"
}

switch_on() {
  local since
  systemctl --user cat "$UNIT" >/dev/null 2>&1 || preflight_fail "no unit $UNIT"
  [ -f "$TRIAL_APP/dist/cli.js" ] || preflight_fail "no trial build: $TRIAL_APP/dist/cli.js is missing"
  grep -q OTTERLY_NATIVE_TOOLS "$TRIAL_APP/dist/cli.js" || preflight_fail "$TRIAL_APP/dist/cli.js has no OTTERLY_NATIVE_TOOLS switch"
  [ -f "$APP/dist/cli.js" ] || preflight_fail "no usual build at $APP/dist/cli.js to go back to"
  if [ -e "$DROPIN" ]; then
    log "already on: $DROPIN is installed"
    show_status
    exit 0
  fi
  since=$(date +%s)
  trap 'log "interrupted: putting the usual build back"; put_back_usual; exit 1' INT TERM HUP
  if ! write_dropin; then
    log "could not write $DROPIN"
    put_back_usual
    exit 1
  fi
  log "installed $DROPIN"
  systemctl --user daemon-reload
  log "restarting $UNIT on the trial build"
  systemctl --user restart "$UNIT" || log "the restart reported an error; the health check decides"
  if wait_healthy trial "$since"; then
    trap - INT TERM HUP
    log "native trial is ON for $UNIT. To go back: $OFF_CMD"
    exit 0
  fi
  log "the trial build is not healthy: putting the usual build back"
  put_back_usual
  exit 1
}

switch_off() {
  systemctl --user cat "$UNIT" >/dev/null 2>&1 || preflight_fail "no unit $UNIT"
  [ -f "$APP/dist/cli.js" ] || preflight_fail "no usual build at $APP/dist/cli.js"
  if [ ! -e "$DROPIN" ] && [ "$(build_of "$(main_cmd "$(main_pid)")")" = usual ]; then
    log "already off: no $DROPIN, and $UNIT runs the usual build"
    exit 0
  fi
  if put_back_usual; then
    log "native trial is OFF for $UNIT"
    exit 0
  fi
  exit 1
}

case $1 in
  on) switch_on ;;
  off) switch_off ;;
  status) show_status ;;
esac

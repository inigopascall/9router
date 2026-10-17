#!/usr/bin/env bash
# configure.sh: give a running 9router fork (by default the live one) its two Otterly connections
# and the model aliases, then report on every Otterly connection. cutover.sh runs it after a
# cutover; it can also be run on its own at any time. See README.md.
#
# Settings, from the environment (the defaults, in common.sh, are the live targets):
#   PORT=20128                                  the 9router at http://127.0.0.1:$PORT
#   AIRSHIP_URL=http://127.0.0.1:11445/v1       Otterly for the Claude account Airship, priority 1
#   IWD_URL=http://127.0.0.1:11446/v1           Otterly for the Claude account IWD, priority 2
#   ALIASES="claude-opus-5-5 claude-fable-5-1"  each id gets the alias <id> -> otterly/<id>
#   DASHBOARD_PASSWORD_FILE                     read the dashboard password from this file instead
#                                               of asking for it on the terminal (rehearsals)
# Exit status: 0 when the connections and the aliases are in place, 1 otherwise.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
BASE="http://127.0.0.1:$PORT"
RERUN=$(configure_cmd)

# Stop before anything has been changed.
stop() {
  log "$*"
  log "nothing was changed"
  log "to run configure.sh again: $RERUN"
  exit 1
}

for tool in curl jq; do
  command -v "$tool" >/dev/null || stop "$tool is not installed"
done

# The session cookie is kept in a private directory under XDG_RUNTIME_DIR, removed on exit.
TMP=$(mktemp -d "$XDG_RUNTIME_DIR/9router-configure.XXXXXX") || stop "cannot create a directory under $XDG_RUNTIME_DIR"
trap 'rm -rf "$TMP"' EXIT

# api METHOD PATH [JSON]: one dashboard API call with the session cookie. The response body goes to
# $TMP/body; the HTTP status is printed (000: no answer).
api() {
  local args=(-s -m 30 -b "$TMP/jar" -o "$TMP/body" -w '%{http_code}' -X "$1" "$BASE$2")
  if [ $# -ge 3 ]; then args+=(-H 'Content-Type: application/json' -d "$3"); fi
  rm -f "$TMP/body"
  curl "${args[@]}" || true
}

# The error message in $TMP/body, if there is one.
body_error() { jq -r '(.error.message? // .error? // .message? // empty) | tostring' "$TMP/body" 2>/dev/null || true; }

# The port of a URL, for a connection's name: http://127.0.0.1:11445/v1 -> 11445.
url_port() {
  local hostport=${1#*://}
  hostport=${hostport%%/*}
  case $hostport in
    *:*) echo "${hostport##*:}" ;;
    *) case $1 in https:*) echo 443 ;; *) echo 80 ;; esac ;;
  esac
}

# 1. The dashboard password, from DASHBOARD_PASSWORD_FILE or asked for once on the terminal. It is
# never printed or written to a file, and it reaches curl on a pipe, not on a command line.
PW=""
if [ -n "${DASHBOARD_PASSWORD_FILE:-}" ]; then
  if [ ! -f "$DASHBOARD_PASSWORD_FILE" ] || [ ! -r "$DASHBOARD_PASSWORD_FILE" ]; then
    stop "cannot read DASHBOARD_PASSWORD_FILE ($DASHBOARD_PASSWORD_FILE)"
  fi
  IFS= read -r PW < "$DASHBOARD_PASSWORD_FILE" || true
elif IFS= read -rs -p "Dashboard password for $BASE: " PW < /dev/tty 2> /dev/tty; then
  printf '\n' > /dev/tty
else
  stop "no terminal to ask for the dashboard password on; set DASHBOARD_PASSWORD_FILE"
fi
[ -n "$PW" ] || stop "no dashboard password given"

# 2. One login attempt. If it fails, nothing is changed.
log "configuring the 9router at $BASE"
code=$(printf '%s' "$PW" | jq -Rs '{password: .}' |
  curl -s -m 20 -c "$TMP/jar" -o "$TMP/body" -w '%{http_code}' -X POST "$BASE/api/auth/login" \
    -H 'Content-Type: application/json' -d @-) || true
unset PW
if [ "$code" != 200 ]; then
  if [ "$code" = 000 ]; then err="no answer from $BASE"; else err=$(body_error); fi
  stop "login failed: HTTP $code: ${err:-the server gave no error message}"
fi
log "logged in"
FAILED=0

# 3. The two otterly connections. An otterly connection that already has the base URL is left as
# it is.
code=$(api GET /api/providers)
if [ "$code" != 200 ]; then
  log "GET /api/providers answered HTTP $code: $(body_error); no connection was created"
  FAILED=1
else
  cp "$TMP/body" "$TMP/providers.json"
  created=0 present=0 prio=0
  for spec in "Airship|$AIRSHIP_URL" "IWD|$IWD_URL"; do
    prio=$((prio + 1))
    title=${spec%%|*}
    url=${spec#*|}
    url=${url%/}
    name="Claude $title (Otterly :$(url_port "$url"))"
    id=$(jq -r --arg u "$url" 'first(.connections[]? | select(.provider == "otterly" and (((.providerSpecificData.baseUrl // "") | tostring | sub("/+$"; "")) == $u)) | .id) // empty' "$TMP/providers.json")
    if [ -n "$id" ]; then
      log "connection already there, left as it is: an otterly connection for $url (id $id)"
      present=$((present + 1))
      continue
    fi
    code=$(api POST /api/providers "$(jq -nc --arg n "$name" --arg u "$url" --argjson p "$prio" \
      '{provider: "otterly", name: $n, apiKey: "unused", priority: $p, providerSpecificData: {baseUrl: $u}}')")
    id=$(jq -r '.connection.id // empty' "$TMP/body" 2>/dev/null || true)
    if [[ $code == 20[01] && -n $id ]]; then
      log "connection created: \"$name\", priority $prio, base URL $url (id $id)"
      created=$((created + 1))
    else
      log "creating the connection \"$name\" failed: HTTP $code: $(body_error)"
      FAILED=1
    fi
  done
  log "connections: $created created, $present already there"
fi

# 4. The aliases: <id> -> otterly/<id> for each id in ALIASES.
code=$(api GET /api/models/alias)
if [ "$code" != 200 ]; then
  log "GET /api/models/alias answered HTTP $code: $(body_error); no alias was set"
  FAILED=1
else
  cp "$TMP/body" "$TMP/aliases.json"
  set_count=0 present=0
  for id in $ALIASES; do
    current=$(jq -r --arg a "$id" '.aliases[$a]? // empty | tostring' "$TMP/aliases.json")
    if [ "$current" = "otterly/$id" ]; then
      log "alias already set: $id -> otterly/$id"
      present=$((present + 1))
      continue
    fi
    code=$(api PUT /api/models/alias "$(jq -nc --arg m "otterly/$id" --arg a "$id" '{model: $m, alias: $a}')")
    if [ "$code" = 200 ] && [ "$(jq -r '.success // false' "$TMP/body" 2>/dev/null)" = true ]; then
      log "alias set: $id -> otterly/$id${current:+ (it was $current)}"
      set_count=$((set_count + 1))
    else
      log "setting the alias $id failed: HTTP $code: $(body_error)"
      FAILED=1
    fi
  done
  log "aliases: $set_count set, $present already set"
fi

# 5. A report on every otterly connection: name, priority, base URL, connection test, usage.
# Failures here are reported, not fatal.
echo
code=$(api GET /api/providers)
if [ "$code" != 200 ]; then
  log "GET /api/providers answered HTTP $code: $(body_error); no report"
else
  jq -r '[.connections[]? | select(.provider == "otterly")] | sort_by(.priority // 999) | .[]
         | [.id, (.priority // "none" | tostring), (.providerSpecificData.baseUrl // "none" | tostring), (.name // "unnamed")]
         | @tsv' "$TMP/body" > "$TMP/otterly.tsv"
  [ -s "$TMP/otterly.tsv" ] || echo "There is no otterly connection."
  while IFS=$'\t' read -r cid prio url name; do
    echo "$name"
    echo "  priority $prio, base URL $url"
    code=$(api POST "/api/providers/$cid/test")
    if [ "$code" = 200 ]; then
      jq -r '"  connection test: " + (if .valid == true then "passed" + (if .error then " (\(.error))" else "" end) else "failed: \(.error // "no reason given")" end)' "$TMP/body"
    else
      echo "  connection test: HTTP $code: $(body_error)"
    fi
    code=$(api GET "/api/usage/$cid")
    if [ "$code" = 200 ]; then
      jq -r 'if ((.quotas // {}) | length) > 0
             then "  usage: \(.plan // "plan not reported")",
                  (.quotas | to_entries[] | "    \(.key): \(.value.used)% used, resets at \(.value.resetAt // "unknown")")
             else "  usage: \(.message // "none reported")" end' "$TMP/body"
    else
      echo "  usage: HTTP $code: $(body_error)"
    fi
  done < "$TMP/otterly.tsv"
fi

# 6. The aliases now set, and the fallback strategy that applies to otterly.
echo
code=$(api GET /api/models/alias)
if [ "$code" = 200 ]; then
  echo "Model aliases now set:"
  jq -r '(.aliases // {}) | if length == 0 then "  none" else (to_entries[] | "  \(.key) -> \(.value)") end' "$TMP/body"
else
  echo "Model aliases: GET /api/models/alias answered HTTP $code: $(body_error)"
fi
code=$(api GET /api/settings)
if [ "$code" = 200 ]; then
  jq -r '(try .providerStrategies.otterly.fallbackStrategy catch null) as $p
    | (try .fallbackStrategy catch null) as $g
    | "Fallback strategy for otterly: "
      + (if $p then "\($p), set for otterly in providerStrategies"
         elif $g then "\($g), the global fallbackStrategy"
         else "fill-first, the default of 9router, which tries the connections in priority order (GET /api/settings sets neither fallbackStrategy nor providerStrategies.otterly)"
         end)' "$TMP/body"
else
  echo "Fallback strategy for otterly: GET /api/settings answered HTTP $code: $(body_error)"
fi

echo
if [ "$FAILED" = 0 ]; then
  log "configure.sh done: the otterly connections and the aliases are in place"
  exit 0
fi
log "configure.sh FAILED: see above. To run it again: $RERUN"
exit 1

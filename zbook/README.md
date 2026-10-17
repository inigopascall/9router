---
verified: 2026-10-17
verified_by: workdonkey
---

# zbook: the 9router fork and Otterly as systemd user units

Units, environment files and three scripts for running the 9router fork (this branch, with the
`otterly` provider) and two Otterly servers on the zbook, for switching the live
`nine-router.service` to the fork and back, and for giving the fork its two Otterly connections.
The fork runs from a standalone build at `~/.local/share/9router-fork/app/`; Otterly from
`~/.local/share/otterly-zbook/`.

## Files

| File | What it is | Installed at |
|---|---|---|
| `otterly@.service` | Template unit: one Otterly server per Claude account, on 127.0.0.1 | `~/.config/systemd/user/otterly@.service` |
| `otterly.env.example` | An instance's environment: Claude config dir, port, trace dir (the `airship` values) | `~/.config/otterly/airship.env`; `iwd.env` is the same with `iwd` and port 11446 |
| `nine-router-staging.service` | The fork on 127.0.0.1:20129 with its own data, beside the live service | `~/.config/systemd/user/nine-router-staging.service` |
| `nine-router.service.d/otterly-fork.conf` | Drop-in that runs `nine-router.service` on the fork; `cutover.sh` installs it, `rollback.sh` removes it | `~/.config/systemd/user/nine-router.service.d/otterly-fork.conf` |
| `override.env` | `HOSTNAME` and `PORT` for the fork. `~/.9router/service.env` sets them too; the drop-in reads this file after it, so these values win | `~/.config/9router-fork/override.env` |
| `cutover.sh` | Switches `nine-router.service` to the fork, then runs `configure.sh` | not installed; run from here |
| `rollback.sh` | Switches it back | not installed; run from here |
| `configure.sh` | Gives a running fork its two Otterly connections and the model aliases, and reports on them | not installed; run from here |
| `common.sh` | Settings and health check shared by the three scripts | not installed |

The staging instance keeps its data in `~/.local/share/9router-staging/`, its password in
`~/.config/9router-staging/env` (`INITIAL_PASSWORD`) and a client API key in
`~/.config/9router-staging/api-key`. On 2026-10-17 that password was also stored as its dashboard
password, and its database was given the two Otterly connections, that API key and the model
aliases.

Ports: Otterly 11445 (`airship`) and 11446 (`iwd`); staging 9router 20129; live 9router 20128.

## Before the cutover

1. Log in each Claude account into its own config dir:
   `CLAUDE_CONFIG_DIR=~/.claude-airship ~/.local/share/otterly-zbook/bin/claude auth login`,
   and the same with `~/.claude-iwd`. `claude auth status`, with the same variable, checks it.
2. `systemctl --user start otterly@airship otterly@iwd`; then
   `curl -s http://127.0.0.1:11445/api/quota | jq .otterly.account` names the account.
3. To try the fork first: `systemctl --user start nine-router-staging`, dashboard at
   http://127.0.0.1:20129/dashboard. `cutover.sh` stops and disables it again.

## cutover.sh

    ~/code/iwd/9router/zbook/cutover.sh

1. Preflight, read-only: the fork build, the drop-in source and `override.env` exist, no drop-in
   is installed, and `otterly@airship` and `otterly@iwd` are active and logged in (their
   `/api/quota` names the account). Any failure stops the script with nothing changed.
2. Stops `nine-router.service` and copies `~/.9router` to `~/.9router.pre-fork-<YYYYmmdd-HHMMSS>`.
3. Installs the drop-in, reloads systemd and starts the service.
4. Health check: within 90 s, `GET /v1/models` returns 200 and the service runs the fork. If not,
   it runs `rollback.sh --restore <backup>` and exits 1.
5. Runs `configure.sh` (below), which asks once for the dashboard password. `SKIP_CONFIGURE=1`
   leaves this step out. If `configure.sh` fails, the fork keeps running and nothing is rolled
   back: the script finishes the remaining steps and exits 3.
6. For the live unit only: enables `otterly@airship` and `otterly@iwd`, and stops and disables
   `nine-router-staging`.
7. Prints the backup path; the outcome of `configure.sh`, with the command to run it again when it
   failed or was skipped; for the live unit, the change to make in AiderDesk (the provider
   `otterly-claude` gets the base URL `http://127.0.0.1:20128/v1` and the 9router API key; to go
   back, the base URL `http://localhost:11435/v1`); and the undo command.

Exit status: 0 done; 1 the health check failed and `rollback.sh --restore` was run, or the backup
failed and the unit was started again unchanged; 2 the preflight failed and nothing was changed;
3 the fork is running, but `configure.sh` failed.

## configure.sh

    ~/code/iwd/9router/zbook/configure.sh

Configures the 9router at `http://127.0.0.1:$PORT`. `cutover.sh` runs it; run it on its own to
redo a step that failed, or after changing a setting. A second run creates nothing that is
already there.

1. Asks once for the dashboard password on the terminal, or reads it from the file named by
   `DASHBOARD_PASSWORD_FILE` (for rehearsals). The password is never printed or written to a
   file. The session cookie is kept in a `mktemp -d` directory under `$XDG_RUNTIME_DIR`, removed
   on exit.
2. Logs in once. If that fails, it prints the server's error, `nothing was changed` and the
   command to run it again, and exits 1. Five failed logins in a row lock the dashboard login for
   30 s, and for longer after further failures.
3. Creates two `otterly` connections with the API key `unused`:
   `Claude Airship (Otterly :<port>)` with base URL `AIRSHIP_URL` and priority 1, and
   `Claude IWD (Otterly :<port>)` with base URL `IWD_URL` and priority 2, `<port>` being
   the port of the URL. An `otterly` connection that already has the base URL is left as it is.
4. Gives each id in `ALIASES` the alias `<id>` -> `otterly/<id>`, so that clients can go on
   sending bare model ids.
5. Reports on each `otterly` connection: name, priority, base URL, the result of its connection
   test, and its usage: the plan and each quota's percentage used and reset time, or the reason
   there is none, e.g. `Otterly not reachable at http://127.0.0.1:11445: fetch failed` while
   Otterly is stopped. A failure in this step is reported, not fatal.
6. Prints the aliases now set, and the fallback strategy that applies to `otterly`:
   `providerStrategies.otterly.fallbackStrategy`, else the global `fallbackStrategy`, else
   9router's default, `fill-first`, which tries the connections in priority order.

Exit status: 0 when the connections and the aliases are in place, 1 otherwise.

## When an account is at its usage limit

While its Claude account is at its usage limit, Otterly answers every inference request with
HTTP 429 at once, without starting the Claude CLI (`quota.usageLimit()` in Otterly's
`server/index.ts`). 9router then sends the same request to the next connection by priority, and
locks the connection that answered 429 for that model only. The lock lasts 2 s after the
connection's first 429 and doubles with each further 429 from it, whatever the model, up to
5 minutes (`BACKOFF_CONFIG` and `ERROR_RULES` in `open-sse/config/errorConfig.js`). 9router does
not read Otterly's `Retry-After` or reset time. So while Airship is limited, a request whose
lock on Airship has run out tries Airship first again, which costs one immediate 429 before
IWD answers. When every connection answers 429, the client gets HTTP 503 with `retry-after`
set to the seconds until the earliest lock runs out (`unavailableResponse` in
`open-sse/utils/error.js`).

This was rehearsed on 2026-10-17 with two stub Otterly servers behind a scratch 9router.

## rollback.sh

    ~/code/iwd/9router/zbook/rollback.sh [--restore ~/.9router.pre-fork-<timestamp>]

Stops `nine-router.service`, removes the drop-in, reloads systemd and starts the service on its own
`ExecStart` (the npm package), with the same health check. `--restore` first moves `~/.9router`
aside to `~/.9router.failed-fork-<timestamp>` and copies the backup into its place; without it,
the npm package runs on the data as the fork left it. The Otterly units are left as they are.

When the npm package starts, its launcher kills every `next-server` process of the user, which
includes the staging instance if it is running.

## Settings

The scripts read these from the environment; the defaults, in `common.sh`, are the live targets:
`UNIT=nine-router.service`, `DATA=/home/inigo/.9router`, `PORT=20128`,
`FORK_APP=/home/inigo/.local/share/9router-fork/app`,
`OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env`, `HEALTH_TIMEOUT=90`, and for
`configure.sh` `AIRSHIP_URL=http://127.0.0.1:11445/v1`, `IWD_URL=http://127.0.0.1:11446/v1` and
`ALIASES="claude-opus-5-5 claude-fable-5-1"`. `configure.sh` also reads
`DASHBOARD_PASSWORD_FILE`; when it is unset, it asks on the terminal. `cutover.sh` also reads
`SKIP_OTTERLY_CHECK=1` (skips the Otterly check) and `SKIP_CONFIGURE=1` (does not run
`configure.sh`), and passes the `configure.sh` settings on to it. `cutover.sh` writes the drop-in
with `PORT`, `FORK_APP` and `OVERRIDE_ENV` in place of the live values, so a rehearsal against
another unit stays off port 20128.

The health check cannot use the main process's command line, because Next.js renames its process
to `next-server (vX)`. It reads the unit's `ExecStart` record and the main process's working
directory instead. The record's `pid=` must be the unit's main PID, or 0, which is what a
daemon-reload resets it to.

## Verify

Run from the Z-Book. Every command is read-only; the expected result follows `# expect:`.

```bash
cd /home/inigo/code/iwd/9router/zbook
# Files: the installed copies are the tracked ones; iwd.env differs from airship.env only in iwd and 11446; the old acct env files are gone
cmp otterly@.service ~/.config/systemd/user/otterly@.service && echo same                         # expect: same
cmp nine-router-staging.service ~/.config/systemd/user/nine-router-staging.service && echo same   # expect: same
cmp override.env ~/.config/9router-fork/override.env && echo same                                 # expect: same
cmp otterly.env.example ~/.config/otterly/airship.env && echo same                                # expect: same
sed 's/airship/iwd/g; s/11445/11446/' otterly.env.example | cmp - ~/.config/otterly/iwd.env && echo same # expect: same
ls ~/.config/otterly | grep -c acct                                                               # expect: 0
grep -c -e '^WorkingDirectory=/home/inigo/.local/share/9router-fork/app$' -e '^EnvironmentFile=/home/inigo/.config/9router-fork/override.env$' nine-router.service.d/otterly-fork.conf # expect: 2
# Staging: its port and data, and the files it keeps (tested, not read); the live unit's port and ExecStart
grep -c -e '^Environment=PORT=20129$' -e '^Environment=DATA_DIR=%h/.local/share/9router-staging$' -e '^EnvironmentFile=%h/.config/9router-staging/env$' nine-router-staging.service # expect: 3
test -f ~/.config/9router-staging/env && test -f ~/.config/9router-staging/api-key && test -d ~/.local/share/9router-staging/db && echo present # expect: present
grep -cxE 'Environment=(PORT=20128|HOSTNAME=127.0.0.1)|ExecStart=/home/inigo/.local/bin/9router .*' ~/.config/systemd/user/nine-router.service # expect: 3
# Before the cutover: the pinned CLI knows auth login and auth status; the installed Otterly answers 429 at the usage limit
grep -a -c -e 'claude auth login' -e 'claude auth status' "$(readlink -f ~/.local/share/otterly-zbook/bin/claude)" # expect: 1 or more
grep -c 'quota.usageLimit()' ~/.local/share/otterly-zbook/app/dist/server/index.js                 # expect: 1
# cutover.sh: preflight, backup, drop-in, rollback on failure, configure.sh, live-unit steps, summary, exit 3
grep -cF -e '.otterly.account.email // empty' -e 'log "nothing was changed"; exit 2' -e 'BACKUP="$DATA.pre-fork-$(date +%Y%m%d-%H%M%S)"' -e '"$DROPIN_SRC" > "$DROPIN"' -e '"$ZBOOK_DIR/rollback.sh" --restore "$BACKUP"' cutover.sh # expect: 5
grep -cF -e 'Environment=PORT=$PORT|' -e '|$FORK_APP|g' -e '|EnvironmentFile=$OVERRIDE_ENV|' cutover.sh # expect: 3
grep -cF -e 'SKIP_OTTERLY_CHECK=${SKIP_OTTERLY_CHECK:-0}' -e 'SKIP_CONFIGURE=${SKIP_CONFIGURE:-0}' -e 'if "$ZBOOK_DIR/configure.sh"; then' -e '[ "$CONFIGURE_RC" = 0 ] || exit 3' cutover.sh # expect: 4
grep -cF -e 'systemctl --user enable otterly@airship.service otterly@iwd.service' -e 'systemctl --user disable nine-router-staging.service' -e 'for acct in airship iwd; do' cutover.sh # expect: 3
grep -cF 'In AiderDesk, edit the provider otterly-claude: set its base URL to http://127.0.0.1:20128/v1 and its API key to the 9router API key your 9router provider uses. To go back, set the base URL to http://localhost:11435/v1.' cutover.sh # expect: 1
# rollback.sh: removes the drop-in, moves the data aside, checks the original; the npm launcher kills next-server processes
grep -cF -e 'rm -f "$DROPIN"' -e 'FAILED="$DATA.failed-fork-$(date +%Y%m%d-%H%M%S)"' -e 'if ! wait_healthy original; then' rollback.sh # expect: 3
grep -cF '|| cmd.includes("next-server");' ~/.local/lib/node_modules/9router/cli.js               # expect: 2
# configure.sh: password, cookie directory, one login, connections, aliases, report, exit status
grep -cF -e 'read -rs -p' -e 'IFS= read -r PW < "$DASHBOARD_PASSWORD_FILE"' -e 'mktemp -d "$XDG_RUNTIME_DIR/9router-configure.XXXXXX"' -e 'rm -rf "$TMP"' configure.sh # expect: 4
grep -c 'api/auth/login' configure.sh                                                               # expect: 1
grep -cF -e 'for spec in "Airship|$AIRSHIP_URL" "IWD|$IWD_URL"; do' -e 'name="Claude $title (Otterly :$(url_port "$url"))"' -e 'apiKey: "unused", priority: $p' -e 'select(.provider == "otterly" and' -e '--arg m "otterly/$id" --arg a "$id"' configure.sh # expect: 5
grep -cF -e '/api/providers/$cid/test' -e '/api/usage/$cid' -e 'try .providerStrategies.otterly.fallbackStrategy catch null' -e 'try .fallbackStrategy catch null' configure.sh # expect: 4
grep -cxE ' *exit [01]' configure.sh                                                                 # expect: 3
# common.sh: the defaults and the health check
grep -cxF -e 'UNIT=${UNIT:-nine-router.service}' -e 'DATA=${DATA:-/home/inigo/.9router}' -e 'PORT=${PORT:-20128}' -e 'FORK_APP=${FORK_APP:-/home/inigo/.local/share/9router-fork/app}' -e 'OVERRIDE_ENV=${OVERRIDE_ENV:-/home/inigo/.config/9router-fork/override.env}' -e 'HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-90}' -e 'AIRSHIP_URL=${AIRSHIP_URL:-http://127.0.0.1:11445/v1}' -e 'IWD_URL=${IWD_URL:-http://127.0.0.1:11446/v1}' -e 'ALIASES=${ALIASES:-claude-opus-5-5 claude-fable-5-1}' common.sh # expect: 9
grep -rn -iE 'acct[12]|ACCT[12]_URL|Claude account [12]' . | wc -l                                  # expect: 0
grep -cF -e '"http://127.0.0.1:$PORT/v1/models" || true)' -e 'readlink "/proc/$main/cwd"' -e '[ "${epid:-0}" = 0 ] || [ "$epid" = "$main" ]' -e 'fork) if [[ $argv == *"$FORK_APP/custom-server.js"* && $cwd == "$fork_real" ]]' common.sh # expect: 4
# 9router: the login lock, Otterly's usage message, connection order, the lock after a 429 (otterly has no executor of its own, and the base parseError gives no reset time), the answer when every connection is locked
grep -cF -e 'const MAX_FAILS_BEFORE_LOCK = 5;' -e 'const LOCK_STEPS_MS = [30_000,' ../src/lib/auth/loginLimiter.js # expect: 2
grep -cF 'Otterly not reachable at ${root}:' ../open-sse/services/usage/otterly.js                 # expect: 1
grep -cF -e 'providerOverride.fallbackStrategy || settings.fallbackStrategy || "fill-first"' -e 'backoffLevel: newBackoffLevel ?? backoffLevel' ../src/sse/services/auth.js # expect: 2
grep -cF 'list.sort((a, b) => (a.priority || 999) - (b.priority || 999));' ../src/lib/db/repos/connectionsRepo.js # expect: 1
grep -cF -e 'base: 2000,' -e 'max: 5 * 60 * 1000,' -e '{ status: 429, backoff: true },' ../open-sse/config/errorConfig.js # expect: 3
grep -cF 'return model ? `${MODEL_LOCK_PREFIX}${model}` : MODEL_LOCK_ALL;' ../open-sse/services/accountFallback.js # expect: 1
grep -c parseError ../open-sse/executors/default.js                                                # expect: 0
grep -cF 'return { status: response.status, message: bodyText || `HTTP ${response.status}` };' ../open-sse/executors/base.js # expect: 1
grep -c otterly ../open-sse/executors/index.js                                                      # expect: 0
grep -cF 'const status = HTTP_STATUS.SERVICE_UNAVAILABLE;' ../src/sse/handlers/chat.js              # expect: 1
grep -cF '"retry-after": String(retryAfterSec)' ../open-sse/utils/error.js                           # expect: 1
```

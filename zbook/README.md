---
verified: 2026-10-18
verified_by: workdonkey
---

# zbook: the 9router fork and Otterly as systemd user units

Units, environment files and scripts for running the 9router fork (this branch, with the
`otterly` provider) and two Otterly servers on the zbook, for switching the live
`nine-router.service` to the fork and back, and for updating the fork to a new upstream 9router
release. The fork runs from a standalone build at `~/.local/share/9router-fork/app/`; Otterly from
`~/.local/share/otterly-zbook/`.

## Files

| File | What it is | Installed at |
|---|---|---|
| `otterly@.service` | Template unit: one Otterly server per Claude account, on 127.0.0.1. After a failed start it tries again every 30 s, with no limit | `~/.config/systemd/user/otterly@.service` |
| `otterly.env.example` | An instance's environment: Claude config dir, port, trace dir (the `airship` values) | `~/.config/otterly/airship.env`; `iwd.env` is the same with `iwd` and port 11446 |
| `nine-router-staging.service` | The fork on 127.0.0.1:20129 with its own data, beside the live service | `~/.config/systemd/user/nine-router-staging.service` |
| `nine-router.service.d/otterly-fork.conf` | Drop-in that runs `nine-router.service` on the fork; `cutover.sh` installs it, `rollback.sh` removes it | `~/.config/systemd/user/nine-router.service.d/otterly-fork.conf` |
| `override.env` | `HOSTNAME` and `PORT` for the fork. `~/.9router/service.env` sets them too; the drop-in reads this file after it, so these values win | `~/.config/9router-fork/override.env` |
| `cutover.sh` | Switches `nine-router.service` to the fork | not installed; run from here |
| `rollback.sh` | Switches it back | not installed; run from here |
| `update.sh` | Updates the fork to the latest upstream 9router release | not installed; run from here |
| `configure.sh` | Optional: gives a running fork its two Otterly connections and the model aliases, and reports on them | not installed; run from here |
| `common.sh` | Settings and helpers shared by the scripts | not installed |

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

Run from a shell, the script starts itself again in a transient systemd user unit,
`9router-cutover-<YYYYmmdd-HHMMSS>`, follows that unit's output until the unit ends, and exits with
the script's exit status. A closed terminal, Ctrl+C or a killed shell therefore stops only the
following, not the cutover; Ctrl+C prints the `journalctl --user -f -u <unit>` command that follows
it again. Everything the run prints is also appended to
`~/.local/state/9router-fork/<unit>.log`, whose path is printed first. One cutover or update runs
at a time: while one is going, another exits 2 and names it.

1. Preflight, read-only: the fork build, the drop-in source and `override.env` exist, no drop-in
   is installed, and `otterly@airship` and `otterly@iwd` are active and logged in (their
   `/api/quota` names the account). Any failure stops the script with nothing changed.
2. Stops `nine-router.service` and copies `~/.9router` to `~/.9router.pre-fork-<YYYYmmdd-HHMMSS>`.
3. Installs the drop-in, reloads systemd and starts the service.
4. Health check: within 120 s, `GET /v1/models` returns 200 (each request may take up to 30 s) and
   the service runs the fork.

   From the stop until the health check passes, a failed step, a failed health check, or SIGTERM,
   SIGINT or SIGHUP (for example `systemctl --user stop` of the transient unit) runs
   `rollback.sh --restore <backup>` and exits 1. Before the backup is complete the data is
   unchanged, and plain `rollback.sh` is run instead.
5. For the live unit only: enables `otterly@airship` and `otterly@iwd`, and stops and disables
   `nine-router-staging`.
6. Prints the backup path; the dashboard steps for the two Otterly connections (Providers →
   "Otterly (Claude)" → add a connection with the base URL `http://127.0.0.1:11445/v1`, and
   another with `http://127.0.0.1:11446/v1`; any text as the API key; the lowest priority is tried
   first); that 9router knows these models as `otterly/<id>`, so in AiderDesk either use those
   names or give each id the alias `<id>` → `otterly/<id>` (no dashboard page sets model aliases,
   so it prints the `configure.sh` command that does); for the live unit, the change to make in
   AiderDesk (the provider `otterly-claude` gets the base URL `http://127.0.0.1:20128/v1` and the
   9router API key; to go back, the base URL `http://localhost:11435/v1`); and the undo command.

Exit status: 0 done; 1 the cutover failed and was rolled back (the output says whether the
rollback itself succeeded); 2 the preflight failed, or another run is going: nothing was changed.

On 2026-10-18 this was rehearsed against a scratch copy of the unit on port 20149: a cutover, a
fork that exits at once, and the transient unit stopped during the health check. After each
failure the original ran again on the original data.

## rollback.sh

    ~/code/iwd/9router/zbook/rollback.sh [--restore ~/.9router.pre-fork-<timestamp>]

Stops `nine-router.service`, removes the drop-in and reloads systemd. Then it waits until no
process has a TCP socket on the port (`lsof -nP -iTCP:$PORT -t`, every second, for up to
`PORT_FREE_TIMEOUT` seconds, 30 by default). This matters because the npm launcher, on every
start, `kill -9`s the first process that `lsof -ti:<port>` lists, whatever it is, and a client
still connected to the port, such as AiderDesk, would be that process. If the port does not come
free, the service stays **stopped** and the data is left as it is: the script names each process
that holds the port (PID and command), says that restarting those programs (for example AiderDesk)
frees it, prints the exact command to run the rollback again, and exits 1.

Once the port is free, `--restore` moves `~/.9router` aside to
`~/.9router.failed-fork-<timestamp>` and copies the backup into its place; without it, the npm
package runs on the data as the fork left it. Then it starts the service on its own `ExecStart`
(the npm package), with the same health check. The Otterly units are left as they are.

Exit status: 0 done; 1 the port stayed in use (the service is stopped), or the original is not
healthy; 2 bad arguments or no such backup: nothing was changed.

When the npm package starts, its launcher kills every `next-server` process of the user, which
includes the staging instance if it is running.

## update.sh

    ~/code/iwd/9router/zbook/update.sh --check
    ~/code/iwd/9router/zbook/update.sh

`--check` is read-only. It fetches the release tags from `upstream`, prints the release the branch
is based on, the build version deployed at `FORK_APP`, the latest upstream release, and whether
the fork's commits rebase cleanly onto it, which it tries in a temporary `git worktree` under
`$XDG_RUNTIME_DIR`, removed afterwards. Exit status 0, or 1 when the rebase would conflict.

Without an argument it refuses (exit 2, nothing changed) unless the repository is clean, on
`otterly-provider`, and the drop-in is installed on `nine-router.service`, that is, the service
runs the fork. Then, in a transient unit `9router-update-<timestamp>`, run and followed as for
`cutover.sh`:

1. If the branch is already on the latest release it exits 0; `FORCE=1` goes on anyway.
2. Tags the branch tip `pre-update-<timestamp>` and rebases the fork's commits onto the latest
   release. On a conflict it aborts the rebase, resets the branch to that tag, prints the
   conflicting files and that nothing was changed, and exits 2.
3. `npm install` and `npm run build`; the unit tests `tests/unit/otterly-provider.test.js` and
   `tests/unit/zbook-fork-update-notice.test.js`, and `tests/__baseline__/verify-alias.mjs`,
   `verify-oauth-urls.mjs` and `verify-providers.mjs`, with `DATA_DIR` and `HOME` under
   `UPDATE_WORK`. A failure stops it here with exit 1: the service, the build and the data are
   unchanged, and it prints how to reset the repository to `pre-update-<timestamp>`.
4. Copies the standalone build to `~/.local/share/9router-fork/app.new`.
5. Stops the service, copies `~/.9router` to `~/.9router.pre-update-<timestamp>`, moves `app` to
   `app.prev` (replacing an older one) and `app.new` to `app`, starts the service, and runs the
   health check.
6. From the stop until the new build is healthy, a failure, an error or a signal puts things back:
   it stops the service, moves the new build aside to `app.failed-<timestamp>`, moves `app.prev`
   back, restores the data backup, waits for the port as `rollback.sh` does, starts the service and
   checks it. It prints that the repository is now on the new release and how to reset it to
   `pre-update-<timestamp>`, and exits 1.
7. On success it prints the versions before and after, the backup path, the previous build and the
   undo command.

On 2026-10-18 `FORCE=1 update.sh` was rehearsed against the scratch copy of the unit.

## The dashboard's update notice

In this fork the dashboard still shows "New version available" when npm's `9router` latest is newer
than the running version, but the command it shows and copies is
`~/code/iwd/9router/zbook/update.sh` (`UPDATER_CONFIG.installCmdLatest` in
`src/shared/constants/config.js`; `GET /api/version` also returns it as `updateCommand`). The
dashboard installs nothing: `POST /api/version/update` answers HTTP 409 with a message naming
`update.sh`. The update panel's "Copy & Shutdown" button still calls `POST /api/version/shutdown`,
which is unchanged from upstream.

## configure.sh

    ~/code/iwd/9router/zbook/configure.sh

Optional and standalone: `cutover.sh` does not run it. It configures the 9router at
`http://127.0.0.1:$PORT`; a second run creates nothing that is already there.

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

## Settings

The scripts read these from the environment; the defaults, in `common.sh`, are the live targets:
`UNIT=nine-router.service`, `DATA=/home/inigo/.9router`, `PORT=20128`,
`FORK_APP=/home/inigo/.local/share/9router-fork/app`,
`OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env`, `HEALTH_TIMEOUT=120`,
`PORT_FREE_TIMEOUT=30`, and for `configure.sh` `AIRSHIP_URL=http://127.0.0.1:11445/v1`,
`IWD_URL=http://127.0.0.1:11446/v1` and `ALIASES="claude-opus-5-5 claude-fable-5-1"`.
`configure.sh` also reads `DASHBOARD_PASSWORD_FILE`; when it is unset, it asks on the terminal.
`cutover.sh` also reads `SKIP_OTTERLY_CHECK=1` (skips the Otterly check). `update.sh` also reads
`FORCE=1` (rebuild and swap even when already on the latest release) and `UPDATE_WORK`
(`DATA_DIR` and `HOME` for the build and the tests; default
`/home/inigo/.local/state/9router-fork/work`). `cutover.sh` and `update.sh` pass their settings
on to their transient unit. `cutover.sh` writes the drop-in with `PORT`, `FORK_APP` and
`OVERRIDE_ENV` in place of the live values, so a rehearsal against another unit stays off port
20128.

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
# Otterly units: retry every 30 s after a failure, with no start limit
grep -cxF -e 'StartLimitIntervalSec=0' -e 'Restart=on-failure' -e 'RestartSec=30' otterly@.service # expect: 3
grep -c StartLimitBurst otterly@.service                                                           # expect: 0
# Staging: its port and data, and the files it keeps (tested, not read); the live unit's port and ExecStart
grep -c -e '^Environment=PORT=20129$' -e '^Environment=DATA_DIR=%h/.local/share/9router-staging$' -e '^EnvironmentFile=%h/.config/9router-staging/env$' nine-router-staging.service # expect: 3
test -f ~/.config/9router-staging/env && test -f ~/.config/9router-staging/api-key && test -d ~/.local/share/9router-staging/db && echo present # expect: present
grep -cxE 'Environment=(PORT=20128|HOSTNAME=127.0.0.1)|ExecStart=/home/inigo/.local/bin/9router .*' ~/.config/systemd/user/nine-router.service # expect: 3
# Before the cutover: the pinned CLI knows auth login and auth status; the installed Otterly answers 429 at the usage limit
grep -a -c -e 'claude auth login' -e 'claude auth status' "$(readlink -f ~/.local/share/otterly-zbook/bin/claude)" # expect: 1 or more
grep -c 'quota.usageLimit()' ~/.local/share/otterly-zbook/app/dist/server/index.js                 # expect: 1
# cutover.sh: preflight, backup, drop-in, rollback, live-unit steps
grep -cF -e '.otterly.account.email // empty' -e 'log "nothing was changed"; exit 2' -e 'BACKUP="$DATA.pre-fork-$(date +%Y%m%d-%H%M%S)"' -e '"$DROPIN_SRC" > "$DROPIN"' -e '"$ZBOOK_DIR/rollback.sh" --restore "$BACKUP"' cutover.sh # expect: 5
grep -cF -e 'Environment=PORT=$PORT|' -e '|$FORK_APP|g' -e '|EnvironmentFile=$OVERRIDE_ENV|' cutover.sh # expect: 3
grep -cF -e 'systemctl --user enable otterly@airship.service otterly@iwd.service' -e 'systemctl --user disable nine-router-staging.service' -e 'for acct in airship iwd; do' cutover.sh # expect: 3
# cutover.sh: the transient unit, and rollback on an error, a failed health check or a signal
grep -cF -e 'start_in_unit cutover' -e 'unit_io_setup' -e "trap 'roll_back \"interrupted by SIGTERM\"' TERM" -e "trap 'roll_back \"interrupted by SIGHUP\"' HUP" -e 'wait_healthy fork || roll_back "health check failed"' cutover.sh # expect: 5
# cutover.sh: no configure step; the summary
grep -c -e 'SKIP_CONFIGURE' -e 'exit 3' -e '"$ZBOOK_DIR/configure.sh"' cutover.sh                  # expect: 0
grep -cF -e 'Otterly (Claude)' -e 'otterly/<id>' -e 'echo "Undo: $UNDO"' cutover.sh               # expect: 3
grep -cF 'In AiderDesk, edit the provider otterly-claude: set its base URL to http://127.0.0.1:20128/v1 and its API key to the 9router API key your 9router provider uses. To go back, set the base URL to http://localhost:11435/v1.' cutover.sh # expect: 1
# No dashboard component sets a model alias: the model rows take no onSetAlias
cat '../src/app/(dashboard)/dashboard/providers/[id]/ModelRow.js' '../src/app/(dashboard)/dashboard/providers/[id]/CompatibleModelsSection.js' '../src/app/(dashboard)/dashboard/providers/[id]/PassthroughModelsSection.js' | grep -c onSetAlias # expect: 0
grep -cF 'function ModelRow({ model, fullModel, copied, onCopy, testStatus, isCustom, isFree, onDeleteAlias, onTest, isTesting })' '../src/app/(dashboard)/dashboard/providers/components/ModelsCard.js' # expect: 1
# rollback.sh: removes the drop-in, waits for the port, moves the data aside, checks the original; the npm launcher
grep -cF -e 'rm -f "$DROPIN"' -e 'FAILED="$DATA.failed-fork-$(date +%Y%m%d-%H%M%S)"' -e 'if ! wait_healthy original; then' rollback.sh # expect: 3
grep -cF -e 'if ! wait_port_free; then' -e 'is STOPPED: 9router is not running, and was not started again' -e 'log "  $RERUN"' rollback.sh # expect: 3
grep -cF '|| cmd.includes("next-server");' ~/.local/lib/node_modules/9router/cli.js               # expect: 2
grep -c 'lsof -ti' ~/.local/lib/node_modules/9router/cli.js                                       # expect: 1 or more
# update.sh: the check, the refusals, the rebase, the tests, the swap
test -x update.sh && echo executable                                                               # expect: executable
grep -cF -e 'g worktree add -q --detach "$tmp/wt" "$BRANCH"' -e 'g worktree remove --force "$tmp/wt"' update.sh # expect: 2
grep -cF -e 'refuse "$REPO is not on the branch $BRANCH"' -e 'refuse "$REPO has uncommitted changes"' -e 'the drop-in $DROPIN is not installed' update.sh # expect: 3
grep -cF -e 'PRE_TAG="pre-update-$TS"' -e 'g rebase --abort || true' -e 'g reset -q --hard "$PRE_TAG"' update.sh # expect: 3
grep -cF -e 'unit/otterly-provider.test.js unit/zbook-fork-update-notice.test.js' -e 'for f in verify-alias verify-oauth-urls verify-providers; do' update.sh # expect: 2
grep -cF -e 'start_in_unit update' -e 'DATA_BACKUP="$DATA.pre-update-$TS"' -e 'mv "$FORK_APP" "$FORK_APP.prev"' -e 'mv "$FORK_APP.new" "$FORK_APP"' -e 'wait_healthy fork || put_back "health check failed"' update.sh # expect: 5
# configure.sh: password, cookie directory, one login, connections, aliases, report, exit status
grep -cF -e 'read -rs -p' -e 'IFS= read -r PW < "$DASHBOARD_PASSWORD_FILE"' -e 'mktemp -d "$XDG_RUNTIME_DIR/9router-configure.XXXXXX"' -e 'rm -rf "$TMP"' configure.sh # expect: 4
grep -c 'api/auth/login' configure.sh                                                               # expect: 1
grep -cF -e 'for spec in "Airship|$AIRSHIP_URL" "IWD|$IWD_URL"; do' -e 'name="Claude $title (Otterly :$(url_port "$url"))"' -e 'apiKey: "unused", priority: $p' -e 'select(.provider == "otterly" and' -e '--arg m "otterly/$id" --arg a "$id"' configure.sh # expect: 5
grep -cF -e '/api/providers/$cid/test' -e '/api/usage/$cid' -e 'try .providerStrategies.otterly.fallbackStrategy catch null' -e 'try .fallbackStrategy catch null' configure.sh # expect: 4
grep -cxE ' *exit [01]' configure.sh                                                                 # expect: 3
# common.sh: the defaults, the health check, the port wait, the transient unit and its log
grep -cxF -e 'UNIT=${UNIT:-nine-router.service}' -e 'DATA=${DATA:-/home/inigo/.9router}' -e 'PORT=${PORT:-20128}' -e 'FORK_APP=${FORK_APP:-/home/inigo/.local/share/9router-fork/app}' -e 'OVERRIDE_ENV=${OVERRIDE_ENV:-/home/inigo/.config/9router-fork/override.env}' -e 'HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}' -e 'PORT_FREE_TIMEOUT=${PORT_FREE_TIMEOUT:-30}' -e 'AIRSHIP_URL=${AIRSHIP_URL:-http://127.0.0.1:11445/v1}' -e 'IWD_URL=${IWD_URL:-http://127.0.0.1:11446/v1}' -e 'ALIASES=${ALIASES:-claude-opus-5-5 claude-fable-5-1}' -e 'STATE_DIR=/home/inigo/.local/state/9router-fork' common.sh # expect: 11
grep -rn -iE 'acct[12]|ACCT[12]_URL|Claude account [12]' . | wc -l                                  # expect: 0
grep -cF -e '"http://127.0.0.1:$PORT/v1/models" || true)' -e 'readlink "/proc/$main/cwd"' -e '[ "${epid:-0}" = 0 ] || [ "$epid" = "$main" ]' -e 'fork) if [[ $argv == *"$FORK_APP/custom-server.js"* && $cwd == "$fork_real" ]]' common.sh # expect: 4
grep -cF -- "-m 30 -w '%{http_code}'" common.sh                                                    # expect: 1
grep -cF -e 'lsof -nP -iTCP:"$PORT" -t' -e '[ "$(date +%s)" -lt "$deadline" ] || break' -e 'log "port $PORT is still held after ${PORT_FREE_TIMEOUT}s by:"' common.sh # expect: 3
grep -cF -e 'systemd-run --user --quiet --collect --unit="$tunit"' -e '-p KillMode=mixed -p TimeoutStopSec=600' -e 'journalctl --user -u "$tunit" -f -o cat --since "@$t0" &' -e 'exec > >(tee -a "$NINEROUTER_FORK_LOG") 2>&1' common.sh # expect: 4
# The dashboard's update notice: the command it shows, the update action, and the deployed build
grep -cF 'installCmdLatest: "~/code/iwd/9router/zbook/update.sh",' ../src/shared/constants/config.js # expect: 1
grep -cF 'const INSTALL_CMD = UPDATER_CONFIG.installCmdLatest;' ../src/shared/components/Sidebar.js # expect: 1
grep -cF 'updateCommand: UPDATER_CONFIG.installCmdLatest' ../src/app/api/version/route.js        # expect: 1
grep -c -e spawnUpdaterAndExit -e killAppProcesses ../src/app/api/version/update/route.js          # expect: 0
grep -cF '{ status: 409 }' ../src/app/api/version/update/route.js                                  # expect: 1
grep -lF 'not updated from npm' ~/.local/share/9router-fork/app/.next/server/app/api/version/update/route.js | wc -l # expect: 1
grep -rlF 'npm i -g 9router@latest' ~/.local/share/9router-fork/app/.next | wc -l                  # expect: 0
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

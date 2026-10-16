# zbook: the 9router fork and Otterly as systemd user units

Units, environment files and two scripts for running the 9router fork (this branch, with the
`otterly` provider) and two Otterly servers on the zbook, and for switching the live
`nine-router.service` to the fork and back. The fork runs from a standalone build at
`~/.local/share/9router-fork/app/`; Otterly from `~/.local/share/otterly-zbook/`.

## Files

| File | What it is | Installed at |
|---|---|---|
| `otterly@.service` | Template unit: one Otterly server per Claude account, on 127.0.0.1 | `~/.config/systemd/user/otterly@.service` |
| `otterly.env.example` | An instance's environment: Claude config dir, port, trace dir (the `acct1` values) | `~/.config/otterly/acct1.env`; `acct2.env` is the same with `acct2` and port 11446 |
| `nine-router-staging.service` | The fork on 127.0.0.1:20129 with its own data, beside the live service | `~/.config/systemd/user/nine-router-staging.service` |
| `nine-router.service.d/otterly-fork.conf` | Drop-in that runs `nine-router.service` on the fork; `cutover.sh` installs it, `rollback.sh` removes it | `~/.config/systemd/user/nine-router.service.d/otterly-fork.conf` |
| `override.env` | `HOSTNAME` and `PORT` for the fork. `~/.9router/service.env` sets them too; the drop-in reads this file after it, so these values win | `~/.config/9router-fork/override.env` |
| `cutover.sh` | Switches `nine-router.service` to the fork | not installed; run from here |
| `rollback.sh` | Switches it back | not installed; run from here |
| `common.sh` | Settings and health check shared by the two scripts | not installed |

The staging instance keeps its data in `~/.local/share/9router-staging/`, its password in
`~/.config/9router-staging/env` (`INITIAL_PASSWORD`, also stored as the dashboard password) and a
client API key in `~/.config/9router-staging/api-key`. Its database already holds the two Otterly
connections, that API key and the model aliases.

Ports: Otterly 11445 (`acct1`) and 11446 (`acct2`); staging 9router 20129; live 9router 20128.

## Before the cutover

1. Log in each Claude account into its own config dir:
   `CLAUDE_CONFIG_DIR=~/.claude-acct1 ~/.local/share/otterly-zbook/bin/claude auth login`,
   and the same with `acct2`. `claude auth status`, with the same variable, checks it.
2. `systemctl --user start otterly@acct1 otterly@acct2`; then
   `curl -s http://127.0.0.1:11445/api/quota | jq .otterly.account` names the account.
3. To try the fork first: `systemctl --user start nine-router-staging`, dashboard at
   http://127.0.0.1:20129/dashboard. `cutover.sh` stops it again.

## cutover.sh

    ~/code/iwd/9router/zbook/cutover.sh

1. Preflight, read-only: the fork build, the drop-in source and `override.env` exist, no drop-in
   is installed, and `otterly@acct1` and `otterly@acct2` are active and logged in (their
   `/api/quota` names the account). Any failure stops the script with nothing changed.
2. Stops `nine-router.service` and copies `~/.9router` to `~/.9router.pre-fork-<YYYYmmdd-HHMMSS>`.
3. Installs the drop-in, reloads systemd and starts the service.
4. Health check: within 90 s, `GET /v1/models` returns 200 and the service runs the fork. If not,
   it runs `rollback.sh --restore <backup>` and exits non-zero.
5. Enables `otterly@acct1` and `otterly@acct2`, stops and disables `nine-router-staging`, and
   prints the backup path, the dashboard steps for the two Otterly connections, the alias commands
   and the undo command.

## rollback.sh

    ~/code/iwd/9router/zbook/rollback.sh [--restore ~/.9router.pre-fork-<timestamp>]

Stops `nine-router.service`, removes the drop-in, reloads systemd and starts the service on its own
`ExecStart` (the npm package), with the same health check. `--restore` first moves `~/.9router`
aside to `~/.9router.failed-fork-<timestamp>` and copies the backup into its place; without it,
the npm package runs on the data as the fork left it. The Otterly units are left as they are.

When the npm package starts, its launcher kills every `next-server` process of the user, which
includes the staging instance if it is running.

## Settings

Both scripts read these from the environment; the defaults are the live service:
`UNIT=nine-router.service`, `DATA=/home/inigo/.9router`, `PORT=20128`,
`FORK_APP=/home/inigo/.local/share/9router-fork/app`, `HEALTH_TIMEOUT=90`, and for `cutover.sh`
`OVERRIDE_ENV=/home/inigo/.config/9router-fork/override.env`, `SKIP_OTTERLY_CHECK=1` (skips the
Otterly check) and `ALIASES` (the ids in the alias commands, default
`claude-opus-5-5 claude-fable-5-1`). `cutover.sh` writes the drop-in with `PORT`, `FORK_APP` and
`OVERRIDE_ENV` in place of the live values, so a rehearsal against another unit stays off port 20128.

The health check cannot use the main process's command line, because Next.js renames its process
to `next-server (vX)`. It reads the unit's `ExecStart` record and the main process's working
directory instead. The record's `pid=` must be the unit's main PID, or 0, which is what a
`daemon-reload` resets it to.

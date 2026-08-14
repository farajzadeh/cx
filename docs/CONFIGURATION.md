# Configuration

Settings live in `~/.config/cx/config`, seeded from `config.example` on
install and **never overwritten afterwards**. Every setting can also be given
as an environment variable, which takes precedence — useful for one-off
overrides and CI.

```sh
CX_CACHE_TTL=0 cx ls        # bypass the cache once
```

The file is sourced by bash, so comments and shell expansion work. Keep it to
simple `KEY=value` assignments.

## Targets

| Setting | Default | Meaning |
|---|---|---|
| `CX_DEFAULT_HOST` | *(empty)* | Host used when you type a bare project name. Empty means search every server; an ambiguous name then exits 5 and lists the candidates. |
| `CX_PROJECT_ROOT` | `projects` | Where new projects are created on a server. Relative values hang off the remote `$HOME`. Overridable per host with `cx host add --root`. |

## Cache

| Setting | Default | Meaning |
|---|---|---|
| `CX_CACHE_TTL` | `30` | Seconds before cached project data is stale. Stale data still displays immediately, with a background refresh. `0` disables caching. |
| `CX_UNREACHABLE_TTL` | `60` | How long an unreachable server is remembered. This is what stops a powered-off box costing a connection timeout on every command. |
| `CX_STALE_OK` | `0` | `1` accepts cached data of any age and only fetches on `-r`. An offline mode. |

## Connection

Passed to `ssh` as `-o` flags rather than written into `~/.ssh/config`, so cx
never changes how your other SSH sessions behave.

| Setting | Default | Meaning |
|---|---|---|
| `CX_CONNECT_TIMEOUT` | `5` | Seconds before a host is declared unreachable. Keep it low: it bounds how long a dead server stalls a fan-out. |
| `CX_CONTROL_PERSIST` | `10m` | How long an idle multiplexed connection stays open. This is what makes repeat commands fast. |

## Behaviour

| Setting | Default | Meaning |
|---|---|---|
| `CX_EDITOR` | *(empty)* | Editor for `cx host edit`. Falls back to `$VISUAL`, `$EDITOR`, then `vi`. |
| `CX_NO_COLOR` | `0` | `1` disables color. The standard `NO_COLOR` variable works too. |

## Environment-only

Not in the config file; set these in the environment when you need them.

| Variable | Meaning |
|---|---|
| `CX_SSH_CONFIG` | Use a different SSH config file. Needed because OpenSSH resolves `~/.ssh/config` from the passwd database, so setting `HOME` does not redirect it. Note VS Code reads `~/.ssh/config` itself, so `cx code` will not honour this. |
| `CX_ASSUME_YES` | `1` answers yes to every prompt. For scripts and CI. |
| `CX_HOME` | Where cx is installed. Set by the shim; override only for development. |
| `CX_CACHE_DIR` | Cache location (default `~/.cache/cx`). |
| `CX_CONFIG_DIR` | Config location (default `~/.config/cx`). |
| `CX_SSHD_DIR` | Host definitions (default `~/.config/cx/ssh.d`). |

## Driving

| Key | Default | What it does |
|---|---|---|
| `CX_IDLE_GRACE` | `120` | How long a session may go quiet mid-turn before `cx peek` calls it `blocked` rather than `working`. Claude routinely spends a minute inside one tool call, so this is deliberately generous — a false `blocked` costs a pointless nudge, a false `working` costs a driver that waits forever. |
| `CX_PEEK_TAIL` | `6` | How many of a session's last messages `cx peek --json` includes. |
| `CX_GOAL_HOST` | — | Which server holds goals when a command does not name one. Falls back to `CX_DEFAULT_HOST`, then to the only configured server if there is just one. |

## Flags

| Flag | Meaning |
|---|---|
| `-r`, `--refresh` | Force a fetch, ignoring the cache |
| `--no-cache` | Read through without updating the cache |
| `--stale` | Accept cached data of any age |
| `--json` | Machine-readable output |
| `-y`, `--yes` | Assume yes to prompts |
| `--no-color` | Disable color |

Global flags work before or after the subcommand: `cx --json ls` and
`cx ls --json` are equivalent. `-h`/`--help` is deliberately not global, so
`cx host --help` documents `host` rather than printing the top-level usage.

## Per-host settings

Host files under `~/.config/cx/ssh.d/<alias>.conf` are ordinary SSH config
plus `#cx:` metadata comments, which `ssh` ignores:

```
#cx:root=/srv/work        project root on this server
#cx:import=web1           present only for imported hosts

Host web1
    HostName 10.0.0.5
    User deploy
```

Edit with `cx host edit web1`, or by hand — it is just a file.

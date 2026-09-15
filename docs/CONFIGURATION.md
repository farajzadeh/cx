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
| `CX_IDLE_GRACE` | `120` | How long a session may go quiet mid-turn before `cx peek` and `cx bar` call it `blocked` rather than `working`. Claude routinely spends a minute inside one tool call, so this is deliberately generous — a false `blocked` costs a pointless nudge, a false `working` costs a driver that waits forever. |
| `CX_PEEK_TAIL` | `6` | How many of a session's last messages `cx peek --json` includes. |
| `CX_STATE_TTL` | `180` | How old the session-state cache may be before `cx bar --window` stops putting an icon on a tab, and `cx jump` stops trusting it. Refreshed by every `cx bar` and every unnarrowed `cx peek`. |
| `CX_BAR_ICONS` | `unicode` | Which glyphs `cx bar --window` puts on tabs. `unicode` is geometric shapes nearly every font has; `nerd` is Font Awesome glyphs from a Nerd Font, which draw as empty boxes without one. |
| `CX_BAR_COLOR` | `0` | `1` colours the status bar and the tab icons by state. Off by default so your terminal theme's colours are used; `NO_COLOR` and `--no-color` override it. |
| `CX_TMUX_TAG` | `1` | Whether `cx open` records its target on the local tmux window it was launched in, which is what puts a state icon in the tab title. Invisible otherwise. `0` disables it. |
| `CX_TMUX_TITLE` | `0` | `1` also renames that window to the target. Off by default: tmux turns off `automatic-rename` for any window given an explicit name, and that is a lasting change to how your tmux behaves. |
| `CX_SERVER_BAR` | `1` | Whether `cx open` draws the session's facts — state, model, context, usage limits, cost, branch — on the session's own tmux bar **on the server**, the one you see at the bottom once attached. Set per session, never globally, and whatever your server's bar showed on the right is kept after it. `0` leaves the bar alone and installs no status line. Its icons follow `CX_BAR_ICONS`. Needs agent 0.5.0. |
| `CX_GOAL_HOST` | — | Which server holds goals when a command does not name one. Falls back to `CX_DEFAULT_HOST`, then to the only configured server if there is just one. |

## On the server

These live on each server, not on the machine you run cx from.

| Path | What it does |
|---|---|
| `~/.config/cx/notify` | An executable run when a session turns `blocked` or `idle`, with `<target> <state> <message>` and `CX_NOTIFY_HOST` set. Runs in the background, is never waited for, and fires only on a change. Absent means no notifications. `CX_NOTIFY` in the server's environment names a different file. |
| `~/.local/share/cx/state/` | What each session's hooks last reported, and, as `<id>.line`, what Claude last told its status line: the context, cost and usage-limit numbers the session's tmux bar shows. A cache: delete it and cx reads conversations instead. |
| `~/.local/share/cx/cx-driver.agent.md` | The driver's instructions, copied by `cx provision`. Goals with `on-stop` cannot drive themselves without it. |
| `~/.local/share/cx/driving/<goal>.log` | What each self-driving pass printed. |

## The flags, as environment variables

Every global flag is also read from the environment, and deliberately so:
`bin/cx` defaults them with `:=` rather than assigning, so a value you export
survives. That is what lets a script or a CI job set the behaviour once
instead of threading a flag through every call.

| Variable | Flag | Set it to |
|---|---|---|
| `CX_JSON` | `--json` | `1` for machine-readable output |
| `CX_REFRESH` | `-r`, `--refresh` | `1` to always fetch |
| `CX_NO_CACHE` | `--no-cache` | `1` to bypass without writing |
| `CX_FORCE_STALE` | `--stale` | `1` to accept cached data of any age |
| `CX_ASSUME_YES` | `-y`, `--yes` | `1` to answer every prompt yes |
| `CX_NO_COLOR` | `--no-color` | `1` to disable colour (`NO_COLOR` works too) |

```sh
export CX_JSON=1 CX_ASSUME_YES=1     # a cron job that parses output
cx ls | jq '.projects[].name'
```

Resetting these unconditionally at startup would break that, and did once —
hence the `:=`.

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

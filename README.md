# cx

**Run Claude Code on your servers. Manage it from your laptop.**

Claude Code often has to run somewhere other than your laptop — the
credentials live on a server, the code lives on a server, or the work is
long-running and shouldn't die with your SSH session. Once that's true for
more than one machine, you're retyping `ssh` commands and keeping track of
which box has which project in your head.

`cx` makes a fleet of servers feel like one workspace.

```console
$ cx ls
HOST   PROJECT   BRANCH   SESSIONS  ACTIVE  LIVE  REPO
web1   api       main     12        4m      ●     gh:acme/api
web1   dashboard main     3         2d            gh:acme/dashboard
db1    etl       main     7         1h            gh:acme/etl

$ cx open web1:api
# ... attaches a persistent Claude session on web1, resuming where you left off
```

Close your laptop mid-task. Claude keeps working. Run `cx open web1:api` again
from anywhere and you're back in the same conversation.

---

## The one thing to understand

**The client holds no credentials and never runs Claude Code locally.**

Claude runs on your servers, signed in there, one time, interactively. `cx`
only knows how to reach servers over SSH and ask them questions. Nothing about
your Claude sign-in ever passes through the machine you're typing on.

That's the constraint the whole design serves — not a limitation to work
around.

```
CLIENT (no Claude, no credentials)          SERVER (Claude runs here)
┌───────────────────────────────┐          ┌──────────────────────────────┐
│ cx                            │──ssh────▶│ cx-agent                     │
│   reads your ~/.ssh/config    │          │   owns the project registry  │
│   fans out, merges, caches    │◀──JSON───│   drives tmux + Claude Code  │
└───────────────────────────────┘          │ ~/.claude/  ← credentials    │
                                           └──────────────────────────────┘
```

---

## Install

```sh
git clone https://github.com/farajzadeh/cx.git
cd cx
./install.sh
```

Or, if you're comfortable piping curl into a shell:

```sh
curl -fsSL https://raw.githubusercontent.com/farajzadeh/cx/main/install.sh | bash
```

Check what it needs and what it would change, without touching anything:

```sh
./install.sh --check
```

Then add your first server:

```sh
cx host add          # a few questions; offers to set the server up for you
cx login web1        # one-time Claude Code sign-in, on the server
```

**Requirements.** Client: bash 3.2+ (macOS's default works), `ssh` 7.3+,
`jq`, `git`. Servers: any Linux with a package manager `cx` recognises — it
installs `tmux`, `git`, `jq`, `curl` and Claude Code itself. `install.sh
--check` prints the full picture with a fix command for anything missing.

---

## Commands

### Servers

| | |
|---|---|
| `cx host add` | add a server, with connection diagnosis and key setup |
| `cx host import <alias>` | adopt a host already in your `~/.ssh/config` |
| `cx host ls` / `test` / `edit` / `rm` | manage servers |
| `cx provision <host>` / `--all` | install or update the agent (idempotent) |
| `cx login <host>` | one-time Claude Code sign-in |
| `cx doctor` | check this machine and every server |

### Projects

| | |
|---|---|
| `cx new web1:api --repo <url>` | clone a repo into a new project |
| `cx new web1:api` | create an empty git repository |
| `cx ls [host] [--git]` | list projects across servers |
| `cx rm web1:api [--purge]` | unregister (`--purge` also deletes files) |

### Working

| | |
|---|---|
| `cx open web1:api` | attach a Claude session, resuming the last conversation |
| `cx resume web1:api` | attach and pick an older conversation |
| `cx shell web1:api` | plain shell in the project, no Claude |
| `cx code web1:api` | open in VS Code over Remote-SSH |
| `cx ask web1:api "..."` | one-shot question; prints to stdout, no session |
| `cx status` | what's running right now, everywhere |
| `cx stop web1:api` | end a session |

Targets are `host:project`. A bare `project` resolves against
`CX_DEFAULT_HOST`, or across every server when the name is unique — and if
it's ambiguous, `cx` tells you rather than guessing.

---

## Why sessions survive

`cx open` starts Claude inside a `tmux` session named after the project. The
process belongs to the server, not to your SSH connection, so:

- **Your connection drops** → Claude keeps working. Reattach with `cx open`.
- **You close your laptop** → same.
- **The server reboots** → the process dies, but Claude Code's own
  conversation history is on disk, and `cx open` resumes it.

Detach without stopping anything: `Ctrl-b d`.

Re-running `cx open` on a live session **reattaches** — it doesn't start a
second Claude on top of the first.

---

## Speed

`cx ls` reads through a cache, so repeat calls do no network work at all.
Three properties make that safe:

- **Your own changes are never stale.** `cx new`, `cx rm`, `cx stop` and
  friends invalidate their host's cache before returning, so the next `cx ls`
  is correct without `--refresh`.
- **A stale entry never makes you wait.** It prints immediately and refreshes
  in the background — and five rapid calls fork one refresh, not five.
- **A dead server costs one timeout, not one per command.** Unreachable hosts
  are remembered for a minute. Their projects still show from cache, dimmed,
  with a warning that the view is partial.

```sh
cx ls -r          # force a fetch
cx ls --no-cache  # bypass without updating
cx ls --stale     # accept any age (offline mode)
cx cache status   # what's cached, how old, which hosts are down
```

The cache is disposable: `rm -rf ~/.cache/cx` changes speed, never
correctness.

---

## What it does to your machine

`cx` is deliberately conservative about files it doesn't own:

- **One line** added to `~/.ssh/config`: `Include ~/.config/cx/ssh.d/*.conf`.
  Backed up first, shown before it happens, removed by `--uninstall`.
- Servers live in their own files under `~/.config/cx/ssh.d/`. They're
  ordinary SSH hosts — `ssh web1`, `scp`, `rsync` and `git` all work.
- Connection tuning is passed as `ssh -o` flags at call time, so your other
  SSH sessions behave exactly as before.
- Shell rc changes are **printed, not applied**, unless you pass
  `--shell-setup`.

On a server, `cx provision` installs only what's missing, never overwrites an
existing `~/.tmux.conf` or registry, and doesn't invoke `sudo` at all when
there's nothing to install.

---

## Documentation

| | |
|---|---|
| [docs/SERVERS.md](docs/SERVERS.md) | adding servers, SSH keys, bastions, adopting existing configs |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | every setting and environment variable |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | when something doesn't work |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how it works, and why it's built this way |
| [CONTRIBUTING.md](CONTRIBUTING.md) | tests, portability rules, sending a patch |

---

## Status

Early. The core loop — add a server, create projects, open persistent Claude
sessions, list everything — works and is covered by integration tests that run
against real SSH servers in containers.

Interfaces may still change. If you hit something, please open an issue with
the output of `cx doctor`.

## License

MIT — see [LICENSE](LICENSE).

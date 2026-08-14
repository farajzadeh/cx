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
HOST   PROJECT       BRANCH    SESSIONS  ACTIVE  LIVE  REPO
web1   api           main      12        4m      ●2    gh:acme/api
         api/authfix authfix   3         1m      ●
web1   dashboard     main      3         2d            gh:acme/dashboard
db1    etl           main      7         1h            gh:acme/etl

$ cx open web1:api
# ... attaches a persistent Claude session on web1, resuming where you left off
```

Close your laptop mid-task. Claude keeps working. Run `cx open web1:api` again
from anywhere and you're back in the same conversation.

Need to work on two things at once? Give each task a worktree — its own branch
and directory, so parallel Claude sessions can't overwrite each other:

```console
$ cx wt add web1:api/authfix    # then: cx open web1:api/authfix
```

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
| `cx ls [host] [--git]` | list projects and worktrees across servers |
| `cx rm web1:api [--purge]` | unregister (`--purge` also deletes files) |

### Working

| | |
|---|---|
| `cx open web1:api` | attach a Claude session, resuming its conversation |
| `cx open web1:api --dangerously-skip-permissions` | ...with no permission checks |
| `cx resume web1:api` | attach and pick an older conversation |
| `cx shell web1:api` | plain shell in the project, no Claude |
| `cx code web1:api` | open in VS Code over Remote-SSH |
| `cx ask web1:api "..."` | one-shot question; prints to stdout, no session |
| `cx open -d web1:api` | start a session without attaching to it |
| `cx status` | what's running right now, everywhere |
| `cx stop web1:api [--all]` | end a session (`--all`: every one of the project's) |

### Driving

| | |
|---|---|
| `cx peek [target]` | what each session is doing: idle, working, blocked, dead |
| `cx nudge web1:api "..."` | send a prompt to a session that's already running |
| `cx goal new ship "..."` | a definition of done, and who's working on it |
| `cx goal ls` / `show` / `pause` / `resume` / `done` | manage them |
| `cx driver` | print the cx-driver subagent, to install in Claude Code |

### Working in parallel

| | |
|---|---|
| `cx open web1:api@review` | a second conversation on the **same files** |
| `cx wt add web1:api/authfix` | a worktree: its own **branch and directory** |
| `cx wt ls [host[:project]]` | list worktrees |
| `cx wt rm web1:api/authfix [--force]` | remove one (the branch is kept) |

Targets are `host:project[/worktree][@session]`. A bare `project` resolves
against `CX_DEFAULT_HOST`, or across every server when the name is unique —
and if it's ambiguous, `cx` tells you rather than guessing.

---

## Two ways to work on several things at once

They compose, and picking the right one matters:

**`@label` — parallel conversations.** Same directory, same branch, separate
Claude sessions each with their own history. Good for a review thread running
alongside the work, or asking a question without derailing what you were
doing.

```sh
cx open web1:api            # the main thread
cx open web1:api@review     # a second one, same files
cx stop web1:api@review     # end just that one
```

**`/worktree` — parallel branches.** A `git worktree` is a second checkout of
the same repository on its own branch, in its own directory. Two Claude
sessions in two worktrees edit different files and cannot overwrite each
other's work, which two sessions in one directory absolutely can.

```sh
cx wt add web1:api/authfix           # new branch 'authfix', new directory
cx wt add web1:api/bug-123           # a second task, at the same time
cx open   web1:api/authfix           # work on one
cx open   web1:api/bug-123           # and the other, in parallel
cx ls                                # both, with their branches
cx wt rm  web1:api/authfix           # done; the branch stays
```

Worktrees live in `.worktrees/<project>/<name>` beside the project on the
server, so `ls ~/projects` stays readable. cx records nothing about them —
`git worktree list` is the only source of truth, so one you create by hand
over SSH shows up in `cx ls`, and one you delete by hand disappears.

And they nest: `cx open web1:api/authfix@tests` is a second conversation
inside a worktree.

---

## Letting them run themselves

Once you have four sessions going, the problem changes: not *starting* work
but knowing which one needs you. `cx peek` reads each session's own
conversation and says:

```
$ cx peek
HOST   SESSION            STATE    WHO  QUIET
web1   api/authfix@impl   working  —    4s
web1   api/authfix@tests  idle     —    6m
web1   api@review         blocked  —    22m
web2   web                dead     —    —
```

`idle` means the last turn finished and it is waiting for you. `blocked` means
it stopped mid-turn and went quiet — nearly always a permission prompt only
you can answer. `dead` means Claude exited.

`cx nudge` sends the next instruction to one that's ready, without attaching:

```sh
cx nudge web1:api/authfix@tests "the retry test is still failing — fix it"
```

It declines, rather than making a mess, if the session is mid-turn, waiting on
a prompt, or open in front of you. `--force` overrides that.

### Definitions of done

Write down what a set of sessions is *for*, and it stops being something you
have to hold in your head:

```sh
cx goal new auth "the auth tests pass and a PR is open" \
    --member web1:api/authfix@impl \
    --member web2:api@tests

cx goal ls                       # all of them, with state
cx goal dod auth "...new..."     # change your mind; the old text is kept
cx goal pause auth               # stop the driver — nothing is killed
```

Goals live on the server, next to the work, so they outlive this terminal and
look the same from any machine you use.

### The driver

`cx` itself decides nothing. It reports what each session is doing and moves
text between you and them; whether a definition of done has been *met* is a
judgement, and judgement lives in a Claude Code subagent that cx ships:

```sh
cx driver > ~/.claude/agents/cx-driver.md
```

Then ask Claude Code to drive your cx goals. It reads each goal, looks at what
every session is actually doing, sends the next prompt to whichever is ready,
and stops when a goal is paused or done. It never answers a permission prompt
for you, and it never forces a nudge — those are yours.

Because nothing in cx loops, `cx goal pause` really does stop it: there is no
process to signal, only a driver that re-reads the goal each time round.

---

## Why sessions survive

`cx open` starts Claude inside a `tmux` session named after the target. The
process belongs to the server, not to your SSH connection, so:

- **Your connection drops** → Claude keeps working. Reattach with `cx open`.
- **You close your laptop** → same.
- **The server reboots** → the process dies, but Claude Code's own
  conversation history is on disk, and `cx open` resumes it.

Detach without stopping anything: `Ctrl-b d`.

Re-running `cx open` on a live session **reattaches** — it doesn't start a
second Claude on top of the first.

Each session is pinned to its own Claude conversation, so `cx open web1:api`
and `cx open web1:api@review` always come back to the thread you left in that
one — they never collide, however many you run at once.

---

## Skipping permission checks

`--dangerously-skip-permissions` starts Claude with every permission check
bypassed: it edits files and runs commands without asking. Claude Code
recommends this only for sandboxes with no internet access, which is exactly
what a throwaway dev server can be.

```sh
cx open web1:api --dangerously-skip-permissions
cx open web1:api@yolo --dangerously-skip-permissions   # scope it to one session
cx ask  web1:api --dangerously-skip-permissions "fix the failing test"
```

Two things worth knowing:

- **It applies when the session is created, not when you reattach.** A live
  session's permission mode cannot be changed, so to turn it off, `cx stop`
  the session and open it again. Passing the flag to a session that is already
  running says so rather than pretending it took effect.
- **cx remembers which sessions were started that way** and marks them in
  `cx status`, because from inside an attached session there is no way to
  tell:

```console
$ cx status
HOST   PROJECT   SESSION   MODE      STATE      UPTIME
web1   api       —                   attached   12m
web1   api       yolo      no-perms  detached   3m
```

Scoping it to a `@label` — or better, to a worktree — keeps the unguarded
session away from the work you care about.

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
| [docs/cx-driver.agent.md](docs/cx-driver.agent.md) | the driver subagent, as `cx driver` prints it |
| [CONTRIBUTING.md](CONTRIBUTING.md) | tests, portability rules, sending a patch |
| [issues/](issues/) | known issues not yet fixed, with full context |

---

## Status

Early. The core loop — add a server, create projects, open persistent Claude
sessions, list everything — works and is covered by integration tests that run
against real SSH servers in containers.

Interfaces may still change. If you hit something, please open an issue with
the output of `cx doctor`.

## License

MIT — see [LICENSE](LICENSE).

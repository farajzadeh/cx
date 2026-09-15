# Troubleshooting

Start here:

```sh
cx doctor
```

It checks this machine and every server, and names the fix for anything wrong.

---

## Installation

### `cx: command not found` after installing

`~/.local/bin` is not on your `PATH`. The installer prints the lines to add
but does not edit your shell config unless you ask:

```sh
./install.sh --shell-setup     # shows a diff, then appends
```

Or add it yourself and restart your shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### `install.sh --check` says jq is missing

`jq` is the one dependency most people do not already have. The check prints
the exact command for your platform — `sudo apt-get install -y jq`,
`brew install jq`, `sudo dnf install -y jq`, and so on.

### The installer refuses to run on macOS

If it reports a bash version below 3.2 something unusual is going on — macOS
has shipped 3.2 for years and that is the floor cx targets. Report it.

### `cx: broken installation`

The tree at `~/.local/share/cx` is missing or incomplete. Re-run
`./install.sh` to repair it.

---

## Servers

### A host is not listed by `cx host ls`

Either there is no file for it in `~/.config/cx/ssh.d/`, or the `Include` line
is missing from `~/.ssh/config`. Check:

```sh
grep 'cx/ssh.d' ~/.ssh/config
```

If it is absent, re-run `./install.sh`, or add it yourself **at the top** of
the file (ssh uses first-match-wins, so position matters):

```
Include ~/.config/cx/ssh.d/*.conf
```

### `cx host test` says `auth`

SSH reached the server and your credentials were rejected.

```sh
ssh-copy-id web1        # cx host add offers to do this for you
ssh -v web1             # see which keys were offered
```

If you have many keys, the server may hit `MaxAuthTries` before reaching the
right one. cx-managed hosts set `IdentitiesOnly yes` to avoid that; imported
hosts follow whatever your own config says.

### `cx host test` says `timeout`

No response at all — a firewall, a wrong address, or a VPN you are not
connected to. `ping` the hostname and check `HostName` with
`cx host edit <alias>`.

### `cx host test` says `hostkey`

The server's host key does not match your `known_hosts` entry.

If the server was genuinely rebuilt:

```sh
ssh-keygen -R <hostname>
```

**If it was not rebuilt, stop and investigate.** This is what an intercepted
connection looks like.

### Provisioning fails with `No supported package manager`

The server has none of apt-get, dnf, yum, pacman, zypper or apk. Install
`tmux`, `git`, `jq` and `curl` by hand, then re-run `cx provision` — it
installs nothing when nothing is missing.

### Provisioning asks for a sudo password in a script

`cx provision` only requests a TTY when it has one. In a pipeline or CI, sudo
must already be passwordless. On a server that is fully set up, `cx provision`
never invokes sudo at all.

---

## Claude

### `NOT SIGNED IN`

Sign-in is interactive and happens once per server:

```sh
cx login web1
```

Credentials are stored on that server and never reach your machine — that is
the point of the design, not an oversight.

### `claude: command not found` on the server

Almost always PATH. A non-interactive `ssh host cmd` does not read `.bashrc`,
and `~/.profile` is only read by login shells. `cx` calls the agent by
absolute path for this reason, and provisioning adds `~/.local/bin` to
`~/.profile`.

Check what the server actually sees:

```sh
ssh web1 'command -v claude || echo missing'
ssh web1 'ls ~/.local/bin/'
```

Re-run `cx provision web1` to reinstall.

### The `SESSIONS` column shows `?`

cx could not find Claude Code's session store on that server. That is expected
before Claude has ever run there. If it persists after real usage, the storage
layout may have changed — see the note in
[ARCHITECTURE.md](ARCHITECTURE.md#the-claude-session-store--a-known-assumption).
The column degrades on purpose; nothing else is affected.

---

## Sessions

### `cx open` says the agent is not installed

```sh
cx provision web1
```

### My session disappeared after the server rebooted

The tmux process died with the reboot. The conversation itself is on disk, so
`cx open` starts a new session and resumes it. Anything Claude was midway
through when the machine went down is lost.

### `cx open` reattaches but Claude is not running

The Claude process exited at some point — the shell it was running in stays,
by design, so you keep the session and its scrollback. Just run `claude` again
in that pane, or `cx stop` and `cx open` for a clean start.

### The display is squashed after reconnecting

That is tmux sizing the window to the smallest attached client. `cx open`
passes `attach -d` to detach stale clients, so this should not happen — if it
does, check for a genuine second attachment:

```sh
ssh web1 'tmux list-clients'
```

### `the cx agent on web1 is too old for worktrees and named sessions`

Worktrees and `@label` sessions need agent 0.2.0 or newer. Plain targets keep
working against an older one, which is why this only appears when you use the
new syntax.

```sh
cx provision web1
```

### A named session started a new conversation instead of resuming

Each session's conversation id is pinned in `~/.local/share/cx/sessions.json`
on the server. If that file was deleted, the pin is gone and the next open
starts fresh — the old conversation is still on disk, so recover it with the
picker:

```sh
cx resume web1:api
```

### `--dangerously-skip-permissions` seems to have been ignored

It only applies when the session is **created**. If the session was already
running, cx says so and attaches to it unchanged. Stop it first:

```sh
cx stop web1:api
cx open web1:api --dangerously-skip-permissions
```

### Which of my sessions are running without permission checks?

```sh
cx status
```

Sessions started that way are marked `no-perms` in the MODE column. There is
no way to tell from inside an attached session, which is why cx records it.

### `--dangerously-skip-permissions` is refused on the server

Claude Code declines to bypass permission checks when it is running as root.
cx runs Claude as whatever user you SSH in as, so use a normal account rather
than root for that host.

### `cx open` and `cx open ...@label` seem to share one conversation

They should not: each pins its own. Check what is actually recorded:

```sh
ssh web1 'jq . ~/.local/share/cx/sessions.json'
```

Two entries with the same `uuid` means the file was edited or restored by
hand. Delete the offending entry and reopen that session.

---

## Worktrees

### `cx wt add` says `no commits yet`

`git worktree add` needs a commit to branch from, and `cx new` leaves a fresh
project with an empty repository. Make one first:

```sh
cx shell web1:api      # then: git commit --allow-empty -m init
```

### `cx wt rm` says the worktree has uncommitted changes

Deliberate — it refuses before stopping anything, so nothing is lost and your
session keeps running. Commit the work, or discard it explicitly:

```sh
cx wt rm web1:api/authfix --force
```

### A worktree I made by hand does not appear

It should: cx reads `git worktree list` rather than a stored copy. Force a
fetch, since `cx ls` answers from cache by default:

```sh
cx ls -r
```

If it still does not show, confirm git itself knows about it:

```sh
ssh web1 'git -C ~/projects/api worktree list'
```

### I removed a worktree with plain `git` and its branch is still there

That is also what `cx wt rm` does. Removing a worktree never deletes its
branch, so committed work survives. Delete the branch yourself if you want it
gone:

```sh
ssh web1 'git -C ~/projects/api branch -d authfix'
```

---

## Listing and the cache

### `cx ls` shows stale information

It should not: every command that changes server state invalidates its host's
cache before returning. If you see it anyway, force a fetch and please report
it:

```sh
cx ls -r
cx cache status     # shows the age of every entry
```

### `cx ls` is slow

```sh
cx cache status
```

- **Every host says `not cached`** — the cache is not being written. Check
  that `~/.cache/cx` is writable.
- **A host shows `unreachable`** — that one is down. Its projects still show
  from cache, and it is skipped without connecting until the mark expires.
- **Consistently slow even warm** — SSH multiplexing may not be engaging.
  Check `ls ~/.ssh/cm-*` after a command; if nothing appears, the socket path
  may be too long or `~/.ssh` may not be writable.

### One dead server slows everything

It should cost about five seconds once, then nothing. If every command is
slow, `CX_UNREACHABLE_TTL` may be `0`. Check with `cx cache status`.

### Working offline

```sh
CX_STALE_OK=1 cx ls
```

Renders entirely from cache, at any age, fetching nothing.

---

## Driving sessions

### A session says `blocked` but it is just working

For a session Claude Code reports on — anything started by a current cx, on
Claude Code 2.1 or later — `blocked` means a permission prompt is on screen,
and `working` stays `working` through a long, quiet tool call.

For an older session there is no report, and cx reads the conversation instead:
a turn that has been silent longer than `CX_IDLE_GRACE` (120 s) is called
`blocked`, because that is usually a prompt. A long build is the exception.
Restart the session to get exact states: `cx stop <target>`, then `cx open`.

### Notifications never arrive

- **The notifier is on the wrong machine.** It runs on the *server*:
  `~/.config/cx/notify` there, executable (`chmod +x`).
- **The session predates the hooks.** Only sessions started by agent 0.4.0 or
  later, without `--no-hooks`, report. `cx provision <host>`, then restart the
  session.
- **It only fires on a change** into `blocked` or `idle` — a session that stays
  waiting is not news twice. Test the script by hand:
  `CX_NOTIFY_HOST=test ~/.config/cx/notify api idle "hello"`.

### `cx peek` says `unknown`

cx could not read that session's conversation. Two harmless causes:

- **No conversation is pinned.** Sessions started before cx 0.2.0 have no
  pinned id. `cx stop <target>` and open it again to pin one.
- **Claude Code's storage layout changed.** cx reads
  `~/.claude/projects/<encoded-path>/*.jsonl`, which is an observed layout
  rather than a documented API. It degrades to `unknown` on purpose — nothing
  else breaks, and `cx open` keeps working.

### `cx peek` says `dead` but the session looks fine

cx calls a session dead when the pane's foreground process is a shell, which
normally means Claude exited. It will also say that if your `claude` is a
wrapper script that does not `exec` the real binary, since the pane then shows
the wrapper's interpreter. Check with:

```sh
cx shell <host>            # then, on the server:
tmux list-panes -a -F '#{session_name} #{pane_current_command}'
```

The error is in the safe direction: cx will refuse to nudge such a session
rather than typing your prompt into a shell.

### A session is stuck on `starting`

Claude has not finished starting. For more than a few seconds, that is almost
always its **"do you trust this folder?"** prompt, which it shows the first time
it runs in a directory — and which blocks everything until answered. Answer it
once and the session behaves normally from then on:

```sh
cx open <target>
```

cx refuses to nudge a session in this state, and that is deliberate: the
prompt has **"No, exit" selected**, so the Enter that sends a prompt would end
Claude and the session with it. `cx nudge --force` overrides the refusal, and
on that prompt it will do exactly that.

### A session is stuck on `fresh`

`fresh` means Claude is up and ready, but this conversation has never been
written to. Claude writes nothing until its first exchange, so this is normal
right after `cx open -d` — and it stays true if nobody has sent it anything.
Send it one: `cx nudge <target> "..."`.

### `cx nudge` says "has not finished starting — not sent"

See "A session is stuck on `starting`" above: answer the trust prompt with
`cx open <target>`, then nudge again.

### `cx nudge` says "is mid-turn — not sent"

Working as intended. Nudging a session that is mid-turn interleaves your text
with what Claude is already doing. Wait for `cx peek` to show `idle`, or
override deliberately:

```sh
cx nudge <target> --force "stop what you are doing and ..."
```

A declined nudge exits 0, not an error — a driver in a loop needs to tell
"busy, come back" apart from "this is broken".

### `cx nudge` says "has gone quiet mid-turn"

The session stopped part-way through a turn and has not written anything for
`CX_IDLE_GRACE` seconds (120 by default). Nearly always a permission prompt
that only you can answer:

```sh
cx open <target>
```

If your work legitimately involves long tool calls, raise the threshold in
`~/.config/cx/config`:

```sh
CX_IDLE_GRACE=600
```

### `cx ask` says "a second claude on its conversation would lose turns"

`cx ask <target>@<label>` joins that named session's conversation. If the
session is running, a second `claude` resuming the same conversation gives two
processes appending to one transcript with no merge, and one of them loses its
turns silently. cx refuses instead. Use `cx nudge` to talk to a live session,
or `cx ask` without the label for a one-shot with no shared history.

### The tmux status bar stays empty

`cx bar` prints nothing when nothing is waiting — that is the design, so the
bar collapses instead of holding space. Check what it would say:

```sh
cx bar --plain          # what tmux is being given
cx peek                 # every session, whatever state it is in
```

If `cx bar` prints something in your terminal and tmux still shows nothing:

- **tmux cannot find cx.** Status commands run under the environment the tmux
  server started with, which usually has no `~/.local/bin`. Use the absolute
  path — `cx bar --setup` prints it for you.
- **`status-interval` is 0**, which disables timed redraws entirely.
- **`status-right-length`** is too short and the line is being cut off.

### The status bar shows `!host`

That server did not give a usable answer, and the bar says so rather than
passing over it — an empty bar has to mean "nothing needs you", not "cx could
not tell". One line cannot say why, so ask:

```sh
cx host test <host>       # is it reachable at all?
cx peek                   # peek has room to explain, and does
```

Two causes. Either it is **unreachable**, which cx remembers for a minute so
the bar does not wait on it again — the marker clears itself as soon as the
server answers — or its **agent is too old to observe** (0.3.0 or newer),
which `cx peek` says in words and `cx provision <host>` fixes.

Seen from inside tmux only, this is usually SSH keys rather than the server:
if your key needs an agent, the tmux server has to see `SSH_AUTH_SOCK`. Add it
to `update-environment`, or run any cx command from a terminal first — the
shared connection cx opens is reused for the next while.

### The tabs have no icons

The per-tab lookup reads a cache and never fetches, so an empty tab means the
cache cannot answer. In order of likelihood:

```sh
cx bar --plain                       # does the aggregate line work at all?
cat ~/.cache/cx/state                # what the tabs are reading
tmux list-windows -F '#I #W [#{@cx_target}]'   # is the window tagged?
```

- **No `status-right` line.** The tabs read the cache; the line on the right is
  what refreshes it. Without it nothing does, and after `CX_STATE_TTL` the icons
  stop. Keep both halves of `cx bar --setup`.
- **The window is not tagged.** Only a window `cx open` was actually run in
  carries `@cx_target`. A tab where you ran `ssh` yourself, or attached to tmux
  by hand, has nothing to look up. Tag it with
  `tmux set -w @cx_target <host>:<target>`.
- **`CX_TMUX_TAG=0`** in your config turns the tagging off entirely.

### The tab icons are empty boxes

Your font does not have those glyphs. The default set is plain geometric shapes
nearly every font carries; `CX_BAR_ICONS=nerd` switches to Font Awesome glyphs
that only a Nerd Font has. Remove that line from `~/.config/cx/config`, or set
the terminal to a Nerd Font such as MesloLGS NF.

If the boxes appear only inside tmux, the client is probably not in UTF-8 mode:
`tmux list-clients -F '#{client_utf8}'` should print `1`. tmux decides from
`LANG` / `LC_ALL` when the client starts.

### A tab and another terminal keep stealing a session from each other

That happens only where attaching has to detach everyone else: a server whose
tmux is older than 3.1, or whose agent is older than 0.4.0. There, a dropped
SSH connection leaves a phantom client that would pin the window to its size,
and `tmux attach -d` is the fix — at the cost that a tab and a terminal throw
each other out. Check with `cx provision <host>`; on tmux 3.1+ both stay
attached. Until then `cx tabs` skips sessions held elsewhere unless `--take`.

### `cx jump` says nothing is waiting, or that there is no recent state

It reads the same cache as the tab icons. "No recent session state" means the
status line that refreshes it is not running — keep the `status-right` line
from `cx bar --setup`, or use `cx jump -r` to fetch first. "Has no tab" means the
waiting session is not open in a tab: `cx open` it in one.

### The server's tmux bar shows no context, cost or limits

The bar at the bottom of an attached session is drawn on the server, from what
Claude tells its status line. A session shows only a model and a token count —
no percentage, cost or limits — when Claude never ran cx's status line:

- **It was started before agent 0.5.0.** `cx provision <host>`, then restart the
  session (`cx stop`, `cx open`). Re-opening alone draws the bar but cannot add
  a status line to a Claude that is already running.
- **It was started with `CX_SERVER_BAR=0`.**
- **The limits appear after the first reply.** Claude learns them from the API,
  so a session nobody has sent anything shows context and model only. They are
  a Claude subscription's limits; with an API key there are none to show.

### The server's tmux bar is not there at all

`cx open` sets it each time it opens a session, so an older session gets it the
next time you open it. Check with
`tmux show-options -t '=cx-<project>' status-right` on the server; empty means
cx did not set it — the agent is older than 0.5.0 or `CX_SERVER_BAR=0`. It is set
on that session only, and keeps what your server's bar had on the right as it
was when the session was opened, so a change to your server's `~/.tmux.conf`
reaches a cx session when you next open it.

### Claude shows an empty row under its prompt box

That row is the status line cx gives Claude, which is how the server's tmux bar
learns the context, cost and usage numbers. Claude keeps a row for any status
line, and cx's prints nothing there, since the numbers go to the tmux bar
instead. A status line of your own fills the row as before: cx runs it. To have
the row back, set `CX_SERVER_BAR=0` and restart the session (`cx stop`,
`cx open`) — the status line is fixed when Claude starts.

### A goal with `on-stop` never drives itself

`cx goal show <name>` says why, in its log: `on-stop-failed` (no driver on the
server — run `cx provision`; or no Claude Code there) or `on-stop-capped` (it
already ran its hourly maximum). No entry at all means no member finished a
turn with hooks: the member must be started by agent 0.4.0 without
`--no-hooks`, and named in the goal exactly as its session is
(`cx goal show` lists them). A pass's own output is in
`~/.local/share/cx/driving/<goal>.log` on the server.

### `cx wt rm --merged` kept a worktree

It says why for each one. "Has commits that are not in main" — the branch has
work the project does not; merge it first. "Has uncommitted changes" — commit or
discard them. "Has a running session" — `cx stop` it. Nothing is removed on a
guess.

### `cx forget` refuses: "is running"

Its pin is what the next `cx open` resumes, so forgetting a live session would
start a second conversation on top of the running one. `cx stop` it first.

### The status bar is costing too many connections

Each redraw is one SSH round trip per server. Raise the interval:

```tmux
set -g status-interval 60
```

There is no cx-side interval to change, deliberately: cx has no loop anywhere,
and whatever calls it owns the pacing.

### The driver will not stop

`cx goal pause <name>`. Nothing in cx loops, so there is no process to kill —
the driver re-reads the goal each pass and stops when it is not `active`. If
it is a Claude Code subagent, you can also just stop talking to it.

Pausing touches no session: everything stays exactly where it was.

### `the cx agent on <host> is too old for observing and steering`

`cx peek`, `cx bar`, `cx nudge` and `cx goal` need agent 0.3.0 or newer.

```sh
cx provision <host>
```

Existing sessions are unaffected — the agent is only run per command, never
kept alive.

---

### `<project> has no commits yet — commit something before adding a worktree`

A git worktree branches from a commit, and `cx new` without `--repo` leaves
you an empty repository. Make one commit and the worktree works:

```sh
cx shell web1:api
# then, on the server:
git commit --allow-empty -m "init"
```

cx checks for this rather than letting git's `fatal: invalid reference` out,
because that message names a branch you never asked for.

## Targets

### `'api' exists on more than one server`

Exactly what it says — cx refuses to guess. Name the host:

```sh
cx open web1:api
```

Or set `CX_DEFAULT_HOST` in `~/.config/cx/config` so bare names resolve to one
server.

### `no project named 'x' on any server`

```sh
cx ls               # what exists
cx new web1:x       # create it
```

If you expected it to exist, the server holding it may be unreachable — check
for an `unreachable` warning under the listing.

### `invalid worktree name` or `invalid session label`

Both may use only letters, digits, underscore and hyphen — no dots. tmux
silently rewrites a dot in a session name to an underscore, which would make
the session unmappable back to what it names, so cx rejects it up front.
Project names are the exception and still allow dots.

### `a project name cannot contain '/' or '@'`

Those are target syntax: `/` selects a worktree and `@` selects a session, so
neither can be part of a name. To create a project and then a worktree in it:

```sh
cx new    web1:api
cx wt add web1:api/authfix
```

---

## Shell completion

### Tab completion does nothing

Completion reads `~/.cache/cx/targets`, which is written by any listing:

```sh
cx ls
```

It deliberately performs no network work, so it will never hang — but it also
will not populate itself until something has listed projects at least once.

Confirm the completion file is sourced (`--shell-setup` adds this):

```sh
[ -f "$HOME/.local/share/cx/completions/cx.bash" ] && . "$HOME/.local/share/cx/completions/cx.bash"
```

---

## Still stuck

Open an issue with:

```sh
cx doctor
cx --version
bash --version | head -1
uname -a
```

If it involves a specific server, `cx host test <alias>` output helps too.
Redact hostnames as needed — the failure classification is the useful part.

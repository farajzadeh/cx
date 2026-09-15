# Architecture

How `cx` works, and why it is built this way. Read this before changing
anything structural.

## The constraint everything follows from

Claude Code is authenticated **on the servers**, never on the client. That is
a given, not a design choice — and every other decision falls out of it:

- The client cannot run Claude, so it must ask servers to.
- Credentials must never traverse the client, so sign-in is interactive and
  happens on the server (`cx login` just opens a shell there and gets out of
  the way).
- The client is therefore a thin, stateless thing that could be reinstalled
  or replaced at any moment without losing anything.

```
CLIENT                                      SERVER
┌──────────────────────────────┐           ┌──────────────────────────────────┐
│ bin/cx        dispatch       │           │ cx-agent                         │
│ lib/compat    portability    │──ssh─────▶│   registry (projects.json)       │
│ lib/hosts     which servers  │           │   tmux orchestration             │
│ lib/remote    transport      │◀──JSON────│   claude invocation              │
│ lib/cache     read-through   │           │   session-store scanning         │
│ lib/target    host:project   │           │                                  │
│ lib/projects  fan-out        │           │ ~/.claude/  ← credentials        │
│ ~/.cache/cx   disposable     │           │ ~/projects/ ← the actual work    │
└──────────────────────────────┘           └──────────────────────────────────┘
```

## Invariants

These are load-bearing. Breaking one produces a bug that is hard to see and
easy to reintroduce.

### 1. The client never builds shell command strings

Every remote action goes through `cx_agent`, which runs each argument through
`cx_remote_quote` before handing it to `ssh`.

`ssh` joins its command arguments with spaces and gives the result to the
remote login shell, which re-splits on whitespace. Anything not quoted is
reinterpreted on the far side. This is why `cx new web1:"my project"` and
`cx ask web1:api '$(whoami)'` are safe.

`cx ask` goes further and sends the prompt over **stdin**, so it never passes
through a shell at all and has no length limit.

### 2. The agent's stdout is machine-readable; stderr is for humans

`cx-agent` prints JSON on stdout and progress and errors on stderr. The client
captures stdout and lets stderr flow to the terminal.

Merging them with `2>&1` corrupts the payload the moment the agent logs
anything — this caused a real bug where `cx new` succeeded silently because a
`git clone` progress line ended up inside the JSON.

### 3. The cache is never a source of truth

`rm -rf ~/.cache/cx` must change speed and nothing else. Every cached value is
re-derivable from a server. Corollary: anything that changes server state
invalidates its host's entry **synchronously**, before returning.

### 4. Servers own their own registries

Each server's `~/.local/share/cx/projects.json` is authoritative for that
server. The client merges, never stores. This survives a client reinstall,
works identically from a second machine, and cannot drift from reality.

### 5. Only derivable data is derived, never stored

`branch`, `dirty`, `tmux_live`, `tmux_count`, `sessions`, `last_active` and
`worktrees` are computed fresh on every `list`. Only `name`, `path`, `repo`
and `created_at` are recorded — the things that genuinely cannot be
recomputed.

Worktrees are the clearest case. `git worktree list --porcelain` already
knows about them, so cx writes nothing down. The payoff is that drift is
impossible by construction: a worktree created by hand over SSH appears in
`cx ls` without cx being told, and one removed with plain `git` disappears
from it. A stored copy would have needed reconciliation logic that could only
ever be wrong.

### 6. A session is a pinned conversation, not a directory

`claude --continue` means "the newest conversation in this directory". Two
sessions on one project are two panes in the same directory, so both resolve
to the same conversation and the second hijacks the first — which is why
parallel sessions were not possible before.

So each cx session pins a Claude session id, recorded on the server in
`~/.local/share/cx/sessions.json` keyed by `project[/worktree][@label]`. The
agent launches `--session-id <uuid>` the first time and `--resume <uuid>`
afterwards, choosing by whether that conversation's `.jsonl` exists yet.

The file is a cache of ids, not state cx owns: delete it and every session
starts a fresh conversation — annoying, not broken.

### 7. cx contains no judgment, and therefore no loop

The client and agent classify *structure* — does this transcript's last
main-thread message end in `stop_reason: end_turn` — and never *meaning* — is
this definition of done met. Meaning belongs to the driver subagent
(`docs/cx-driver.agent.md`), which reaches cx only through the CLI.

The corollary is the load-bearing half: every verb is one-shot and returns.
No `--follow`, no `--wait`, no daemon, nothing that polls.

That is forced rather than chosen. A client daemon contradicts "a thin,
stateless thing that could be reinstalled or replaced at any moment". A server
daemon would need a driver Claude with its own conversation and session pin,
which is a recursion into the problem being solved. And mechanically there is
no `timeout(1)`, no `wait -n` and no `setsid`, so any loop written here is a
hand-rolled `sleep` holding an SSH connection open for its duration.

Two user-visible consequences follow directly. `cx goal pause` works without
touching anything, because there is no process to signal — only a driver that
re-reads the goal each pass and stops. And `cx nudge` declines a busy session
rather than queueing, because cx has nowhere to keep a queue that is not state
it owns, and draining one would need the daemon it does not have.

### 8. One conversation, one writer

A Claude conversation id is owned by exactly one live process. Running
`claude -p --resume <uuid>` against a uuid that a tmux session is already
holding gives two writers appending to a single transcript with no merge, and
the turns of whichever loses are silently orphaned.

`cx ask <target>@<label>` did exactly this until 0.3.0. It now refuses with
exit 4 when that session is live and points at `cx nudge` instead.

Steering a running session is `tmux send-keys` into its pane — never a second
`claude`. The text goes through a paste buffer (`load-buffer` from stdin,
`paste-buffer -d`, then `C-m`) rather than as a `send-keys` argument, because a
multi-line prompt is impossible with `send-keys` — the first newline submits —
and because this way the prompt never becomes part of a command line on either
side of the wire.

## Portability

The client targets **bash 3.2** (macOS's default) and BSD userland. See
`lib/compat.sh` and `test/lint-portability.sh`.

Two shims deserve explanation:

- **Locking uses `mkdir`, not `flock`.** `flock(1)` is Linux-only. `mkdir` is
  atomic on every POSIX filesystem including NFS. A PID file inside lets a
  stale lock be reaped.
- **`ssh -F` is how the SSH config is overridden.** OpenSSH resolves
  `~/.ssh/config` from the passwd database, *not* from `$HOME` — so setting
  `HOME` does not redirect it. `CX_SSH_CONFIG` exists because of this, and it
  is what makes the test suite hermetic.

`server/bootstrap.sh` is **POSIX sh**, not bash: a minimal server (Alpine, some
container images) may have no bash, and bootstrap is what installs it. It is
tested under busybox `ash`.

`server/cx-agent` is **one file with no dependencies** because it is `scp`'d
to servers as a single artifact. It duplicates a little of `compat.sh` for
that reason. Do not factor it into `lib/`.

## Driving sessions

Four commands, and the split between them is invariant 7 made concrete.

**`cx peek`** — the agent's `observe` verb reports raw facts per session: tmux
liveness, whether the pane's foreground process is a shell, the transcript's
mtime, and its last main-thread message. `lib/activity.sh` turns those into a
state. The classifier is on the client because the threshold is the user's
(`CX_IDLE_GRACE`) and because a pure function is the only part of this that a
unit test can pin — inside the monolithic agent it would be untestable.

| state | meaning |
|---|---|
| `dead` | no tmux session, or the pane is back at a shell |
| `fresh` | up, but this conversation has not been written to yet |
| `idle` | the last turn finished; it is waiting for a human |
| `working` | the transcript is still moving |
| `blocked` | mid-turn and quiet past the grace period |
| `unknown` | nothing readable |

`idle` is tested before `working`, deliberately: a turn that ended two seconds
ago is idle, not busy — the file is fresh precisely *because* Claude stopped.
And `fresh` never expires, because Claude writes no transcript until its first
exchange, so "just started" and "nobody has given it anything to do" are the
same fact; whether that has gone on too long depends on what the caller has
already sent, which only the caller knows.

**Where the state comes from.** Three sources, most trusted first: Claude
Code's own status file (`~/.claude/sessions/<pid>.json`: `idle`, `busy`, or
`waiting` for a permission prompt), then what the session's hooks last reported
through `cx-agent event`, then the transcript. The first two are exact and the
third is inference. The status file outranks the hook because an Escape at a
permission prompt fires no hook at all, so a hook's `blocked` can outlive the
prompt. Both are observed rather than documented, like the transcript layout,
and both degrade to the transcript reading when absent.

**`cx bar`** — the same classification, rendered as one line for a tmux status
bar: which sessions are waiting for a human, blocked before idle, and nothing
at all when the answer is none. It shares `cx_activity_rows` with peek and adds
only presentation, which is the reason that function lives in `lib/activity.sh`
rather than beside either command.

It is where the corollary to invariant 7 gets its real test, because a status
bar is a polling loop by nature. The loop is tmux's: `cx bar` runs once and
returns, and `status-interval` decides how often, exactly as a person or a
driver agent decides how often to run `cx peek`. Two things it does differently
from peek, both because it is called unattended and repeatedly:

- **A server that just failed to connect is skipped rather than waited on.**
  The negative cache is read, and written when — and only when — ssh itself
  exits 255, so a powered-off laptop costs one `ConnectTimeout` a minute
  instead of one per redraw. Any other exit status came back from the far side,
  which means the host is up and something else is wrong; marking that down
  would make `cx ls` lie about it. Speed only, per invariant 4: every redraw
  that does reach a server reads it live.
- **Failure is silent and exit 0**, with one exception. A status line is not a
  place to report an error: it has one line, it is redrawn every few seconds,
  and whoever glances at it is not in a position to act. The exception is a
  server that could not be reached, which is named `!host` — an empty bar has
  to mean "nothing needs you", and a bar that empties out when the VPN drops
  would be saying something false.

**`cx bar --window <target>`** — one tmux tab's state, as a single glyph. Run
once per window on every status redraw, so it does no network work whatsoever:
it reads `~/.cache/cx/state`, which every `cx bar` and every unnarrowed
`cx peek` rewrites as a side effect. Exactly the arrangement shell completion
has with the `targets` file, for exactly the same reason — a status line that
blocks is worse than one that is thirty seconds old.

It prints **nothing** for anything it cannot answer: no target, no cache, a
cache older than `CX_STATE_TTL`, or a session it has never seen. A tab that is
not a cx tab has to look exactly as it always did, and an icon asserted from a
stale file is worse than no icon.

The window learns its target from `cx open`, which records it as a tmux window
user option before handing over the terminal. Addressed by `$TMUX_PANE` rather
than "the current window": current means the session's *active* window, so a
tab opening in the background tags somebody else's — nine tabs opened at once
all tagged the last one created and the other eight silently got nothing.

Two places attached to one session used to take it from each other: the agent
attached with `tmux attach -d` so a phantom client left by a dropped SSH
connection could not size the window, and `-d` threw out every real client too.
On tmux 3.1 and later it sets `window-size latest` and attaches without `-d`,
since a phantom is never the latest client.

**The session's own tmux bar** — once attached, the bar at the bottom belongs to
the *server's* tmux, and `cx open` puts that session's facts in it: state,
model, how full the context is, the five-hour and weekly usage limits, cost,
lines changed, branch, and any other cx session showing a permission prompt.
Two agent verbs and a file between them. Claude runs `cx-agent statusline` as
the status-line command `cx open` passes in `--settings`, hands it those numbers
at startup and after every turn, and it keeps a copy in
`state/<session_id>.line`; tmux runs `cx-agent tmux-status <slug>` from the
session's `status-right` and it prints one line from that copy and Claude's
status file for the pane's own process.

Neither is a loop — Claude and tmux do the calling — and neither is
load-bearing. The numbers are Claude's own (its context percentage, not one
worked out here), observed rather than documented like the rest of its storage;
a session that never ran cx's status line shows the model and token count from
its transcript instead. Usage limits are the account's, not a session's, so every
session shows them from the newest reading on the server: any session's last
status line, or the copy of its `/usage` screen Claude keeps in
`~/.claude.json`, which is refreshed rarely and so carries its age once it is
older than fifteen minutes. Two choices keep it out of the user's way. The options
are set on the one tmux session, never globally, with whatever was on the right
kept after cx's part. And `--settings` outranks the user's own settings files,
so `statusline` runs *their* status-line command, if they have one, with the
same input and prints what it prints: installing cx's must not take theirs away.

**`cx tabs`** — a tmux tab per live session, on the machine cx is running on.
The only command that drives tmux on the *client*, which is less of a departure
than it looks: cx still runs no Claude here and keeps no state here, every
window it opens is a plain `cx open`, and arranging the user's own terminal is
what a client is for.

It asks the agent's `sessions` verb rather than `observe` — "is there a tmux
session" is a tmux question answered in about a second, while observe reads a
transcript per session and takes six. The state beside each tab comes free from
the cache `cx bar` keeps, and is allowed to be missing.

One shot, like everything else: it builds windows and hands over the terminal.
It does not watch for new sessions or close tabs whose session ended. Re-running
is the mechanism, which is why a session that already has a tab is skipped.

**`cx jump`** — reads the state cache, picks the first blocked then idle
session that has a tab, and selects it; "next" is whatever follows the tab you
are on, so cycling needs no state. Cache-only, like `--window`.

**`cx forget`** — drops exactly one finished session's pin, refusing a running
one: that pin is what the next `cx open` resumes.

**`cx goal on-stop`** — the one place cx starts Claude by itself. A member's
Stop hook runs one `claude -p` driver pass, bounded by opt-in, an hourly cap
counted from the goal log, and a per-goal lock; see invariant 11 in CLAUDE.md
for why that is not a loop. A turn that ends while a pass holds the lock is
replayed when that pass exits — usually it is the reply to that pass's own
nudge, and dropping it stalls the goal.

**`cx nudge`** — types into a live session. It declines with **exit 0** and
`sent: false` when the session is not ready, following the precedent that
stopping an already-stopped project is not an error: a driver in a loop has to
tell "busy, come back" apart from "this is broken". The agent refuses an
*attached* session by itself — a fact it can check — while the client refuses
`working` and `blocked`, which are policy and need the grace period.

**`cx goal`** — a definition of done, and the sessions working towards it.
Server-side per invariant 4, because a goal is the one thing in cx that cannot
be derived from anything else. Members are stored **as written**: a bare
`api/authfix` means this host, a qualified `web2:api@tests` means another one.
The agent validates only the bare ones — it cannot see other servers, and
invariant 1 says it must not try — which is what lets a single goal span hosts
with no client-side state and no replication between servers.

`cx goal dod` records the previous text in `revisions` rather than overwriting
it. Changing the definition of done halfway through is normal, and afterwards
the only way to know what a session was actually asked for is to have kept it.

## The Claude session store — a known assumption

`cx ls` reports how many conversations a project has and when it was last
active; `cx peek` reports what each session is doing. Both come from reading
Claude Code's own storage:

```
~/.claude/projects/<encoded-absolute-path>/*.jsonl
```

The encoding replaces **every character outside `[A-Za-z0-9-]`** with a dash,
not just the slashes:

```
/home/u/projects/api             ->  -home-u-projects-api
/home/u/projects/.worktrees/api  ->  -home-u-projects--worktrees-api
```

The dot is the one that matters. cx puts every worktree under `.worktrees`, so
a slashes-only encoding pointed at a directory that never exists — `cx ls`
reported no history for any worktree cx had ever made. `_session_dir_name` is
now the single place this is written down, because it used to be written twice
and the copies disagreed.

Three more properties are relied on, all verified against a real transcript:

- **each `*.jsonl` is named for the session id it holds** — the file's own
  `.sessionId` equals its basename. That is what lets the agent adopt the
  conversation `--continue` would have picked when a project is opened for the
  first time, and decide whether a pinned id can be `--resume`d yet.
- **`.type` separates messages from bookkeeping, `.isSidechain` separates the
  main thread from subagent turns.** Twelve `.type` values appeared in one real
  transcript and only two of them (`assistant`, `user`) are messages, so *the
  last line of a transcript is usually not a message at all*. Sidechain entries
  outnumbered main-thread ones two to one.
- **`.message.stop_reason`** on an assistant entry: `end_turn` means the turn
  finished, `tool_use` means it is mid-work. That is the whole idle/busy
  signal.

**This is an observed layout, not a documented API.** It could change.
Everything that reads it degrades rather than failing:

| if this breaks | the cost |
|---|---|
| the directory naming | `sessions` is `null`, rendered `?` |
| adopting the newest conversation | a first open starts a fresh one |
| the `.jsonl`-is-the-id property | `--session-id` where `--resume` was meant |
| `.type` / `.isSidechain` / `.stop_reason` | `cx peek` says `unknown`, exit 0 |

A future Claude Code change should cost one display column or one extra
conversation — never a broken `cx ls`, a session that will not open, or a
driver that cannot tell what is happening. If you touch this code, keep that
property; `test/fixtures/transcript/` has a fixture for each failure mode.

Two practical notes for anyone editing the reader. The scan window has to be
far larger than the number of messages wanted (500, escalating once to 5000)
because sidechains bury the main thread. And every line is parsed with
`jq -R 'fromjson? // empty'` — **the `?` is load-bearing**: the file is
append-only and is being written while it is read, so its final line is
routinely a half-written object.

## Naming and tmux

A **unit** is a working directory: a project, or one of its worktrees. A
**slug** adds an optional session label:

```
unit := project[/worktree]
slug := unit[@label]
tmux := cx-<slug>
```

Two tmux behaviors shape this, both verified against tmux 3.x:

- **Targets match by prefix.** Once `cx-api@review` exists, `has-session -t
  cx-api` succeeds and `attach -t cx-api` lands in the review session. Every
  lookup therefore uses the exact-match `=name` form — and `send-keys`, which
  takes a *pane* target, needs the trailing colon (`=name:`) or it fails with
  "can't find pane".
- **Dots are rewritten to underscores.** `new-session -s cx-my.app` creates
  `cx-my_app`, so the tmux name cannot always be reversed. Project names have
  always allowed dots, so the project is recovered by registry lookup;
  worktree names and session labels forbid dots outright.

## Performance

`cx ls` is the most-run command, so its hot path is kept short:

- **Server side, O(1) per host, not per project.** One `tmux list-sessions`,
  one pass over the session store, and `git status --porcelain` (expensive on
  large repos) only when `--git` is passed. `git worktree list` is the one
  per-project call, and it reads `.git/worktrees` rather than the working tree.
- **Client side, one `jq` for the whole table.** The natural shape — a shell
  loop extracting each field — costs about seven processes per project and
  dominated the runtime.
- **Cache hits do not fork.** The fan-out only backgrounds hosts that
  genuinely need the network.

A warm `cx ls` does no SSH at all. Cold cost is one round trip per host, in
parallel, with connections multiplexed so repeat calls reuse the socket.

## Exit codes

Stable, so scripts can branch on them:

| | |
|---|---|
| 0 | success |
| 1 | general error |
| 2 | not found (unknown host or project) |
| 3 | usage error |
| 4 | conflict (project already exists) |
| 5 | ambiguous target (name exists on several servers) |
| 64 | bad command-line usage (`install.sh`) |
| 78 | configuration error |

`install.sh --check` additionally uses 1 for a missing required dependency,
2 for a missing optional one, and 3 for an unsupported platform.

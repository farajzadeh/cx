# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`cx` manages Claude Code sessions across multiple servers over SSH. The client
holds **no credentials and never runs Claude Code locally** — Claude runs on
the servers, signed in there interactively, once per server. Every other
design decision follows from that constraint.

Two halves:

- **Client** (`bin/cx`, `lib/`) — resolves targets, fans out over SSH, caches,
  renders. Stateless and disposable.
- **Agent** (`server/cx-agent`) — owns each server's project registry and its
  goals, drives tmux, invokes Claude Code. Copied to servers by `cx provision`.

A third piece is *not* code: `docs/cx-driver.agent.md` is a Claude Code
subagent that drives sessions towards their goals through the CLI. It holds
all the judgment, because cx holds none — see invariant 11.

## Commands

```sh
./test/run.sh              # portability lint + shellcheck (if installed) + unit tests
./test/run.sh --bash32     # ALSO re-runs unit tests under real bash 3.2 (needs Docker)
./test/run.sh --all        # ALSO integration tests against SSH containers (needs Docker)

bash test/unit/compat.test.sh              # a single test file
bash test/unit/target.test.sh              # the target grammar, pure and fast
bash test/unit/activity.test.sh            # session state + the transcript reader
bash test/unit/goal.test.sh                # the goal store
bash test/integration/hosts.test.sh        # a single integration suite
bash test/integration/worktrees.test.sh    # worktrees end to end
bash test/integration/driving.test.sh      # observe, nudge and goals end to end
docker run --rm -v "$PWD":/w -w /w bash:3.2 bash test/unit/compat.test.sh

./test/lint-portability.sh                 # the bash-3.2/BSD construct ban, alone
./install.sh --check                       # requirements table; writes nothing
```

CI additionally runs `shellcheck` and `shfmt -d -i 2 -ci`. Run them through
containers if not installed locally — **pass `--user` or they write files back
owned by root**:

```sh
FILES=$(git ls-files '*.sh' bin/cx server/cx-agent | grep -v 'completions/cx.\(zsh\|fish\)')
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w -w /w \
  koalaman/shellcheck-alpine:stable shellcheck -x -e SC1091 -S warning $FILES
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w -w /w \
  mvdan/shfmt:latest -w -i 2 -ci $FILES
```

Integration tests spin up throwaway `sshd` containers with real key auth and
real package installation. Claude Code is stubbed, so they need Docker but no
credentials and no network access to Anthropic.

## Invariants

Each of these is load-bearing. Breaking one produces a bug that is subtle,
already happened once, and easy to reintroduce.

**1. The client never builds shell command strings for the server.** Every
remote action goes through `cx_agent` / `cx_ssh` in `lib/remote.sh`, which
runs each argument through `cx_remote_quote`. `ssh` joins its command
arguments with spaces and hands the result to the remote login shell, which
re-splits — so anything unquoted is reinterpreted on the far side. If you find
yourself writing `ssh "$host" "cmd $var"`, stop. `cx ask` goes further and
sends the prompt over **stdin**, so it never touches a shell at all.

**2. The agent's stdout is machine-readable; stderr is for humans.** Never
capture with `2>&1`. This already caused a silent bug where `git clone`
progress output landed inside the JSON and `cx new` succeeded printing
nothing. Under `set -e`, a failed command substitution in an assignment aborts
the function silently — guard extractions with `|| true`.

**3. Non-interactive SSH has a minimal PATH.** `ssh host 'cmd'` reads neither
`~/.bashrc` nor `~/.profile`, so `~/.local/bin` is absent — which is exactly
where Claude Code installs itself. Both `cx-agent` and `bootstrap.sh` prepend
it explicitly, and `_find_claude` falls back to known install locations. The
agent is always invoked by absolute path for the same reason. This caused a
real bug: cx reported "Claude Code not installed" on servers where it was
installed and signed in.

**4. The cache is never a source of truth.** `rm -rf ~/.cache/cx` must change
speed and nothing else. Anything that changes server state must call
`cx_cache_invalidate "$host"` **before returning** — a cache that is wrong
immediately after the user's own change is worse than no cache.

**5. Servers own their registries, and record only what cannot be derived.**
Each server's `~/.local/share/cx/projects.json` is authoritative. The client
merges, never stores. Only non-derivable fields are recorded (`name`, `path`,
`repo`, `created_at`); `branch`, `dirty`, `tmux_live`, `tmux_count`,
`sessions`, `last_active` and **`worktrees`** are computed fresh on every
`list`. Worktrees in particular come from `git worktree list --porcelain` and
are never written down — a second copy of a fact git maintains is a copy that
drifts, and deriving means a worktree made by hand over SSH shows up in cx and
one deleted by hand disappears.

**6. `server/cx-agent` is deliberately monolithic.** It is `scp`'d to servers
as a single file and cannot source anything. It duplicates a little of
`lib/compat.sh` for that reason. Do not factor it into `lib/`.

**7. `server/bootstrap.sh` is POSIX sh, not bash.** A minimal server (Alpine,
some container images) has no bash, and bootstrap is what installs it. Tested
under busybox `ash`.

**8. Every tmux target uses the exact-match `=name` form.** A bare `-t cx-api`
is a *prefix* match: once `cx-api@review` exists, `has-session -t cx-api`
succeeds and `attach -t cx-api` lands in the review session. Verified against
tmux 3.x. Two shapes, and they are not interchangeable — session commands
(`has-session`, `kill-session`, `attach`) take `=name`, while **`send-keys`
takes a pane target and needs the trailing colon: `=name:`**. `send-keys -t
"=name"` fails outright with "can't find pane".

**9a. Permission mode is fixed at session creation, so it must be recorded.**
`--dangerously-skip-permissions` is passed to the `claude` process the pane
launches; reattaching cannot change it, and from inside an attached session
there is no way to tell which mode you are in. So `cmd_open` records
`dangerous: true` on the session entry and `cx status` shows a `no-perms`
MODE. The negative is **deleted rather than stored** — absent already means
guarded, and writing `false` would turn `sessions.json` from a list of pins
into a list of every session ever opened. Clearing still happens explicitly on
each creation, because a previous session under the same slug may have set it
and a stale `true` makes `cx status` lie in the dangerous direction. Note
`.sessions[$s] |= ...` on a missing key *creates* it holding null, so the
clearing path is guarded with `has($s)`.

**9. A cx session pins a Claude conversation id.** `claude --continue` means
"the newest conversation in this directory", so two sessions on one project
both resume the same conversation and the second silently hijacks the first —
which is the whole reason parallel sessions did not work before. The agent
records slug → uuid in `~/.local/share/cx/sessions.json` and launches
`--session-id <uuid>` the first time, `--resume <uuid>` afterwards, choosing
between them by whether that conversation's `.jsonl` exists. Claude reuses the
id on resume unless `--fork-session` is passed. The file is a cache, not state
cx owns: delete it and sessions start fresh conversations.

**10. Names that tmux mangles.** tmux silently rewrites `.` to `_` in a
session name (`cx-my.app` becomes `cx-my_app`), so the tmux name cannot always
be reversed into the thing it names. Project names have always allowed dots,
so `cmd_sessions` recovers the project by looking it up in the registry rather
than parsing it out. Worktree names and session labels are cx's own namespaces
and simply **forbid** dots (`_validate_label`), which keeps the ambiguity to
that one component.

**11. cx contains no judgment, and therefore no loop.** The client and agent
classify *structure* — does this transcript's last main-thread message end in
`stop_reason: end_turn` — and never *meaning* — is this definition of done
met. Meaning belongs to the driver subagent (`docs/cx-driver.agent.md`), which
reaches cx only through the CLI.

The corollary is the load-bearing half: **every verb is one-shot and returns.**
No `--follow`, no `--wait`, no daemon, nothing that polls. A client daemon
would contradict "the client is stateless and disposable"; a server daemon
would need a driver Claude with its own conversation and session pin, which is
a recursion into the problem being solved; and mechanically there is no
`timeout(1)`, no `wait -n` and no `setsid`, so every loop you could write here
is a hand-rolled `sleep` holding an SSH connection open for its duration. The
interval comes from whatever is calling cx.

This is also why `cx goal pause` works without touching anything: there is no
process to signal, only a driver that re-reads the goal each pass and stops.
And it is why `cx nudge` declines a busy session rather than queueing — cx has
nowhere to keep a queue that is not state it owns, and draining one would need
the daemon it does not have.

**12. One conversation, one writer.** A Claude conversation id is owned by
exactly one live process. `claude -p --resume <uuid>` against a uuid a tmux
session is already holding gives two writers appending to one transcript with
no merge, and the turns of whichever loses are silently orphaned. `cx ask
<target>@<label>` did exactly this until 0.3.0; it now refuses with exit 4 when
that session is live. **Steering a running session is `tmux send-keys` into its
pane — never a second `claude`.**

`cx nudge` sends the text through a tmux paste buffer (`load-buffer` from
stdin, `paste-buffer -d`, then `C-m`) rather than as a `send-keys` argument.
Two reasons, both practical: a multi-line prompt is impossible with `send-keys`
because the first newline submits, and this way the prompt never becomes part
of a command line on either side of the wire.

## Portability

The client targets **bash 3.2** (macOS's default) and BSD userland.
`test/lint-portability.sh` enforces this and runs first in CI. Banned:
`declare -A`, `mapfile`, `${var^^}`, `wait -n`, globstar, `flock`, `setsid`,
`timeout`, `realpath`, `readlink -f`, `sed -i`, `grep -P`, `sort -V`,
`md5sum`, `echo -e`, `seq`. Expand arrays as `"${arr[@]+"${arr[@]}"}"` —
bash 3.2 under `set -u` errors on an empty expansion.

Use `lib/compat.sh` instead. Mark a genuine exception `# portable-ok: <reason>`.

Two shims worth knowing:

- **Locking is `mkdir`, not `flock`** — atomic on every POSIX filesystem
  including NFS, with a PID file inside so a stale lock can be reaped.
- **`CX_SSH_CONFIG` exists because OpenSSH resolves `~/.ssh/config` from the
  passwd database, not `$HOME`.** Setting `HOME` does not redirect it. This is
  what makes the test suite hermetic, and is a real feature for anyone with a
  non-standard config.

## Targets

The grammar is `[host:]project[/worktree][@session]`, parsed by
`cx_target_split` into `CX_T_HOST` / `CX_T_PROJECT` / `CX_T_WORKTREE` /
`CX_T_SESSION`. `/` and `@` are available as separators precisely because
`_validate_name` has always rejected both in a project name, so no existing
target changed meaning.

Two orthogonal axes, and the distinction is the whole user-facing story:

- **`@label`** — another conversation on the *same files*. Same directory,
  same branch, its own pinned Claude session.
- **`/worktree`** — another *branch and directory*, via `git worktree`. This
  is what makes genuinely parallel tasks safe.

`cx_target_args` turns the parsed target into the `--worktree` / `--session`
argv for the agent, emitting each flag only when non-empty — so a plain
`cx open web1:api` sends exactly the argv it always did and still works
against a pre-0.2.0 agent. When a target does need the new flags,
`cx_target_needs_units` gates on `cx_agent_units_ok`, which tells the user to
re-provision instead of surfacing "unknown option: --worktree".

## Driving sessions

Three commands, and the split between them is invariant 11 made concrete:

- **`cx peek`** — the agent's `observe` verb reports raw facts per session
  (tmux liveness, the pane's current command, the transcript's mtime and its
  last main-thread message); `lib/activity.sh` turns them into a state. The
  classifier lives on the client because the threshold is the user's
  (`CX_IDLE_GRACE`) and because a pure function is the only part of this a unit
  test can pin — inside the monolithic agent it would be untestable.

  States: `dead` (no tmux, or the pane is back at a shell) · `fresh` (up, but
  this conversation has not started) · `idle` (last turn ended) · `working`
  (moving) · `blocked` (mid-turn and quiet past the grace period) · `unknown`.

  `fresh` deliberately never expires. Claude writes no transcript until its
  first exchange, so "just started" and "nobody has given it anything to do"
  are the same fact; whether that has gone on too long depends on what the
  caller has already sent, which only the caller knows.

- **`cx nudge`** — types into a live session. Declines with **exit 0** and
  `sent: false` when the session is not ready, following `cmd_stop`'s
  precedent that a non-event is not an error: a driver in a loop has to tell
  "busy, come back" apart from "this is broken". The agent refuses an
  *attached* session by itself (a fact it can check); the client refuses
  `working` and `blocked` (policy, needing the grace period).

- **`cx goal`** — the definition of done, and who is working on it. Stored
  server-side per invariant 5, because a goal is the one thing in cx that
  cannot be derived from anything. Members are stored **as written**: a bare
  `api/authfix` means this host, a qualified `web2:api@tests` means another.
  The agent validates only the bare ones — it cannot see other servers and
  invariant 1 says it must not try — which is what lets one goal span hosts
  with no client-side state and no replication.

  `cx goal dod` records the old text in `revisions` rather than overwriting:
  changing your mind halfway through is normal, and afterwards the only way to
  know what a session was actually asked for is to have kept it.

## Adding a subcommand

Create `lib/cmd/<name>.sh` defining `cmd_<name>`, source what it needs from
`$CX_HOME/lib/`, and add a line to the usage text in `bin/cx`. Dispatch is
automatic — `load_cmd` sources the file on demand. `resume.sh` and `shell.sh`
are symlinks to `open.sh`; the same command in three modes. `worktree.sh` is a
symlink to `wt.sh` the same way.

Global flags (`-r`, `--no-cache`, `--stale`, `--json`, `-y`, `--no-color`) are
stripped from anywhere in the argv before the subcommand is chosen, so
`cx --json ls` and `cx ls --json` are equivalent. `-h`/`--help` is deliberately
**not** global, so `cx host --help` documents `host`.

## Exit codes

Stable, so scripts can branch on them: `0` success, `1` general error, `2` not
found, `3` usage, `4` conflict, `5` ambiguous target, `78` config error.
`install.sh --check` uses `1` missing required, `2` missing optional, `3`
unsupported platform, `64` bad usage.

## The Claude session store — a known assumption

`cx ls`, `cx peek` and `cx nudge` all read Claude Code's own storage at
`~/.claude/projects/<encoded-path>/*.jsonl`. Verified empirically, but it is an
**observed layout, not a documented API**, and `observe` leans on it hard
enough that the details matter.

Four properties are relied on, all verified against a real store:

1. **the directory name is the absolute path with every character outside
   `[A-Za-z0-9-]` replaced by `-`** — not just the slashes. `_session_dir_name`
   is the one place this is written down, and it is one place because it used
   to be two: a slashes-only copy in `_derive_dir` meant `cx ls` reported no
   history for every worktree cx has ever made, since they all live under
   `.worktrees` and the dot never got encoded.
2. **each `*.jsonl` is named for the session id it contains** — the file's own
   `.sessionId` equals its basename. `_newest_session_id` uses this so the
   first open of a project adopts the conversation `--continue` would have
   picked, and `cmd_open` uses it to choose `--resume` over `--session-id`.
3. **`.type` distinguishes messages from bookkeeping, and `.isSidechain`
   distinguishes the main thread from subagent turns.** Both matter more than
   they look. Twelve `.type` values were seen in one real transcript, only two
   of which (`assistant`, `user`) are messages — so **the last line of a
   transcript is usually not a message at all**, and a reader that takes
   `tail -1` and looks at its role is wrong nearly always. Sidechain entries
   *outnumbered* main-thread ones two to one, so filtering them is essential
   rather than a refinement.
4. **`.message.stop_reason` on an assistant entry** is the whole idle/busy
   signal: `end_turn` means the turn finished and Claude is waiting for a
   human, `tool_use` means it is mid-work.

Two practical consequences for anyone touching `_transcript_messages`. The
scan window has to be far larger than the number of messages wanted (500,
escalating once to 5000) because sidechains bury the main thread. And every
line must be parsed with `jq -R 'fromjson? // empty'` — **the `?` is
load-bearing**: the file is append-only and being written while we read it, so
its last line is routinely a half-written object.

Every reader degrades rather than failing: absent store → `sessions` is `null`
(rendered `?`), no adoptable id → a fresh uuid is generated, no `.jsonl` for a
pinned id → `--session-id` instead of `--resume`, nothing parsable → `cx peek`
says `unknown` and exits 0. A future Claude Code change should cost one display
column or one new conversation, never a broken `cx ls`, a session that will not
open, or a driver that cannot tell what is happening. Preserve that property —
`test/fixtures/transcript/` has a fixture for each of these failure modes.

## Keeping this file current

**Update `CLAUDE.md` as part of the change it describes**, not afterwards. It
is documentation of the architecture, not a snapshot taken once. Specifically:

- A new invariant, or a new reason an obvious approach is wrong → add it.
- A new command, test entry point, or lint step → update **Commands**.
- A change to exit codes, the subcommand contract, or the layout → update it.
- An assumption that turns out to be wrong → correct it rather than leaving a
  future instance to trip over the same thing.

If a change makes something here inaccurate, the change is not finished.

## Conventions

- Comments explain **why**, especially where the obvious approach is wrong.
  Several non-obvious forms here are load-bearing and would otherwise be
  "simplified" back into bugs.
- `issues/` holds one markdown file per open issue. Delete the file when the
  issue is fixed rather than marking it resolved — git history keeps the
  record, and a directory of stale entries helps nobody.
- `install.sh` copies only `bin lib server completions config.example docs`
  to users. `test/` and `issues/` stay repo-only. The driver subagent lives in
  `docs/cx-driver.agent.md` so that it ships; `.claude/agents/cx-driver.md` is
  a symlink to it for this repo's own use, and `cx driver` prints it so a user
  can put it wherever they keep subagents.
- `install.sh` is standalone by necessity — it runs before the repo exists and
  cannot source `lib/compat.sh`. Its duplicated `version_ge` is covered by a
  test asserting the two implementations agree.

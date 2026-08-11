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

`branch`, `dirty`, `tmux_live`, `sessions` and `last_active` are computed
fresh on every `list`. Only `name`, `path`, `repo` and `created_at` are
recorded — the things that genuinely cannot be recomputed.

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

## The Claude session store — a known assumption

`cx ls` reports how many conversations a project has and when it was last
active. That comes from reading Claude Code's own storage:

```
~/.claude/projects/<absolute-path-with-slashes-replaced-by-dashes>/*.jsonl
```

So `/home/u/projects/api` maps to `~/.claude/projects/-home-u-projects-api/`.
This was verified empirically against a real installation.

**This is an observed layout, not a documented API.** It could change.
Everything that reads it degrades to `null` — rendered as `?` — when the
directory is absent, so a future Claude Code change costs one display column
rather than breaking `cx ls`. If you touch this code, keep that property.

## Performance

`cx ls` is the most-run command, so its hot path is kept short:

- **Server side, O(1) per host, not per project.** One `tmux list-sessions`,
  one pass over the session store, and `git status --porcelain` (expensive on
  large repos) only when `--git` is passed.
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

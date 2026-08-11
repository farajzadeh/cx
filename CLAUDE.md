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
- **Agent** (`server/cx-agent`) — owns each server's project registry, drives
  tmux, invokes Claude Code. Copied to servers by `cx provision`.

## Commands

```sh
./test/run.sh              # portability lint + shellcheck (if installed) + unit tests
./test/run.sh --bash32     # ALSO re-runs unit tests under real bash 3.2 (needs Docker)
./test/run.sh --all        # ALSO integration tests against SSH containers (needs Docker)

bash test/unit/compat.test.sh              # a single test file
bash test/integration/hosts.test.sh        # a single integration suite
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

**5. Servers own their registries.** Each server's
`~/.local/share/cx/projects.json` is authoritative. The client merges, never
stores. Only non-derivable fields are recorded (`name`, `path`, `repo`,
`created_at`); `branch`, `dirty`, `tmux_live`, `sessions` and `last_active`
are computed fresh on every `list`.

**6. `server/cx-agent` is deliberately monolithic.** It is `scp`'d to servers
as a single file and cannot source anything. It duplicates a little of
`lib/compat.sh` for that reason. Do not factor it into `lib/`.

**7. `server/bootstrap.sh` is POSIX sh, not bash.** A minimal server (Alpine,
some container images) has no bash, and bootstrap is what installs it. Tested
under busybox `ash`.

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

## Adding a subcommand

Create `lib/cmd/<name>.sh` defining `cmd_<name>`, source what it needs from
`$CX_HOME/lib/`, and add a line to the usage text in `bin/cx`. Dispatch is
automatic — `load_cmd` sources the file on demand. `resume.sh` and `shell.sh`
are symlinks to `open.sh`; the same command in three modes.

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

`cx ls` reports conversation counts and last-active times by reading Claude
Code's own storage at
`~/.claude/projects/<absolute-path-with-slashes-as-dashes>/*.jsonl`. Verified
empirically, but it is an **observed layout, not a documented API**. Every
reader degrades to `null` (rendered `?`) when the directory is absent, so a
future Claude Code change costs one display column rather than breaking
`cx ls`. Preserve that property.

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
  to users. `test/` and `issues/` stay repo-only.
- `install.sh` is standalone by necessity — it runs before the repo exists and
  cannot source `lib/compat.sh`. Its duplicated `version_ge` is covered by a
  test asserting the two implementations agree.

# Contributing

Thanks for looking. This project has a small number of hard rules; everything
else is negotiable.

## Run the tests

```sh
./test/run.sh              # lint + unit tests
./test/run.sh --bash32     # also under real bash 3.2 (needs Docker)
./test/run.sh --all        # also integration tests against SSH containers
```

Integration tests spin up throwaway `sshd` containers, provision them for
real, and stub Claude Code — so they need Docker but no credentials and no
network access to Anthropic.

## The portability rules

`cx` targets **bash 3.2** and BSD userland, because that is what macOS ships
and macOS users are a large share of people who SSH into Linux servers.

`./test/lint-portability.sh` enforces this and runs first in CI. The banned
constructs are listed there with the shim to use instead — the short version:

- no `declare -A`, `mapfile`, `${var^^}`, `wait -n`, globstar
- no `flock`, `setsid`, `timeout`, `realpath`, `readlink -f`, `sed -i`
- no `grep -P`, `sort -V`, `md5sum`, `echo -e`, `seq`
- expand arrays as `"${arr[@]+"${arr[@]}"}"` (bash 3.2 + `set -u`)

Use the helpers in `lib/compat.sh` instead. If you genuinely need a banned
construct, mark the line `# portable-ok: <reason>`.

There is one legitimate use of `stat -c` in the codebase: the probe in
`compat.sh` that decides whether `stat -c` works.

## Two invariants worth knowing before you change things

**The client never builds shell command strings for the server.** Every remote
action goes through `cx_agent`, which quotes each argument individually. This
is why a project called `my project` and a prompt containing `$(rm -rf ~)`
are both safe. If you find yourself writing `ssh "$host" "cmd $var"`, stop.

**The agent's stdout is machine-readable, stderr is for humans.** Do not merge
them with `2>&1` — the client parses stdout, and a stray log line corrupts it.
This has already caused one silent bug.

## Where things live

| | |
|---|---|
| `bin/cx` | client entry point and dispatch |
| `lib/*.sh` | client libraries (`compat`, `config`, `ui`, `cache`, `hosts`, `remote`, `target`, `projects`) |
| `lib/cmd/*.sh` | one file per subcommand, defining `cmd_<name>` |
| `server/cx-agent` | the server half — **deliberately monolithic**, since it is copied to servers as a single file and cannot source anything |
| `server/bootstrap.sh` | provisioning — **POSIX sh**, because it may run on a server with no bash yet |
| `test/` | harness, unit tests, integration tests, portability lint |

## Adding a subcommand

Create `lib/cmd/<name>.sh` defining `cmd_<name>`, source whatever libraries it
needs from `$CX_HOME/lib/`, and add a line to the usage text in `bin/cx`.
Dispatch is automatic.

If the command changes server state, call `cx_cache_invalidate "$host"` before
returning. A cache that is wrong immediately after your own change is worse
than no cache.

## Style

`shfmt -i 2 -ci` — CI checks it with `-d`, so an unformatted file fails the
build.

```sh
shfmt -w -i 2 -ci $(git ls-files '*.sh' bin/cx server/cx-agent)
```

If you run it through Docker rather than installing it, pass `--user` or it
writes the files back as root:

```sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w -w /w \
  mvdan/shfmt:latest -w -i 2 -ci $(git ls-files '*.sh' bin/cx server/cx-agent)
```

Comments should explain *why*, especially where the obvious approach is wrong;
there are several places where the non-obvious form is load-bearing and a
future reader would otherwise "simplify" it back into a bug.

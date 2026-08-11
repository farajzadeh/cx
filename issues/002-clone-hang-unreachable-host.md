# cx new --repo hangs indefinitely when the repo host is unreachable

**Type:** bug  
**Status:** open  
**Found in:** 0.1.0 (8e2a3ed)  
**GitHub:** _not yet filed_

---

## Summary

`cx new --repo <url>` hangs indefinitely when the repository host is
unreachable from the server, instead of failing fast. There is no timeout and
no progress output, so the command looks frozen.

## Reproduction

```sh
# a host the server cannot reach
cx new web1:test --repo 'ssh://user@unreachable.example.com:29418/proj'
```

Observed: the command blocks with no output. In testing it was still hanging
after **10 minutes** and had to be killed.

Expected: fail within a few seconds with a clear message naming the host.

## Cause

`cmd_new` in `server/cx-agent` runs:

```sh
git clone --quiet "$repo" "$path"
```

`git` invokes `ssh` with no `ConnectTimeout`, so it inherits the system
default — effectively "wait for the TCP stack to give up", which can be
minutes. `--quiet` additionally suppresses the progress output that would at
least show something was happening.

This is inconsistent with the rest of cx, which is careful about exactly this
failure mode: `cx_ssh_opts` in `lib/remote.sh` sets `ConnectTimeout` (default
5s, configurable via `CX_CONNECT_TIMEOUT`) precisely so one unreachable server
cannot stall a fan-out. The clone path bypasses that entirely because it is
`git` making the connection, not cx.

## Suggested fix

Pass a connect timeout through to git's ssh, honouring the existing setting:

```sh
GIT_SSH_COMMAND="ssh -o ConnectTimeout=${CX_CONNECT_TIMEOUT:-5} -o BatchMode=yes" \
  git clone --quiet "$repo" "$path"
```

`BatchMode=yes` matters too: without it, a server missing the right key can
sit at an interactive password prompt that nobody is watching, which is a
second way to hang forever.

Note the timeout is per connection attempt, not a total cap on the clone — a
large repository over a slow link should still be allowed to finish. Only the
*connect* phase needs bounding.

Two further considerations:

- **HTTPS remotes** ignore `GIT_SSH_COMMAND`. `git config http.lowSpeedLimit`
  / `http.lowSpeedTime` are the equivalent levers if HTTPS hangs also need
  bounding.
- **Progress.** `--quiet` hides everything. Showing git's progress on stderr
  during a long clone would make a slow-but-working clone distinguishable
  from a stuck one. stdout must stay clean, since the client parses JSON from
  it.

## Impact

Low severity, high annoyance. It is recoverable (Ctrl-C) and leaves no partial
registry entry, since registration happens after a successful clone. But the
first-run experience of a mistyped URL or a server without network access to
the forge is a command that appears to have frozen, which is a bad way to
learn either fact.

## Found while

Investigating Gerrit clone support, where the Gerrit host was deliberately
unreachable from the test server.

# cx new --repo does not install Gerrit's commit-msg hook

**Type:** enhancement  
**Status:** open  
**Found in:** 0.1.0 (8e2a3ed)  
**GitHub:** _not yet filed_

---

## Summary

`cx new --repo <url>` clones the repository but runs no post-clone steps, so a
Gerrit project ends up **missing its `commit-msg` hook**. Without that hook,
commits carry no `Change-Id` and `git push HEAD:refs/for/<branch>` is rejected
by the Gerrit server.

Gerrit's own "clone with commit-msg hook" command is two steps — the clone and
the hook install — and cx only performs the first.

## What already works

The clone itself is fine. Gerrit URLs carry percent-encoded userinfo and a
non-default port, and both survive cx's argument quoting intact. Verified by
shimming `git` on the server and printing the argv it receives:

```
git argv:
  [1] clone
  [2] --quiet
  [3] ssh://user%40example.com@gerrit.example.com:29418/myproject
  [4] /home/deploy/projects/myproject
```

So `%40`, the userinfo `@`, and `:29418` all arrive as a single intact
argument. No quoting work is needed — only the missing post-clone step.

## What does not work

Given Gerrit's documented command:

```sh
git clone "ssh://user%40example.com@gerrit.example.com:29418/myproject" && \
  (cd "myproject" && mkdir -p `git rev-parse --git-dir`/hooks/ && \
   curl -Lo `git rev-parse --git-dir`/hooks/commit-msg \
     https://gerrit.example.com/tools/hooks/commit-msg && \
   chmod +x `git rev-parse --git-dir`/hooks/commit-msg)
```

cx performs only the `git clone` portion. There is no flag or hook that runs
the remainder.

## Why it matters

The failure is **silent and delayed**. `cx new` reports success, the project
appears in `cx ls`, and everything looks correct. The problem only surfaces
later when the first review push is rejected:

```
! [remote rejected] HEAD -> refs/for/main (missing Change-Id in message footer)
```

By then the commits already exist and have to be amended or rebased to add
Change-Ids — significantly more annoying than having the hook from the start.

## Reproduction

```sh
cx new web1:myproject --repo 'ssh://user%40example.com@gerrit.example.com:29418/myproject'
ssh web1 'ls ~/projects/myproject/.git/hooks/commit-msg'
# => No such file or directory
```

## Current workaround

Two steps instead of one:

```sh
cx new web1:myproject --repo 'ssh://user%40example.com@gerrit.example.com:29418/myproject'

ssh web1 'cd ~/projects/myproject && \
  mkdir -p "$(git rev-parse --git-dir)/hooks" && \
  curl -Lo "$(git rev-parse --git-dir)/hooks/commit-msg" \
    https://gerrit.example.com/tools/hooks/commit-msg && \
  chmod +x "$(git rev-parse --git-dir)/hooks/commit-msg"'
```

This works, but it is easy to forget, and forgetting is only discovered at
push time.

## Proposed fix

Two flags on `cx new`, both handled server-side in `cmd_new` (`server/cx-agent`):

**1. `--post-clone '<command>'` — the general primitive**

Runs the command in the project directory after a successful clone. The same
gap affects other ecosystems, so a generic hook is worth more than a
Gerrit-only one:

- `git lfs pull`
- `git submodule update --init --recursive`
- project-specific bootstrap scripts

Not a privilege concern: `cx shell` already gives full shell access to the
same account on the same server, so this adds convenience, not capability.

**2. `--gerrit [hook-url]` — the convenience shorthand**

Expands to the standard hook install. With no argument, derive the URL from
the repo host:

```
ssh://…@gerrit.example.com:29418/proj  ->  https://gerrit.example.com/tools/hooks/commit-msg
```

The argument must stay overridable because derivation is not universally
correct — many Gerrit instances are served under a path prefix, e.g.
`https://gerrit.example.com/r/tools/hooks/commit-msg`, and some use a
different host for HTTPS than for SSH.

Gerrit also supports fetching the hook over SSH:

```sh
scp -p -P 29418 user@gerrit.example.com:hooks/commit-msg .git/hooks/
```

That reuses the credentials the clone already needed and avoids a second
trust path, so it may be the better default with curl as the fallback.

### Behaviour details worth deciding

- **Failure handling.** If the post-clone step fails, should `cx new` fail the
  whole operation, or keep the clone and warn? Leaning toward: keep the clone,
  warn loudly, exit non-zero — deleting a successful clone because a hook
  download failed would be worse.
- **Idempotency.** Re-running should not duplicate work; the hook install is
  naturally idempotent (`curl -Lo` overwrites).
- **`cx ls`** could show a marker for Gerrit projects whose hook is missing,
  since that is the state that bites later.

## Prerequisite worth documenting regardless

The clone runs **on the server**, not on the client. The server therefore
needs its own SSH access to the Gerrit host — its own key registered in
Gerrit, or agent forwarding. A local key on the machine running `cx` is not
used and not sufficient. This is not obvious from the current docs and
deserves a note in `docs/SERVERS.md` whether or not the flags are added.

## Related

`git clone` has no connect timeout, so `cx new --repo` blocks indefinitely
when the repository host is unreachable from the server rather than failing
fast. Discovered while investigating this; tracked separately in
[002-clone-hang-unreachable-host.md](002-clone-hang-unreachable-host.md) as it
is a bug rather than a missing feature.

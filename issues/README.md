# Known issues

Tracked in the repository rather than only on GitHub so that a checkout is
self-contained: `grep` finds them, they show up in diffs, and they travel with
the code when someone works offline.

These are **not** a replacement for GitHub issues. The workflow is:

1. An issue is written here when it is found, with enough detail to act on
   later without re-investigating.
2. When it is filed on GitHub, add the issue number to the header.
3. When it is fixed, delete the file in the same commit as the fix. The git
   history keeps the record; a directory full of stale "resolved" files does
   not help anyone.

## Format

Each file starts with a short metadata block, then prose. Numbering is just
for ordering and has no relationship to GitHub issue numbers.

```
# Title

**Type:** bug | enhancement
**Status:** open
**Found in:** <version or commit>
**GitHub:** <url, once filed>
```

## Current

| File | Type | Summary |
|---|---|---|
| [001-gerrit-commit-msg-hook.md](001-gerrit-commit-msg-hook.md) | enhancement | `cx new --repo` clones a Gerrit project but never installs its `commit-msg` hook, so review pushes are rejected later |
| [002-clone-hang-unreachable-host.md](002-clone-hang-unreachable-host.md) | bug | `cx new --repo` hangs indefinitely instead of failing fast when the repository host is unreachable from the server |

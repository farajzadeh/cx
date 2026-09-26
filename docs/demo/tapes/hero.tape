# hero.gif — the twenty-second pitch: every server at once, find the session
# that needs you, answer it, and leave it running.

Output "/out/hero.gif"
Source "settings.tape"
Source "prelude.tape"

Type "cx ls"
Sleep 400ms
Enter
Sleep 3s

# The fuzzy finder, over every project, worktree and session on both servers.
Type "cx find"
Sleep 300ms
Enter
Sleep 1.5s
Type@120ms "auth"
Sleep 1.5s
Enter
Sleep 1.2s
# The action menu: open is first.
Enter

# Attached to Claude on web1, stopped on a permission question.
Sleep 3s
Type "1"
Enter
Sleep 5s

# Detach; the session keeps running on the server.
Ctrl+B
Sleep 200ms
Type "d"
Sleep 1s
Type "cx peek"
Sleep 300ms
Enter
Sleep 3s

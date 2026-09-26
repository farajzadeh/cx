# parallel.gif — the two ways to do two things at once. @label: another
# conversation on the same files. /worktree: another branch and directory.

Output "/out/parallel.gif"
Source "settings.tape"
Source "prelude.tape"

Type "cx open web1:api@review -d"
Sleep 400ms
Enter
Sleep 3s

Type "cx wt add web1:api/bug-123 -d"
Sleep 400ms
Enter
Sleep 4s

Ctrl+L
Type "cx status"
Sleep 300ms
Enter
Sleep 3s

Type "cx ls api"
Sleep 300ms
Enter
Sleep 4s

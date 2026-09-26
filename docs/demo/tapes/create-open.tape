# create-open.gif — `cx new` asks for what it was not told, then offers to
# open a session; `cx wt add --open -d` does both for a worktree in one line.

Output "/out/create-open.gif"
Source "settings.tape"

Type "cx new"
Sleep 300ms
Enter

# Which server: a menu, since there are two.
Sleep 1.5s
Type@150ms "web2"
Sleep 800ms
Enter
Sleep 800ms
Type "blog"
Sleep 400ms
Enter
Sleep 800ms
Type "git@github.com:acme/blog.git"
Sleep 500ms
Enter

# "Open a session now? [Y/n]" — yes, and Claude starts in the new project.
Sleep 3s
Type "y"
Sleep 400ms
Enter
Sleep 3.5s
Ctrl+B
Sleep 200ms
Type "d"
Sleep 1.5s

# A worktree, and a session in it, without leaving the shell.
Type "cx wt add web1:api/authfix --open -d"
Sleep 400ms
Enter
Sleep 5s

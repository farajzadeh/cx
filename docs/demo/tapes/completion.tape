# completion.gif — bash tab completion: commands, then a target one level
# at a time, then a flag and its values. None of it touches the network: it
# reads what `cx ls` and `cx peek` last saw.

Output "/out/completion.gif"
Source "settings.tape"
Source "prelude.tape"

Type "cx op"
Sleep 500ms
Tab
Sleep 1s

# Servers first...
Type "we"
Sleep 400ms
Tab
Sleep 1.8s
Type "1"
Sleep 400ms
Tab
Sleep 1.5s

# ...then its projects...
Tab
Sleep 1.8s
Type "a"
Sleep 400ms
Tab
Sleep 1s

# ...then what is inside one: worktrees and @sessions.
Tab
Sleep 2.2s
Type "/"
Sleep 400ms
Tab
Sleep 1.5s
Type "a"
Sleep 400ms
Tab
Sleep 1.5s

Ctrl+C
Sleep 500ms
Type "cx open web1:api@"
Sleep 400ms
Tab
Sleep 1.5s

# Flags, and the values a flag takes.
Ctrl+C
Sleep 500ms
Type "cx ls --so"
Sleep 400ms
Tab
Sleep 800ms
Tab
Sleep 1.8s
Type "a"
Sleep 400ms
Tab
Sleep 600ms
Enter
Sleep 3s

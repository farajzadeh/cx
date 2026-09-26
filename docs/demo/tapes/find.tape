# find.gif — `cx find`: pick any target, then what to do with it; and
# `cx find --print`, which makes the menu usable from any command.

Output "/out/find.gif"
Source "settings.tape"

Type "cx find api"
Sleep 300ms
Enter
Sleep 2s
Down
Sleep 700ms
Down
Sleep 1s
Enter

# The action menu.
Sleep 2.5s
Type@150ms "peek"
Sleep 1s
Enter
Sleep 3s

# --print: the menu, and only the choice on stdout.
Type `cx ask "$(cx find --print)" "what changed this week?"`
Sleep 500ms
Enter
Sleep 2s
Type@150ms "infra"
Sleep 1.2s
Enter
Sleep 5s

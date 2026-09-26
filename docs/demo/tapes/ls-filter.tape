# ls-filter.gif — narrowing `cx ls`: a pattern, what is live, grouped and
# sorted; then the servers themselves.

Output "/out/ls-filter.gif"
Source "settings.tape"

Type "cx ls"
Sleep 300ms
Enter
Sleep 2.5s

Type "cx ls api"
Sleep 300ms
Enter
Sleep 2.5s

Ctrl+L
Type "cx ls --live"
Sleep 300ms
Enter
Sleep 2.5s

Type "cx ls --group host --sort active"
Sleep 300ms
Enter
Sleep 3s

Ctrl+L
Type "cx host ls"
Sleep 300ms
Enter
Sleep 3s

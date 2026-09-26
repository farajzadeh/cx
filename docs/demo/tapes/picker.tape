# picker.gif — `cx open` with no target: a menu of everything, with a
# preview; type to narrow it, Enter to attach.

Output "/out/picker.gif"
Source "settings.tape"

Type "cx open"
Sleep 300ms
Enter
Sleep 2.5s

# Move through the list so the preview follows.
Down
Sleep 900ms
Down
Sleep 900ms
Down
Sleep 1.2s

Type@150ms "review"
Sleep 1.8s
Enter

# The review conversation on web1, as it was left.
Sleep 2.5s
Type "add rate limiting to the login route"
Sleep 400ms
Enter
Sleep 8s

Ctrl+B
Sleep 200ms
Type "d"
Sleep 2s

# peek-nudge.gif — what every session is doing, without attaching to any;
# then the next instruction, typed into one that is ready.

Output "/out/peek-nudge.gif"
Source "settings.tape"
Source "prelude.tape"

Type "cx peek"
Sleep 300ms
Enter
Sleep 3.5s

Type `cx nudge web1:api@review "run the tests"`
Sleep 400ms
Enter
Sleep 1.5s

# It is working on it now.
Ctrl+L
Type "cx peek"
Sleep 300ms
Enter
Sleep 3s

# One that is mid-turn is declined, not interrupted.
Type `cx nudge web1:api/ratelimit "also check p99"`
Sleep 400ms
Enter
Sleep 3s

# And a few seconds later, the review session has finished its turn.
Type "cx peek web1:api@review"
Sleep 300ms
Enter
Sleep 4s

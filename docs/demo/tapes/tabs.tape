# tabs.gif — `cx tabs`: a tab per live session in your own tmux, each titled
# with its state; the icons change as the sessions do, and prefix + j goes to
# the one that needs you.

Output "/out/tabs.gif"
Source "settings.tape"
# JetBrains Mono has no ◐ (working), and the browser's fallback draws half of
# it. DejaVu Sans Mono has every glyph cx bar uses.
Set FontFamily "DejaVu Sans Mono"
Source "prelude.tape"

# The laptop's own tmux, configured exactly as `cx bar --setup` prints, plus
# docs/demo/laptop.tmux.conf. ~ is the demo volume, not anyone's real home.
Hide
Type "cx bar --setup > ~/.tmux.conf && cat /cx/docs/demo/laptop.tmux.conf >> ~/.tmux.conf"
Enter
Type "tmux kill-server 2>/dev/null; tmux new -s laptop"
Enter
Sleep 2s
Type "clear"
Enter
Sleep 500ms
Show

Type "cx tabs -n"
Sleep 300ms
Enter
Sleep 3.5s

Type "cx tabs"
Sleep 300ms
Enter
Sleep 3.5s

# The review session's tab: give it something to do. Its icon goes from
# ● (idle) to ◐ (working)...
Ctrl+B
Type "3"
Sleep 1.5s
Type "run the tests"
Sleep 300ms
Enter
Sleep 3.5s

# ...and, while we look at the load test, back to ● when the turn ends.
Ctrl+B
Type "2"
Sleep 7s

# prefix + j: the tab most in need of you, the ▲ (blocked) one. Answer it.
Ctrl+B
Type "j"
Sleep 3s
Type "1"
Enter
Sleep 5s

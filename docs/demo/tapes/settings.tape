# Shared by every tape (each one starts with `Source settings.tape`), so the
# GIFs match: one size, one font, one theme.
#
# 1200x650 at 16px is 113 columns by 27 rows, which is what the servers' tmux
# default-size is set to in node-prep.sh — sessions are started detached, and
# the demo Claude draws its boxes for the size it was started at.

Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 16
Set Width 1200
Set Height 650
Set Padding 18
Set Theme "OneDark"
Set WindowBar Colorful
Set WindowBarSize 32
Set BorderRadius 8
Set Margin 0
Set TypingSpeed 55ms
Set Framerate 24
Set CursorBlink false

# The server's tmux bar lags the pane by up to 10 s

**Type:** bug  
**Status:** open  
**Found in:** 0.5.0  
**GitHub:** _not yet filed_

---

## Summary

The session's own bar kept showing `▲ blocked` for several seconds after the
prompt was answered: its `status-interval` is 10 s, while the tab icons on
the laptop refreshed faster.

## Fix direction

Have `cx-agent event` run `tmux refresh-client -S` for that session on a state
transition, so the bar updates on the event rather than on the timer.

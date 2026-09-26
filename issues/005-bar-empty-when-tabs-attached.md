# cx bar goes empty once cx tabs has attached every session

**Type:** bug  
**Status:** open  
**Found in:** 0.5.0  
**GitHub:** _not yet filed_

---

## Summary

`cx bar` leaves out attached sessions, and `cx tabs` attaches every live
session in a tab of its own. So the moment tabs are open the status line's
counts and names vanish — exactly when they are most useful.

## Fix direction

Exclude a session only when it is attached *and* it is the tab you are looking
at (or attached by another client), not merely attached.

# cx jump from an idle tab can skip a blocked one

**Type:** bug  
**Status:** open  
**Found in:** 0.5.0  
**GitHub:** _not yet filed_

---

## Summary

`cx jump` cycles to whatever follows the current tab in its blocked-then-idle
list. Pressed on an idle tab, it goes to the next *idle* tab even when a
blocked session has a tab — so the key does not land on "the session most in
need of you". Found recording `tabs.gif`: from idle `api@review` it went to
idle `docs`, not blocked `api/authfix`.

## Fix direction

When the current tab is not blocked and any blocked tab exists, go to the first
blocked one; cycle within a state only once you are already in it.

# The server's tmux bar is cut from the left, losing the state

**Type:** bug  
**Status:** open  
**Found in:** 0.5.0  
**GitHub:** _not yet filed_

---

## Summary

At about 113 columns, `cx-agent tmux-status` output is truncated from the
left by tmux: `[cx-api/ratelimit] emo · ctx 9% …`. The state icon and word —
the most important part — are what disappears.

## Fix direction

Put the state first, or set `status-right-length` / drop low-value segments
(model, cost) as width shrinks, so truncation eats the least useful part.

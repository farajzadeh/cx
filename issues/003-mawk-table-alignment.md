# cx ls misaligns columns after ● when awk is mawk

**Type:** bug  
**Status:** open  
**Found in:** 0.5.0  
**GitHub:** _not yet filed_

---

## Summary

`cx_table` in `lib/ui.sh` pads cells with awk's `length()` and `printf "%-Ns"`.
gawk counts characters in a UTF-8 locale; mawk — the default awk on Debian and
Ubuntu — counts bytes. `●` is three bytes, so on those clients every row with
a live session is padded two columns short and the REPO column no longer lines
up. Found while recording the demo GIFs; the demo image installs gawk to avoid
it.

## Reproduction

```sh
printf 'A\tB\n●\tx\n.\ty\n' | mawk -F'\t' '{printf "%-3s|%s\n", $1, $2}'
```

## Fix direction

Measure display width without relying on the awk's locale handling — e.g.
count UTF-8 lead bytes (`gsub(/[\200-\277]/, "")` on a copy before `length`)
and pad by hand instead of with `%-Ns`. Must stay portable to BSD awk and
busybox awk; cover it in a unit test that runs under mawk when available.

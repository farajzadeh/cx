#!/usr/bin/env bash
# docs/demo/record.sh — record the GIFs in docs/media from the tapes.
#
#   docs/demo/record.sh                 set up, record every tape, tear down
#   docs/demo/record.sh hero find       ...only these
#   docs/demo/record.sh --keep hero     leave the servers up afterwards
#   docs/demo/record.sh --no-setup hero reuse servers left up by --keep
#
# Every tape starts from a re-seeded world (setup.sh --seed), so each GIF can
# be re-recorded on its own and comes out the same as in a full run.
#
# Needs Docker and nothing else: VHS, ffmpeg, fzf and gifsicle all live in
# the laptop image (docs/demo/Dockerfile).

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

keep=0
setup=1
names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1 ;;
    --no-setup)
      setup=0
      keep=1
      ;;
    -h | --help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) demo_die "unknown option: $1" ;;
    *) names+=("${1%.tape}") ;;
  esac
  shift
done

if [ ${#names[@]} -eq 0 ]; then
  for t in "$DEMO_DIR"/tapes/*.tape; do
    t=$(basename "$t" .tape)
    [ "$t" = settings ] || names+=("$t")
  done
fi
for n in "${names[@]+"${names[@]}"}"; do
  [ -f "$DEMO_DIR/tapes/$n.tape" ] || demo_die "no such tape: $n"
done

if [ "$keep" = 0 ]; then
  trap '"$DEMO_DIR/teardown.sh"' EXIT
fi
if [ "$setup" = 1 ]; then
  "$DEMO_DIR/setup.sh"
fi

mkdir -p "$ROOT/docs/media"
for n in "${names[@]+"${names[@]}"}"; do
  demo_log "recording $n"
  "$DEMO_DIR/setup.sh" --seed "$n" >/dev/null 2>&1 ||
    "$DEMO_DIR/setup.sh" --seed "$n"
  # VHS writes a GIF far larger than it needs to be. gifsicle's lossy
  # compression costs nothing visible on flat terminal colours and typically
  # halves it again; these files live in the repository.
  demo_run -w /cx/docs/demo/tapes -- -c '
    set -e
    vhs -q "$1.tape"
    gifsicle -O3 --lossy=60 --colors 64 -b "/out/$1.gif"
  ' _ "$n"
  printf '    docs/media/%s.gif  %s KB\n' "$n" \
    "$(($(wc -c <"$ROOT/docs/media/$n.gif") / 1024))" >&2
done

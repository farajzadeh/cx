#!/usr/bin/env bash
# docs/demo/lib.sh — what setup.sh, seed, record.sh and teardown.sh share.
#
# The demo is three containers on a private Docker network:
#
#   cx-demo-web1, cx-demo-web2   the servers: the integration tests' sshd image
#                                (test/integration/node), reachable as web1
#                                and web2 on the network and nowhere else
#   cx-demo-vhs-*                the laptop: VHS plus the cx client, built from
#                                docs/demo/Dockerfile, run once per step
#
# The laptop's home directory is a named volume, so the SSH key, cx's config
# and its cache survive from setup to recording without ever being written
# on the machine running this — nothing here reads or writes the real
# ~/.ssh, ~/.config/cx or ~/.cache/cx.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$DEMO_DIR/../.." && pwd -P)"

# The prefix every demo container is named with. Integration tests clean up
# by prefix, and so does teardown here, so it must not be one they use.
CX_NODE_PREFIX="cx-demo-"
export CX_NODE_PREFIX

DEMO_IMAGE="cx-demo-vhs"
DEMO_NET="cx-demo-net"
DEMO_HOME_VOL="cx-demo-home"
# shellcheck disable=SC2034 # used by the scripts that source this
DEMO_HOSTS="web1 web2"

# demo_run [DOCKER-OPTION...] -- CMD... — run CMD in the laptop container,
# as the demo user, with the repo at /cx and docs/media at /out.
demo_run() {
  local opts=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    opts+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && shift
  docker run --rm \
    --name "${CX_NODE_PREFIX}vhs-$$-$RANDOM" \
    --network "$DEMO_NET" \
    -v "$DEMO_HOME_VOL:/home/demo" \
    -v "$ROOT:/cx:ro" \
    -v "$ROOT/docs/media:/out" \
    "${opts[@]+"${opts[@]}"}" \
    --entrypoint /bin/bash \
    "$DEMO_IMAGE" "$@"
}

demo_log() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
demo_die() {
  printf 'demo: %s\n' "$*" >&2
  exit 1
}

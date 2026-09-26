#!/usr/bin/env bash
# docs/demo/teardown.sh — remove everything setup.sh made, except images.
#
# Containers are found by the cx-demo- prefix and nothing else, so the
# integration tests' nodes (cx-test-node-*) and anything else running on this
# machine are never touched. The images stay: rebuilding them is the slow
# part, and `docker rmi cx-demo-vhs` removes the big one by hand.

set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

docker ps -aq --filter "name=^$CX_NODE_PREFIX" | while IFS= read -r id; do
  [ -n "$id" ] && docker rm -f "$id" >/dev/null 2>&1
done
docker network rm "$DEMO_NET" >/dev/null 2>&1 || true
docker volume rm "$DEMO_HOME_VOL" >/dev/null 2>&1 || true
exit 0

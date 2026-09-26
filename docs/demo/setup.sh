#!/usr/bin/env bash
# docs/demo/setup.sh — build the demo world: two servers and a laptop.
#
#   docs/demo/setup.sh          build images, start web1 and web2, provision
#                               them with the real `cx provision`, and seed
#                               projects, worktrees and live sessions
#   docs/demo/setup.sh --seed [TAPE]
#                               only re-seed: put the projects and sessions
#                               back as they were, on servers already up —
#                               less whatever TAPE creates on camera
#
# Needs Docker and nothing else. Undo with docs/demo/teardown.sh.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=../../test/integration/lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

seed_only=0
tape=""
if [ "${1:-}" = --seed ]; then
  seed_only=1
  tape="${2:-}"
fi

if [ "$seed_only" = 0 ]; then
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 ||
    demo_die "Docker is required, and must be running"

  # Anything left from an earlier run, by this prefix only.
  "$DEMO_DIR/teardown.sh" >/dev/null 2>&1 || true

  demo_log "building the server image (test/integration/node)"
  nodes_build || demo_die "could not build $CX_NODE_IMAGE"

  demo_log "building the laptop image (docs/demo/Dockerfile)"
  docker build -q \
    --build-arg "UID=$(id -u)" --build-arg "GID=$(id -g)" \
    -t "$DEMO_IMAGE" "$DEMO_DIR" >/dev/null ||
    demo_die "could not build $DEMO_IMAGE"

  docker network create "$DEMO_NET" >/dev/null
  docker volume create "$DEMO_HOME_VOL" >/dev/null
  mkdir -p "$ROOT/docs/media"

  demo_log "creating the laptop's home: an SSH key and two cx hosts"
  demo_run -- /cx/docs/demo/inside.sh init

  pubkey=$(demo_run -- -c 'cat ~/.ssh/id_ed25519.pub')

  for h in $DEMO_HOSTS; do
    demo_log "starting $h"
    # Not nodes_start: that publishes sshd on a localhost port, which would
    # put 127.0.0.1 and a random port into `cx host ls` in the pictures. On a
    # network of their own the servers are simply web1 and web2.
    docker run -d --rm \
      --name "$CX_NODE_PREFIX$h" \
      --hostname "$h" \
      --network "$DEMO_NET" --network-alias "$h" \
      "$CX_NODE_IMAGE" >/dev/null
    # The image installs a key from /pubkey at start; this one arrives after.
    printf '%s\n' "$pubkey" | docker exec -i "$CX_NODE_PREFIX$h" sh -c '
      mkdir -p /home/cxuser/.ssh &&
      cat > /home/cxuser/.ssh/authorized_keys &&
      chown -R cxuser:cxuser /home/cxuser/.ssh &&
      chmod 700 /home/cxuser/.ssh && chmod 600 /home/cxuser/.ssh/authorized_keys'
  done

  demo_log "provisioning web1 and web2 with cx provision (installs tmux, git, jq)"
  demo_run -- /cx/docs/demo/inside.sh provision ||
    demo_die "provisioning failed"
fi

demo_log "seeding projects, worktrees and sessions"
demo_run -- /cx/docs/demo/inside.sh seed "$tape" || demo_die "seeding failed"
demo_log "ready — record with docs/demo/record.sh, remove with docs/demo/teardown.sh"

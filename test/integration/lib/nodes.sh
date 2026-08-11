#!/usr/bin/env bash
# test/integration/lib/nodes.sh — spin up throwaway SSH servers.
#
# Gives integration tests a real SSH transport: real sshd, real key auth, real
# package installation. Everything is scoped to a temp HOME so a test run can
# never touch the developer's own ~/.ssh, ~/.config/cx or ~/.cache/cx.

CX_NODE_IMAGE="cx-test-node"
CX_NODE_PREFIX="cx-test-node-"

# nodes_build [BASE_IMAGE]
nodes_build() {
  local base="${1:-ubuntu:24.04}"
  docker build -q \
    --build-arg "BASE=$base" \
    -t "$CX_NODE_IMAGE" \
    "$ROOT/test/integration/node" >/dev/null 2>&1
}

# nodes_env — create an isolated HOME with a fresh SSH key.
# Echoes the directory. The caller is responsible for nodes_cleanup.
nodes_env() {
  local home
  home=$(mktemp -d "${TMPDIR:-/tmp}/cxtest.XXXXXX")
  mkdir -p "$home/.ssh" "$home/.config/cx/ssh.d" "$home/.cache/cx"
  chmod 700 "$home/.ssh" "$home/.config/cx/ssh.d"
  ssh-keygen -q -t ed25519 -N "" -f "$home/.ssh/id_ed25519" -C cx-test
  mkdir -p "$home/pubkey"
  cp "$home/.ssh/id_ed25519.pub" "$home/pubkey/authorized_keys"

  # Host keys change every run, so pin verification off for these throwaway
  # containers only — this file never touches the developer's real config.
  cat >"$home/.ssh/config" <<EOF
Include $home/.config/cx/ssh.d/*.conf

Host cx-test-*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
  chmod 600 "$home/.ssh/config"
  printf '%s' "$home"
}

# nodes_start NAME HOME — run a node and wait for sshd. Echoes the port.
nodes_start() {
  local name="$1" home="$2" port

  port=$(_nodes_free_port)
  docker run -d --rm \
    --name "$CX_NODE_PREFIX$name" \
    -v "$home/pubkey":/pubkey:ro \
    -p "127.0.0.1:$port:22" \
    "$CX_NODE_IMAGE" >/dev/null 2>&1 || return 1

  # Poll rather than sleep: sshd start time varies with host load, and a fixed
  # sleep is either flaky or slow.
  local i=0
  while [ "$i" -lt 60 ]; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=2 -o BatchMode=yes -o LogLevel=ERROR \
      -i "$home/.ssh/id_ed25519" -p "$port" cxuser@127.0.0.1 true 2>/dev/null; then
      printf '%s' "$port"
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  docker rm -f "$CX_NODE_PREFIX$name" >/dev/null 2>&1
  return 1
}

_nodes_free_port() {
  # Ask the kernel for an unused port rather than guessing, so parallel runs
  # and busy machines do not collide.
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null ||
    printf '%s' $((20000 + RANDOM % 20000))
}

# nodes_add_host HOME ALIAS PORT — write a cx host definition for a node.
nodes_add_host() {
  local home="$1" alias="$2" port="$3"
  cat >"$home/.config/cx/ssh.d/$alias.conf" <<EOF
#cx:root=projects

Host $alias
    HostName 127.0.0.1
    User cxuser
    Port $port
    IdentityFile $home/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
  chmod 600 "$home/.config/cx/ssh.d/$alias.conf"
}

# nodes_cleanup [HOME] — remove every test container, and the temp HOME.
nodes_cleanup() {
  docker ps -a --filter "name=$CX_NODE_PREFIX" --format '{{.Names}}' 2>/dev/null |
    while IFS= read -r n; do
      [ -n "$n" ] && docker rm -f "$n" >/dev/null 2>&1
    done
  if [ -n "${1:-}" ] && [ -d "$1" ]; then
    # Multiplexed sockets outlive the containers; drop them or the next run
    # inherits a dead connection.
    rm -f "$1"/.ssh/cm-* 2>/dev/null || true
    rm -rf "$1"
  fi
}

# cx_run HOME ARG... — run the client against an isolated HOME.
cx_run() {
  local home="$1"
  shift
  env HOME="$home" \
    CX_HOME="$ROOT" \
    CX_CONFIG_DIR="$home/.config/cx" \
    CX_CONFIG_FILE="$home/.config/cx/config" \
    CX_SSHD_DIR="$home/.config/cx/ssh.d" \
    CX_CACHE_DIR="$home/.cache/cx" \
    CX_SSH_CONFIG="$home/.ssh/config" \
    CX_ASSUME_YES=1 \
    NO_COLOR=1 \
    bash "$ROOT/bin/cx" "$@" 2>&1
}

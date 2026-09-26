#!/usr/bin/env bash
# docs/demo/inside.sh STEP — the steps of setup.sh that run on the laptop.
#
# Runs INSIDE the laptop container (docs/demo/Dockerfile), as the demo user,
# with the repository at /cx. setup.sh calls it; nothing else should.
#
#   init        an SSH key, ~/.ssh/config, and cx host definitions for web1
#               and web2 — the files `cx host add` would have written
#   provision   `cx provision` both servers, then dress them for the camera:
#               the demo Claude, git identity, and "GitHub" repositories
#   seed [TAPE] reset both servers to the same projects, worktrees and live
#               sessions, so every recording starts from the same world —
#               less whatever TAPE is about to create on camera

set -euo pipefail

CX=/cx/bin/cx
DEMO=/cx/docs/demo

# ssh_node HOST — run a script from stdin on HOST, as cxuser. Plain ssh rather
# than cx: this is scenery, and the agent has no verb for it.
ssh_node() { ssh -o BatchMode=yes "$1" bash -s; }

step_init() {
  mkdir -p ~/.ssh ~/.config/cx/ssh.d ~/.cache/cx
  chmod 700 ~/.ssh ~/.config/cx/ssh.d
  [ -f ~/.ssh/id_ed25519 ] ||
    ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C demo@laptop

  # The servers' host keys change every run, so verification is off for these
  # two names only, and only inside this throwaway home.
  cat >~/.ssh/config <<'EOF'
Include ~/.config/cx/ssh.d/*.conf

Host web1 web2
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
  chmod 600 ~/.ssh/config

  local h
  for h in web1 web2; do
    # The same shape cx_host_write produces, so `cx host ls` shows what a
    # real `cx host add` would have left behind.
    cat >~/.config/cx/ssh.d/"$h".conf <<EOF
# Managed by cx. Edit with: cx host edit $h
# Removing this file removes the host from cx and from ssh.
#cx:root=projects

Host $h
    HostName $h
    User cxuser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
    chmod 600 ~/.config/cx/ssh.d/"$h".conf
  done
}

step_provision() {
  local h i
  for h in web1 web2; do
    # sshd takes a moment to come up in a fresh container.
    i=0
    until ssh -o BatchMode=yes -o ConnectTimeout=2 "$h" true 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -lt 60 ] || {
        echo "demo: $h never answered" >&2
        return 1
      }
      sleep 0.5
    done
    CX_ASSUME_YES=1 "$CX" provision "$h" >/tmp/provision-"$h".log 2>&1 || {
      cat /tmp/provision-"$h".log >&2
      return 1
    }
    scp -q "$DEMO/claude-demo.sh" "$h":.local/bin/claude
    ssh_node "$h" <"$DEMO/node-prep.sh"
  done
}

# settle SECONDS — let the demo Claude finish a turn.
settle() { sleep "$1"; }

step_seed() {
  # Which recording this world is for. Most share one; a tape that shows
  # something being CREATED needs a world where it does not exist yet.
  local tape="${1:-}" h review=1 authfix=1
  case "$tape" in
    parallel) review=0 ;;     # it opens web1:api@review itself
    create-open) authfix=0 ;; # it adds web1:api/authfix itself
  esac

  for h in web1 web2; do
    ssh_node "$h" <<'EOF'
tmux kill-server 2>/dev/null || true
rm -rf ~/projects ~/.claude ~/.cx-demo \
  ~/.local/share/cx/projects.json ~/.local/share/cx/sessions.json \
  ~/.local/share/cx/goals.json ~/.local/share/cx/state
mkdir -p ~/.cx-demo
EOF
  done
  rm -rf ~/.cache/cx
  mkdir -p ~/.cache/cx

  # How each session behaves when prompted — see claude-demo.sh.
  ssh_node web1 <<'EOF'
printf '%s\n' 'api/authfix ask' 'api/ratelimit slow' >~/.cx-demo/scenarios
EOF

  export CX_ASSUME_YES=1 CX_OPEN_AFTER_CREATE=never
  "$CX" new web1:api --repo git@github.com:acme/api.git >/dev/null 2>&1
  "$CX" new web1:web --repo git@github.com:acme/web.git >/dev/null 2>&1
  "$CX" new web2:docs --repo git@github.com:acme/docs.git >/dev/null 2>&1
  "$CX" new web2:infra --repo git@github.com:acme/infra.git >/dev/null 2>&1
  [ "$authfix" = 0 ] || "$CX" wt add web1:api/authfix >/dev/null 2>&1
  "$CX" wt add web1:api/ratelimit >/dev/null 2>&1

  # Work in progress on the branches, so they are more than a name.
  ssh_node web1 <<'EOF'
if cd ~/projects/.worktrees/api/authfix 2>/dev/null; then
  printf 'export const SAMESITE = "Lax";\n' >>src/auth/session.ts
  git commit -qam "Rotate refresh tokens on every use"
fi
cd ~/projects/.worktrees/api/ratelimit
mkdir -p load && printf 'export default function () {}\n' >load/ratelimit.js
git add load && git commit -qm "Add a load test for the limiter"
printf '// wip\n' >>src/server.ts
EOF

  "$CX" open -d web1:api >/dev/null 2>&1
  [ "$review" = 0 ] || "$CX" open -d web1:api@review >/dev/null 2>&1
  [ "$authfix" = 0 ] || "$CX" open -d web1:api/authfix >/dev/null 2>&1
  "$CX" open -d web1:api/ratelimit >/dev/null 2>&1
  "$CX" open -d web2:docs >/dev/null 2>&1
  settle 2

  "$CX" nudge web1:api "where do we refresh auth tokens?" >/dev/null 2>&1
  [ "$review" = 0 ] ||
    "$CX" nudge web1:api@review "review the authfix branch" >/dev/null 2>&1
  "$CX" nudge web2:docs "document the new session cookie" >/dev/null 2>&1
  [ "$authfix" = 0 ] ||
    "$CX" nudge web1:api/authfix "apply the pending migration on staging" >/dev/null 2>&1
  "$CX" nudge web1:api/ratelimit "load-test the new limiter" >/dev/null 2>&1
  settle 12

  # Earlier conversations, so the SESSIONS and ACTIVE columns look lived in:
  # copies of today's, renamed and backdated. They are never opened again.
  ssh_node web1 <<'EOF'
. ~/.local/share/cx-demo/history.sh
history_fill ~/projects/api 11 "4 minutes ago"
[ ! -d ~/projects/.worktrees/api/authfix ] ||
  history_fill ~/projects/.worktrees/api/authfix 2 "1 minute ago"
history_fill ~/projects/.worktrees/api/ratelimit 1 "30 seconds ago"
history_fill ~/projects/web 3 "2 days ago"
EOF
  ssh_node web2 <<'EOF'
. ~/.local/share/cx-demo/history.sh
history_fill ~/projects/docs 5 "20 minutes ago"
history_fill ~/projects/infra 7 "6 hours ago"
EOF

  # Warm the cache that shell completion and the pickers read.
  "$CX" ls >/dev/null 2>&1 || true
  "$CX" peek >/dev/null 2>&1 || true
}

case "${1:-}" in
  init) step_init ;;
  provision) step_provision ;;
  seed) step_seed "${2:-}" ;;
  *)
    echo "usage: inside.sh init|provision|seed [TAPE]" >&2
    exit 3
    ;;
esac

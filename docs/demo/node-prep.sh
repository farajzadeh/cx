#!/usr/bin/env bash
# docs/demo/node-prep.sh — dress a provisioned demo server for the camera.
#
# Runs ON the server, as cxuser, fed over ssh by `inside.sh provision` after
# `cx provision` has installed tmux, git and jq. Nothing here is cx: it is
# the scenery cx is filmed against.

set -eu

share="$HOME/.local/share/cx-demo"
mkdir -p "$share/bin" "$HOME/git/acme"

# The demo Claude re-execs itself through a copy of sh named `claude`, so the
# pane's command reads as claude — see the top of claude-demo.sh.
# Copied then renamed: a session may already be running from it, and a file
# being executed cannot be overwritten in place ("Text file busy").
cp /bin/sh "$share/bin/claude.new"
mv -f "$share/bin/claude.new" "$share/bin/claude"
chmod 755 "$share/bin/claude" "$HOME/.local/bin/claude"

# "GitHub", served from ~/git. The projects are cloned from
# git@github.com:acme/<name>.git so that URL is what cx records and shows;
# this ssh command is what git runs to reach it, and it never leaves the box.
# (A url.insteadOf rewrite would be simpler, but `git remote get-url` expands
# it, and cx records what that says — the REPO column would show a path.)
cat >"$share/bin/github-ssh" <<'EOF'
#!/bin/sh
# git runs: <this> [options] git@github.com "git-upload-pack 'acme/x.git'"
while [ $# -gt 1 ]; do shift; done
cd "$HOME/git" && exec sh -c "$1"
EOF
chmod 755 "$share/bin/github-ssh"

# cx looks for Claude's credentials to say whether a server is signed in. The
# demo Claude needs none, and this file only stops cx saying "cx login web1"
# under every command in the recordings.
[ -s "$HOME/.claude.json" ] ||
  printf '{"demo":"placeholder, no credentials"}\n' >"$HOME/.claude.json"

git config --global user.name "Sam Rivera"
git config --global user.email sam@example.com
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global core.sshCommand "$share/bin/github-ssh"

# mkrepo NAME FILE... — a bare repository with a few days of history.
mkrepo() {
  local name="$1" work day=5 f when
  shift
  [ -d "$HOME/git/acme/$name.git" ] && return 0
  work=$(mktemp -d)
  git init -q "$work"
  for f in "$@"; do
    mkdir -p "$work/$(dirname "$f")"
    printf '// %s\n' "$f" >"$work/$f"
    git -C "$work" add "$f"
    when="@$(($(date +%s) - day * 86400)) +0000"
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
      git -C "$work" commit -qm "Add $f"
    [ "$day" -gt 1 ] && day=$((day - 1))
  done
  git clone -q --bare "$work" "$HOME/git/acme/$name.git"
  rm -rf "$work"
}

mkrepo api package.json src/server.ts src/auth/session.ts src/routes/login.ts README.md
mkrepo web package.json src/app.tsx src/pages/login.tsx
mkrepo docs mkdocs.yml docs/index.md docs/auth.md
mkrepo infra main.tf modules/db/main.tf README.md
mkrepo blog config.toml content/posts/hello.md layouts/index.html

# Sessions are started detached, before anyone attaches, so tmux sizes them
# by this — the size of the terminal in the recordings. Anything smaller and
# the demo Claude draws its boxes for a narrower screen than it ends up on.
# Appended: provisioning wrote cx's own ~/.tmux.conf, and that is part of
# what is being shown.
grep -q '^# cx-demo' "$HOME/.tmux.conf" 2>/dev/null ||
  cat >>"$HOME/.tmux.conf" <<'EOF'

# cx-demo: sized for the recordings
set -g default-size 113x26
set -g status-style "bg=colour236,fg=colour250"
set -g status-left-length 30
# cx puts its own facts on the right of a session's bar, then whatever the
# global status-right holds. tmux's default (hostname, clock, date) pushes
# the bar past 113 columns, and tmux then cuts it from the left.
set -g status-right ""
# One window per session, so the window list says nothing — and squeezed by
# cx's long right side it is drawn as a truncated "<claud>".
set -g window-status-format ""
set -g window-status-current-format ""
EOF

# history_fill DIR N AGE — N earlier conversations for DIR, the newest AGE
# old. Copies of a real-shaped transcript under new ids, and never opened.
cat >"$share/history.sh" <<'EOF'
history_fill() {
  dir="$1" n="$2" age="$3"
  store="$HOME/.claude/projects/$(printf '%s' "$dir" | tr -c 'A-Za-z0-9-' '-')"
  mkdir -p "$store"
  base=$(date -d "$age" +%s)
  i=0
  while [ "$i" -lt "$n" ]; do
    id=$(cat /proc/sys/kernel/random/uuid)
    printf '{"type":"user","isSidechain":false,"sessionId":"%s","message":{"role":"user","content":"earlier work"}}\n{"type":"assistant","isSidechain":false,"sessionId":"%s","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}\n' \
      "$id" "$id" >"$store/$id.jsonl"
    touch -d "@$((base - i * 5400))" "$store/$id.jsonl"
    i=$((i + 1))
  done
}
EOF

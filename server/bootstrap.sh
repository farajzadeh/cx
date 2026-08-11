#!/bin/sh
# server/bootstrap.sh — prepare a server to host cx projects.
#
# Invoked as:  ssh -t HOST sh -s -- [OPTIONS] < server/bootstrap.sh
#
# POSIX sh ON PURPOSE. cx-agent is bash, but a minimal server (Alpine, some
# container images) may not have bash at all — so the script that installs
# dependencies cannot itself require one of them. Running under /bin/sh means
# this works everywhere and can install bash before anything needs it.
#
# Idempotent: safe to re-run, and re-running is the upgrade path.
# Conservative: never overwrites an existing ~/.tmux.conf or projects.json,
# and never invokes sudo when nothing needs installing.

set -eu

CX_AGENT_SRC="${CX_AGENT_SRC:-/tmp/cx-agent.incoming}"
CX_PROJECT_ROOT="${CX_PROJECT_ROOT:-$HOME/projects}"
CX_BIN_DIR="$HOME/.local/bin"
CX_DATA_DIR="$HOME/.local/share/cx"
CX_REGISTRY="$CX_DATA_DIR/projects.json"

DRY_RUN=0
SKIP_CLAUDE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-claude) SKIP_CLAUDE=1 ;; # for CI, where a stub claude is supplied
    --root)
      shift
      CX_PROJECT_ROOT="${1:-$CX_PROJECT_ROOT}"
      ;;
    *) ;;
  esac
  shift
done

# Progress goes to stderr; the final machine-readable summary goes to stdout,
# so the client can parse the result without stripping log noise.
log() { printf '  %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }
warn() { printf '  ! %s\n' "$*" >&2; }
die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# This script runs as `ssh host sh -s`, a non-interactive shell that reads
# neither ~/.bashrc nor ~/.profile — so ~/.local/bin is not on PATH. Without
# this, a re-provision cannot see an already-installed Claude Code and
# reinstalls it every single time.
PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"
export PATH

# ---------------------------------------------------------------------------
# Privilege
# ---------------------------------------------------------------------------

# SUDO is empty when we are already root or when nothing needs installing.
SUDO=""
need_sudo() {
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
    return 0
  fi
  if have sudo; then
    SUDO="sudo"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Package manager
# ---------------------------------------------------------------------------

detect_pm() {
  for pm in apt-get dnf yum pacman zypper apk; do
    if have "$pm"; then
      printf '%s' "$pm"
      return 0
    fi
  done
  printf 'none'
}

# pkg_name TOOL PM — the package providing TOOL on this distro. Mostly the
# tool's own name; the exceptions below are the ones that actually differ.
pkg_name() {
  tool="$1"
  pm="$2"
  case "$tool" in
    curl) printf 'curl' ;;
    *)
      case "$pm:$tool" in
        *:bash) printf 'bash' ;;
        *:tmux) printf 'tmux' ;;
        *:git) printf 'git' ;;
        *:jq) printf 'jq' ;;
        *) printf '%s' "$tool" ;;
      esac
      ;;
  esac
}

pm_install() {
  pm="$1"
  shift
  [ $# -gt 0 ] || return 0
  case "$pm" in
    apt-get)
      $SUDO apt-get update -qq
      # `env` rather than a bare assignment prefix: when $SUDO is empty (we are
      # root), the shell has already consumed a word, so `VAR=x cmd` would be
      # parsed as a command named "VAR=x" instead of an assignment.
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
      ;;
    dnf) $SUDO dnf install -y -q "$@" ;;
    yum) $SUDO yum install -y -q "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "$@" ;;
    zypper) $SUDO zypper --non-interactive install "$@" ;;
    apk) $SUDO apk add --no-progress "$@" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------

step "Dependencies"

MISSING=""
for tool in bash tmux git jq curl; do
  if have "$tool"; then
    log "ok       $tool"
  else
    log "missing  $tool"
    MISSING="$MISSING $tool"
  fi
done

# Trim leading space so the emptiness check below is meaningful.
MISSING="${MISSING# }"

if [ -n "$MISSING" ]; then
  PM=$(detect_pm)
  if [ "$PM" = none ]; then
    die "No supported package manager found (tried apt-get, dnf, yum, pacman, zypper, apk).
       Install these manually, then re-run: $MISSING"
  fi

  PKGS=""
  for tool in $MISSING; do
    PKGS="$PKGS $(pkg_name "$tool" "$PM")"
  done

  if [ "$DRY_RUN" = 1 ]; then
    log "would install via $PM:$PKGS"
  else
    if ! need_sudo; then
      die "Need to install:$PKGS
       but this account is not root and sudo is unavailable.
       Ask an administrator to install them, then re-run."
    fi
    log "installing via $PM:$PKGS"
    # shellcheck disable=SC2086
    pm_install "$PM" $PKGS >&2 || die "Package installation failed. Install manually:$PKGS"

    for tool in $MISSING; do
      have "$tool" || die "$tool still not found after installation."
    done
    log "installed"
  fi
else
  # The common case on a re-run. Worth stating explicitly: it is why
  # re-provisioning never prompts for a password.
  log "all present — sudo not needed"
fi

# ---------------------------------------------------------------------------
# 2. Directories
# ---------------------------------------------------------------------------

step "Directories"

for d in "$CX_BIN_DIR" "$CX_DATA_DIR" "$CX_PROJECT_ROOT"; do
  if [ -d "$d" ]; then
    log "exists   $d"
  elif [ "$DRY_RUN" = 1 ]; then
    log "would create $d"
  else
    mkdir -p "$d"
    log "created  $d"
  fi
done

# ---------------------------------------------------------------------------
# 3. PATH
# ---------------------------------------------------------------------------
#
# A non-interactive `ssh host cx-agent ...` does not read .bashrc, so
# ~/.local/bin must be on PATH via .profile — and the client always invokes
# the agent by absolute path as a belt-and-braces fallback.

step "PATH"

PROFILE="$HOME/.profile"
PATH_MARK="# added by cx"
if [ -r "$PROFILE" ] && grep -q "$PATH_MARK" "$PROFILE" 2>/dev/null; then
  log "already configured in ~/.profile"
elif [ "$DRY_RUN" = 1 ]; then
  log "would add ~/.local/bin to PATH in ~/.profile"
else
  {
    printf '\n%s\n' "$PATH_MARK"
    printf 'case ":$PATH:" in\n'
    printf '  *":$HOME/.local/bin:"*) ;;\n'
    printf '  *) PATH="$HOME/.local/bin:$PATH" ;;\n'
    printf 'esac\n'
  } >>"$PROFILE"
  log "added ~/.local/bin to PATH in ~/.profile"
fi

# ---------------------------------------------------------------------------
# 4. tmux configuration
# ---------------------------------------------------------------------------
#
# Only written when absent. Clobbering a hand-tuned tmux config would be an
# unforgivable thing for a tool like this to do.

step "tmux config"

if [ -e "$HOME/.tmux.conf" ]; then
  # shellcheck disable=SC2088  # display text for the user, not a path to expand
  log "~/.tmux.conf exists — left untouched"
elif [ "$DRY_RUN" = 1 ]; then
  log "would write ~/.tmux.conf"
else
  cat >"$HOME/.tmux.conf" <<'TMUXCONF'
# Written by cx because no ~/.tmux.conf existed.
# Edit freely — cx will never overwrite this file.

set -g mouse on              # scroll wheel and click-to-select
set -g history-limit 100000  # deep scrollback for long agent sessions
set -sg escape-time 10       # Esc lag is very noticeable inside Claude Code
set -g focus-events on
setw -g mode-keys vi         # / to search in copy mode

set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
TMUXCONF
  log "wrote ~/.tmux.conf"
fi

# ---------------------------------------------------------------------------
# 5. Registry
# ---------------------------------------------------------------------------

step "Registry"

if [ -e "$CX_REGISTRY" ]; then
  log "exists   $CX_REGISTRY"
elif [ "$DRY_RUN" = 1 ]; then
  log "would initialise $CX_REGISTRY"
else
  cat >"$CX_REGISTRY" <<EOF
{
  "version": 1,
  "root": "$CX_PROJECT_ROOT",
  "projects": []
}
EOF
  log "initialised $CX_REGISTRY"
fi

# ---------------------------------------------------------------------------
# 6. Claude Code
# ---------------------------------------------------------------------------

step "Claude Code"

CLAUDE_PRESENT=0
if have claude; then
  CLAUDE_PRESENT=1
  log "already installed: $(command -v claude)"
elif [ "$SKIP_CLAUDE" = 1 ]; then
  log "skipped (--skip-claude)"
elif [ "$DRY_RUN" = 1 ]; then
  log "would install Claude Code"
else
  log "installing Claude Code..."
  if curl -fsSL https://claude.ai/install.sh | bash >&2; then
    # The installer puts it in ~/.local/bin, which may not be on PATH in this
    # non-login shell yet.
    PATH="$CX_BIN_DIR:$PATH"
    export PATH
    if have claude; then
      CLAUDE_PRESENT=1
      log "installed"
    else
      warn "installer finished but 'claude' is still not on PATH"
    fi
  else
    warn "Claude Code installation failed — install it manually, then re-run"
  fi
fi

# Credentials are a separate, interactive step. Detect rather than attempt.
CLAUDE_LOGGED_IN=0
if [ -d "$HOME/.claude" ] &&
  { [ -s "$HOME/.claude/.credentials.json" ] || [ -s "$HOME/.claude.json" ]; }; then
  CLAUDE_LOGGED_IN=1
  log "credentials present"
else
  log "no credentials yet"
fi

# ---------------------------------------------------------------------------
# 7. Agent
# ---------------------------------------------------------------------------

step "Agent"

AGENT_VERSION="unknown"
if [ -e "$CX_AGENT_SRC" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    log "would install cx-agent from $CX_AGENT_SRC"
  else
    mv -f "$CX_AGENT_SRC" "$CX_BIN_DIR/cx-agent"
    chmod 755 "$CX_BIN_DIR/cx-agent"
    AGENT_VERSION=$("$CX_BIN_DIR/cx-agent" version 2>/dev/null || printf 'unknown')
    log "installed cx-agent $AGENT_VERSION"
  fi
elif [ -x "$CX_BIN_DIR/cx-agent" ]; then
  AGENT_VERSION=$("$CX_BIN_DIR/cx-agent" version 2>/dev/null || printf 'unknown')
  log "kept existing cx-agent $AGENT_VERSION (nothing new was uploaded)"
else
  die "No agent at $CX_AGENT_SRC and none installed.
       The client should upload cx-agent before running bootstrap."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

step "Done"
if [ "$CLAUDE_LOGGED_IN" = 0 ]; then
  printf '\n  Next: complete the one-time interactive sign-in with\n' >&2
  printf '    cx login <host>\n\n' >&2
fi

# Machine-readable summary on stdout. Hand-built rather than via jq so that
# bootstrap has no dependency on a package it may have just installed.
printf '{"ok":true,"agent_version":"%s","project_root":"%s","claude_installed":%s,"claude_logged_in":%s,"dry_run":%s}\n' \
  "$AGENT_VERSION" "$CX_PROJECT_ROOT" \
  "$([ "$CLAUDE_PRESENT" = 1 ] && printf 'true' || printf 'false')" \
  "$([ "$CLAUDE_LOGGED_IN" = 1 ] && printf 'true' || printf 'false')" \
  "$([ "$DRY_RUN" = 1 ] && printf 'true' || printf 'false')"

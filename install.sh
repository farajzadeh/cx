#!/usr/bin/env bash
# install.sh — installer for the cx client.
#
#   curl -fsSL https://raw.githubusercontent.com/farajzadeh/cx/main/install.sh | bash
#   git clone https://github.com/farajzadeh/cx && cd cx && ./install.sh
#
# STANDALONE BY NECESSITY: this runs before the repo exists on the machine, so
# it cannot source lib/compat.sh. The small amount of duplicated portability
# logic below is the price of a working one-liner install, and is kept minimal.
#
# Targets bash 3.2 (macOS's default) — see docs/ARCHITECTURE.md.

# Re-exec under bash if invoked as `sh install.sh`.
# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -u

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CX_REPO_URL="${CX_REPO_URL:-https://github.com/farajzadeh/cx}"
CX_REPO_BRANCH="${CX_REPO_BRANCH:-main}"

MIN_BASH=3.2
MIN_SSH=7.3 # 7.3 introduced `Include` in ssh_config

# Exit codes — stable and documented, so `install.sh --check` is usable inside
# someone else's provisioning script.
EXIT_OK=0
EXIT_MISSING_REQUIRED=1
EXIT_MISSING_OPTIONAL=2
EXIT_UNSUPPORTED=3

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m')
  C_RED=$(printf '\033[31m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
  C_CYAN=$(printf '\033[36m')
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

say() { printf '%s\n' "$*"; }
hdr() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
err() { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# row STATUS NAME VALUE [HINT]
# STATUS: ok | miss | opt | info
row() {
  local status="$1" name="$2" value="$3" hint="${4:-}" mark color
  case "$status" in
    ok) mark='✓' color="$C_GREEN" ;;
    miss) mark='✗' color="$C_RED" ;;
    opt) mark='-' color="$C_YELLOW" ;;
    *) mark=' ' color="$C_DIM" ;;
  esac
  printf '  %s%s%s %-14s %s%s%s\n' \
    "$color" "$mark" "$C_RESET" "$name" "$C_DIM" "$value" "$C_RESET"
  if [ -n "$hint" ]; then
    printf '      %s→ %s%s\n' "$C_CYAN" "$hint" "$C_RESET"
  fi
}

# ---------------------------------------------------------------------------
# Portability helpers (minimal duplicates of lib/compat.sh)
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# version_ge A B — true if version A >= version B. Trims non-numeric suffixes
# so "3.2.57(1)-release" and "9.6p1" compare correctly.
version_ge() {
  local a="$1" b="$2" ai bi pair
  # shellcheck disable=SC2086
  set -- ${a//./ }
  local a1="${1:-0}" a2="${2:-0}" a3="${3:-0}"
  # shellcheck disable=SC2086
  set -- ${b//./ }
  local b1="${1:-0}" b2="${2:-0}" b3="${3:-0}"
  for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3"; do
    ai=$(printf '%s' "${pair%%:*}" | sed 's/[^0-9].*$//')
    bi=$(printf '%s' "${pair##*:}" | sed 's/[^0-9].*$//')
    [ -n "$ai" ] || ai=0
    [ -n "$bi" ] || bi=0
    [ "$ai" -gt "$bi" ] && return 0
    [ "$ai" -lt "$bi" ] && return 1
  done
  return 0
}

detect_os() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    *BSD*) echo bsd ;;
    CYGWIN* | MINGW* | MSYS*) echo windows ;;
    *) echo unknown ;;
  esac
}

# detect_distro — a human label for the report, best effort only.
detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null
    printf '%s %s' "${NAME:-linux}" "${VERSION_ID:-}"
  elif [ "$(detect_os)" = macos ]; then
    printf 'macOS %s' "$(sw_vers -productVersion 2>/dev/null || echo '')"
  else
    uname -sr 2>/dev/null
  fi
}

# detect_pm — the package manager, used to render an actionable fix command.
detect_pm() {
  if [ "$(detect_os)" = macos ]; then
    have brew && echo brew || echo none-macos
    return
  fi
  for pm in apt-get dnf yum pacman zypper apk; do
    have "$pm" && {
      echo "$pm"
      return
    }
  done
  echo none
}

# install_hint PACKAGE — how to install PACKAGE on this machine.
install_hint() {
  local pkg="$1"
  case "$(detect_pm)" in
    apt-get) echo "sudo apt-get install -y $pkg" ;;
    dnf) echo "sudo dnf install -y $pkg" ;;
    yum) echo "sudo yum install -y $pkg" ;;
    pacman) echo "sudo pacman -S --noconfirm $pkg" ;;
    zypper) echo "sudo zypper install -y $pkg" ;;
    apk) echo "sudo apk add $pkg" ;;
    brew) echo "brew install $pkg" ;;
    none-macos) echo "install Homebrew (https://brew.sh), then: brew install $pkg" ;;
    *) echo "install '$pkg' with your package manager" ;;
  esac
}

# Version extractors. Each tool reports its version differently, and ssh
# writes to stderr rather than stdout.
ver_bash() { printf '%s' "${BASH_VERSION%%(*}"; }
ver_ssh() { ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][^ ,]*\).*/\1/p' | head -1; }
ver_jq() { jq --version 2>/dev/null | sed 's/^jq-//'; }
ver_git() { git --version 2>/dev/null | sed -n 's/^git version \([0-9.]*\).*/\1/p'; }

# ---------------------------------------------------------------------------
# Requirement check
# ---------------------------------------------------------------------------

MISSING_REQUIRED=0
MISSING_OPTIONAL=0

check_requirements() {
  local os distro v

  os=$(detect_os)
  distro=$(detect_distro)

  hdr "System"
  row info "os" "$os${distro:+ ($distro)}"
  row info "arch" "$(uname -m 2>/dev/null || echo unknown)"
  row info "shell" "$(basename "${SHELL:-unknown}")"
  row info "package mgr" "$(detect_pm)"

  if [ "$os" = unknown ]; then
    hdr "Result"
    err "Unsupported platform: $(uname -s 2>/dev/null)"
    say "  cx targets Linux and macOS. Windows users: install under WSL."
    return "$EXIT_UNSUPPORTED"
  fi
  if [ "$os" = windows ]; then
    hdr "Result"
    err "Native Windows is not supported."
    say "  Install cx inside WSL instead: https://learn.microsoft.com/windows/wsl/install"
    return "$EXIT_UNSUPPORTED"
  fi

  hdr "Required"

  # bash — we are already running under it, so this can only fail on an
  # ancient system, but reporting it beats a confusing syntax error later.
  v=$(ver_bash)
  if version_ge "$v" "$MIN_BASH"; then
    row ok "bash" "$v"
  else
    row miss "bash" "$v (need >= $MIN_BASH)" "$(install_hint bash)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  # ssh — the version gate is real: `Include` in ssh_config landed in 7.3,
  # and cx's host management depends on it.
  if have ssh; then
    v=$(ver_ssh)
    if [ -z "$v" ]; then
      row ok "ssh" "present (version unreadable)"
    elif version_ge "$v" "$MIN_SSH"; then
      row ok "ssh" "$v"
    else
      row miss "ssh" "$v (need >= $MIN_SSH for Include)" "$(install_hint openssh-client)"
      MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    fi
  else
    row miss "ssh" "not found" "$(install_hint openssh-client)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  if have scp; then
    row ok "scp" "present"
  else
    row miss "scp" "not found" "$(install_hint openssh-client)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  # jq — the only dependency most users will not already have.
  if have jq; then
    row ok "jq" "$(ver_jq)"
  else
    row miss "jq" "not found" "$(install_hint jq)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  if have git; then
    row ok "git" "$(ver_git)"
  else
    row miss "git" "not found" "$(install_hint git)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  # POSIX text tools. Absent only on unusually stripped systems, but a clear
  # message here beats a mysterious failure inside a pipeline.
  local missing_posix=""
  for t in awk sed grep find; do
    have "$t" || missing_posix="$missing_posix $t"
  done
  if [ -z "$missing_posix" ]; then
    row ok "awk/sed/grep" "present"
  else
    row miss "posix tools" "missing:$missing_posix" "$(install_hint coreutils)"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
  fi

  hdr "Optional"

  if have code; then
    row ok "code" "present" ""
  else
    row opt "code" "not found" "cx code will be unavailable — https://code.visualstudio.com"
    MISSING_OPTIONAL=$((MISSING_OPTIONAL + 1))
  fi

  if have tmux; then
    row ok "tmux" "present (local; only servers need it)"
  else
    row opt "tmux" "not found" "not needed on this machine — cx provision installs it on servers"
  fi

  # Report the state of things install.sh will touch, so --check genuinely
  # previews the install rather than only listing dependencies.
  hdr "Install targets"
  local prefix="${CX_PREFIX:-$HOME/.local}"
  row info "tree" "$HOME/.local/share/cx$([ -d "$HOME/.local/share/cx" ] && echo ' (exists, will update)')"
  row info "shim" "$prefix/bin/cx$([ -e "$prefix/bin/cx" ] && echo ' (exists, will replace)')"
  row info "config" "$HOME/.config/cx/config$([ -e "$HOME/.config/cx/config" ] && echo ' (exists, will keep)')"

  if [ -e "$HOME/.ssh/config" ]; then
    if grep -q 'cx/ssh.d' "$HOME/.ssh/config" 2>/dev/null; then
      row info "ssh Include" "already present"
    else
      row info "ssh Include" "will be added (backup taken first)"
    fi
  else
    # shellcheck disable=SC2088  # display text for the user, not a path to expand
    row info "ssh Include" "~/.ssh/config will be created (mode 600)"
  fi

  case ":$PATH:" in
    *":$prefix/bin:"*) row info "PATH" "$prefix/bin already on PATH" ;;
    *) row info "PATH" "$prefix/bin NOT on PATH — shell setup needed" ;;
  esac

  hdr "Result"
  if [ "$MISSING_REQUIRED" -gt 0 ]; then
    err "$MISSING_REQUIRED required dependency(ies) missing."
    say "  Install the items marked ✗ above, then re-run."
    return "$EXIT_MISSING_REQUIRED"
  fi
  if [ "$MISSING_OPTIONAL" -gt 0 ]; then
    printf '%s✓%s Ready to install. %d optional feature(s) unavailable.\n' \
      "$C_GREEN" "$C_RESET" "$MISSING_OPTIONAL"
    return "$EXIT_MISSING_OPTIONAL"
  fi
  printf '%s✓%s All requirements satisfied.\n' "$C_GREEN" "$C_RESET"
  return "$EXIT_OK"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

CX_SHARE="$HOME/.local/share/cx"
CX_CONFIG_DIR="$HOME/.config/cx"
CX_SSHD_DIR="$CX_CONFIG_DIR/ssh.d"

# script_dir — where this installer lives, if it was run from a checkout.
# Empty when piped from curl, which is how we tell the two modes apart.
script_dir() {
  local d
  case "$0" in
    bash | sh | -bash | -sh | /dev/fd/*) return 1 ;; # piped from curl
  esac
  d=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || return 1
  [ -f "$d/bin/cx" ] || return 1
  printf '%s' "$d"
}

confirm() {
  local prompt="$1"
  [ "$ASSUME_YES" = 1 ] && return 0
  # No TTY (curl | bash without -y) means we cannot ask; decline rather than
  # silently modifying a file the user never saw a prompt for.
  [ -t 0 ] || {
    note "  (no terminal for prompts — skipping; re-run with --yes to accept)"
    return 1
  }
  printf '%s [y/N] ' "$prompt"
  local reply=""
  read -r reply || return 1
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

install_tree() {
  local src
  hdr "Installing"

  if src=$(script_dir); then
    if [ "$src" = "$CX_SHARE" ]; then
      row ok "source" "already installed in place"
    else
      mkdir -p "$CX_SHARE"
      # Copy contents rather than the directory itself, and exclude VCS and
      # test scaffolding — users get a runtime, not a working copy.
      # Built as a list rather than an unquoted command substitution: relying
      # on word splitting to drop an absent optional path is fragile and
      # breaks on any path containing whitespace.
      local paths="bin lib server completions config.example"
      [ -d "$src/docs" ] && paths="$paths docs"
      # shellcheck disable=SC2086
      (cd "$src" && tar -cf - $paths) | (cd "$CX_SHARE" && tar -xf -)
      row ok "source" "copied from $src"
    fi
  else
    if ! have git; then
      err "git is required to install from a remote source"
      return 1
    fi
    if [ -d "$CX_SHARE/.git" ]; then
      (cd "$CX_SHARE" && git fetch --quiet origin "$CX_REPO_BRANCH" &&
        git reset --hard --quiet "origin/$CX_REPO_BRANCH") || {
        err "failed to update $CX_SHARE"
        return 1
      }
      row ok "source" "updated from $CX_REPO_URL"
    else
      rm -rf "$CX_SHARE"
      git clone --quiet --depth 1 --branch "$CX_REPO_BRANCH" \
        "$CX_REPO_URL" "$CX_SHARE" || {
        err "failed to clone $CX_REPO_URL"
        return 1
      }
      row ok "source" "cloned from $CX_REPO_URL"
    fi
  fi

  chmod 755 "$CX_SHARE/bin/cx" "$CX_SHARE/server/cx-agent" 2>/dev/null || true
  return 0
}

install_shim() {
  local bindir="$CX_PREFIX/bin"
  mkdir -p "$bindir"
  # A shim rather than a symlink: it pins CX_HOME so bin/cx can find lib/
  # regardless of how it was invoked or where PATH points.
  cat >"$bindir/cx" <<EOF
#!/usr/bin/env bash
# Generated by the cx installer. Safe to delete; re-run install.sh to restore.
CX_HOME="$CX_SHARE"
export CX_HOME
exec "\$CX_HOME/bin/cx" "\$@"
EOF
  chmod 755 "$bindir/cx"
  row ok "shim" "$bindir/cx"
}

install_config() {
  mkdir -p "$CX_CONFIG_DIR" "$CX_SSHD_DIR"
  chmod 700 "$CX_SSHD_DIR"
  if [ -e "$CX_CONFIG_DIR/config" ]; then
    row ok "config" "$CX_CONFIG_DIR/config (kept — not overwritten)"
  elif [ -f "$CX_SHARE/config.example" ]; then
    cp "$CX_SHARE/config.example" "$CX_CONFIG_DIR/config"
    row ok "config" "$CX_CONFIG_DIR/config (created from template)"
  else
    : >"$CX_CONFIG_DIR/config"
    row ok "config" "$CX_CONFIG_DIR/config (created empty)"
  fi
}

# The single edit cx makes to a user-owned file. Backed up, idempotent, and
# shown before it happens. Connection tuning is NOT written here — the client
# passes those as -o flags, so cx never changes how your other SSH sessions
# behave.
install_ssh_include() {
  local cfg="$HOME/.ssh/config" line="Include ~/.config/cx/ssh.d/*.conf" backup

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true

  if [ -e "$cfg" ] && grep -q 'cx/ssh.d' "$cfg" 2>/dev/null; then
    row ok "ssh config" "Include already present"
    return 0
  fi

  if [ ! -e "$cfg" ]; then
    printf '%s\n\n' "$line" >"$cfg"
    chmod 600 "$cfg"
    row ok "ssh config" "created $cfg with Include (mode 600)"
    return 0
  fi

  say ""
  note "  cx needs one line at the top of $cfg:"
  printf '      %s%s%s\n' "$C_BOLD" "$line" "$C_RESET"
  note "  It must come first: ssh uses first-match-wins for host options."
  note "  A timestamped backup will be written alongside it."
  say ""

  if ! confirm "  Add it?"; then
    row opt "ssh config" "skipped — add the line above by hand to use cx host"
    return 0
  fi

  backup="$cfg.cx-backup-$(date +%Y%m%d%H%M%S)"
  cp -p "$cfg" "$backup" || {
    err "could not back up $cfg — aborting this step"
    return 1
  }

  # Prepend via a temp file: no sed -i, and the original survives a failure.
  local tmp="$cfg.cx-new.$$"
  {
    printf '%s\n\n' "$line"
    cat "$cfg"
  } >"$tmp" && mv -f "$tmp" "$cfg" || {
    rm -f "$tmp"
    err "could not write $cfg (backup at $backup)"
    return 1
  }
  chmod 600 "$cfg"
  row ok "ssh config" "Include added (backup: $backup)"
}

# rc_file — the shell rc file to advise editing, per shell and platform.
rc_file() {
  case "$(basename "${SHELL:-sh}")" in
    zsh) printf '%s/.zshrc' "$HOME" ;;
    fish) printf '%s/.config/fish/config.fish' "$HOME" ;;
    bash)
      # macOS Terminal starts login shells, which read .bash_profile, not
      # .bashrc — a classic source of "it works on Linux" install bugs.
      if [ "$(detect_os)" = macos ] && [ -e "$HOME/.bash_profile" ]; then
        printf '%s/.bash_profile' "$HOME"
      else
        printf '%s/.bashrc' "$HOME"
      fi
      ;;
    *) printf '%s/.profile' "$HOME" ;;
  esac
}

shell_lines() {
  local shell_name comp
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    fish) comp="$CX_SHARE/completions/cx.fish" ;;
    zsh) comp="$CX_SHARE/completions/cx.zsh" ;;
    *) comp="$CX_SHARE/completions/cx.bash" ;;
  esac

  if [ "$shell_name" = fish ]; then
    printf '# added by cx\n'
    printf 'set -gx PATH %s/bin $PATH\n' "$CX_PREFIX"
    printf 'test -f %s; and source %s\n' "$comp" "$comp"
  else
    printf '# added by cx\n'
    printf 'export PATH="%s/bin:$PATH"\n' "$CX_PREFIX"
    printf '[ -f "%s" ] && . "%s"\n' "$comp" "$comp"
  fi
}

setup_shell() {
  local rc lines
  rc=$(rc_file)
  lines=$(shell_lines)

  if [ -e "$rc" ] && grep -q '# added by cx' "$rc" 2>/dev/null; then
    row ok "shell" "$rc already configured"
    return 0
  fi

  if [ "$SHELL_SETUP" != 1 ]; then
    hdr "Shell setup"
    note "  Add these lines to $rc:"
    say ""
    printf '%s\n' "$lines" | sed 's/^/      /'
    say ""
    note "  Or re-run with --shell-setup to have the installer append them."
    return 0
  fi

  hdr "Shell setup"
  note "  Appending to $rc:"
  say ""
  printf '%s\n' "$lines" | sed 's/^/      + /'
  say ""
  if ! confirm "  Append these lines?"; then
    row opt "shell" "skipped"
    return 0
  fi
  {
    printf '\n'
    printf '%s\n' "$lines"
  } >>"$rc"
  row ok "shell" "appended to $rc"
}

do_install() {
  install_tree || return 1
  install_shim
  install_config
  install_ssh_include || true
  setup_shell

  hdr "Next steps"
  case ":$PATH:" in
    *":$CX_PREFIX/bin:"*) ;;
    *)
      note "  1. Restart your shell (or source $(rc_file)) so cx is on PATH"
      ;;
  esac
  cat <<EOF
  $(printf '%s' "$C_BOLD")cx host add$(printf '%s' "$C_RESET")            add your first server
  $(printf '%s' "$C_BOLD")cx provision <host>$(printf '%s' "$C_RESET")    install the agent on it
  $(printf '%s' "$C_BOLD")cx login <host>$(printf '%s' "$C_RESET")        one-time Claude Code sign-in
  $(printf '%s' "$C_BOLD")cx new <host>:<name>$(printf '%s' "$C_RESET")   create a project
  $(printf '%s' "$C_BOLD")cx ls$(printf '%s' "$C_RESET")                  see everything

  Docs: $CX_SHARE/docs/
EOF
  return 0
}

do_uninstall() {
  hdr "Uninstalling"

  if [ -d "$CX_SHARE" ]; then
    rm -rf "$CX_SHARE"
    row ok "tree" "removed $CX_SHARE"
  else
    row info "tree" "not present"
  fi

  if [ -e "$CX_PREFIX/bin/cx" ]; then
    rm -f "$CX_PREFIX/bin/cx"
    row ok "shim" "removed $CX_PREFIX/bin/cx"
  else
    row info "shim" "not present"
  fi

  local cfg="$HOME/.ssh/config"
  if [ -e "$cfg" ] && grep -q 'cx/ssh.d' "$cfg" 2>/dev/null; then
    local backup tmp
    backup="$cfg.cx-backup-$(date +%Y%m%d%H%M%S)"
    cp -p "$cfg" "$backup"
    tmp="$cfg.cx-new.$$"
    grep -v 'cx/ssh.d' "$cfg" >"$tmp" && mv -f "$tmp" "$cfg"
    chmod 600 "$cfg"
    row ok "ssh config" "Include removed (backup: $backup)"
  else
    row info "ssh config" "no Include to remove"
  fi

  hdr "Kept"
  # Deliberate: uninstalling the client must never destroy the user's server
  # definitions or anything on the servers themselves.
  note "  $CX_CONFIG_DIR      your config and host definitions"
  note "  $HOME/.cache/cx     disposable cache"
  note "  your servers        untouched — remove agents with: rm ~/.local/bin/cx-agent"
  say ""
  note "  Remove your shell rc lines by hand (search for '# added by cx')."
  return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
cx installer

USAGE
  ./install.sh [OPTIONS]

OPTIONS
  --check          Report requirements and what would change. Writes nothing.
  --yes            Non-interactive; accept all prompts. For CI and dotfiles.
  --prefix DIR     Install the shim to DIR/bin (default: ~/.local).
  --shell-setup    Write PATH and completion lines to your shell rc file
                   after showing a diff. Without it, the lines are printed.
  --uninstall      Remove the tree, shim, and SSH Include. Keeps your config,
                   cache, and servers untouched.
  -h, --help       This message.

EXIT CODES
  0  ready / installed
  1  a required dependency is missing
  2  installed, but an optional dependency is missing
  3  unsupported platform

ENVIRONMENT
  CX_PREFIX        Same as --prefix.
  CX_REPO_URL      Source repository (default: the upstream project).
  NO_COLOR         Disable colored output.
EOF
}

ASSUME_YES=0
SHELL_SETUP=0

main() {
  local mode=install

  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode=check ;;
      --uninstall) mode=uninstall ;;
      --yes | -y) ASSUME_YES=1 ;;
      --shell-setup) SHELL_SETUP=1 ;;
      --prefix)
        shift
        CX_PREFIX="${1:-}"
        ;;
      --prefix=*) CX_PREFIX="${1#--prefix=}" ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        err "unknown option: $1"
        say ""
        usage
        exit 64
        ;;
    esac
    shift
  done

  export CX_PREFIX="${CX_PREFIX:-$HOME/.local}"

  printf '%scx installer%s\n' "$C_BOLD" "$C_RESET"

  case "$mode" in
    check)
      check_requirements
      exit $?
      ;;
    uninstall)
      do_uninstall
      exit $?
      ;;
    install)
      check_requirements
      local rc=$?
      # A missing optional dependency (exit 2) is not a reason to refuse —
      # it only means one feature will be unavailable.
      if [ "$rc" = "$EXIT_MISSING_REQUIRED" ] || [ "$rc" = "$EXIT_UNSUPPORTED" ]; then
        exit "$rc"
      fi
      do_install || exit 1
      exit "$rc"
      ;;
  esac
}

# Tests source this file to exercise version_ge, install_hint, and friends
# without triggering an install.
if [ "${CX_INSTALL_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi

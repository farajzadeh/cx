#!/usr/bin/env bash
# lib/config.sh — configuration loading.
#
# Precedence, highest first:
#   1. environment variables
#   2. ~/.config/cx/config
#   3. the defaults below
#
# Environment beating the file matters for one-off overrides
# (CX_CACHE_TTL=0 cx ls) and for CI.

[ -n "${_CX_CONFIG_LOADED:-}" ] && return 0
_CX_CONFIG_LOADED=1

CX_CONFIG_DIR="${CX_CONFIG_DIR:-$HOME/.config/cx}"
CX_CONFIG_FILE="${CX_CONFIG_FILE:-$CX_CONFIG_DIR/config}"
CX_SSHD_DIR="${CX_SSHD_DIR:-$CX_CONFIG_DIR/ssh.d}"
CX_CACHE_DIR="${CX_CACHE_DIR:-$HOME/.cache/cx}"

# Capture which settings came from the environment before sourcing the file,
# so the file cannot clobber an explicit override.
_cx_env_snapshot() {
  _CX_ENV_KEYS=""
  for k in CX_DEFAULT_HOST CX_PROJECT_ROOT CX_CACHE_TTL CX_UNREACHABLE_TTL \
    CX_STALE_OK CX_CONNECT_TIMEOUT CX_CONTROL_PERSIST CX_EDITOR CX_NO_COLOR; do
    eval "_v=\${$k+set}"
    if [ "${_v:-}" = set ]; then
      _CX_ENV_KEYS="$_CX_ENV_KEYS $k"
      eval "_CX_ENV_$k=\$$k"
    fi
  done
  unset _v
}

cx_config_load() {
  _cx_env_snapshot

  if [ -r "$CX_CONFIG_FILE" ]; then
    # The config is documented as simple KEY=value assignments. Sourcing it
    # gives users comments and shell expansion; it is their own file, at the
    # same trust level as their shell rc.
    # shellcheck disable=SC1090
    . "$CX_CONFIG_FILE" || {
      printf 'cx: error reading %s\n' "$CX_CONFIG_FILE" >&2
      return 1
    }
  fi

  # Environment wins over the file.
  for k in $_CX_ENV_KEYS; do
    eval "$k=\$_CX_ENV_$k"
  done

  # Defaults for anything still unset.
  : "${CX_DEFAULT_HOST:=}"
  : "${CX_PROJECT_ROOT:=projects}"
  : "${CX_CACHE_TTL:=30}"
  : "${CX_UNREACHABLE_TTL:=60}"
  : "${CX_STALE_OK:=0}"
  : "${CX_CONNECT_TIMEOUT:=5}"
  : "${CX_CONTROL_PERSIST:=10m}"
  : "${CX_EDITOR:=}"
  : "${CX_NO_COLOR:=0}"

  # Guard against a malformed config turning into confusing arithmetic errors
  # deep inside the cache layer.
  _cx_require_int CX_CACHE_TTL "$CX_CACHE_TTL"
  _cx_require_int CX_UNREACHABLE_TTL "$CX_UNREACHABLE_TTL"
  _cx_require_int CX_CONNECT_TIMEOUT "$CX_CONNECT_TIMEOUT"

  # Exported so a backgrounded cache refresh (a fresh `cx` process) resolves
  # the same configuration, config file, hosts, and cache directory.
  export CX_DEFAULT_HOST CX_PROJECT_ROOT CX_CACHE_TTL CX_UNREACHABLE_TTL \
    CX_STALE_OK CX_CONNECT_TIMEOUT CX_CONTROL_PERSIST CX_EDITOR CX_NO_COLOR
  export CX_CONFIG_DIR CX_CONFIG_FILE CX_SSHD_DIR CX_CACHE_DIR
}

_cx_require_int() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'cx: %s must be a non-negative integer (got: %s)\n' "$1" "$2" >&2
      printf '    check %s\n' "$CX_CONFIG_FILE" >&2
      exit 78 # EX_CONFIG
      ;;
  esac
}

# cx_editor — the editor for `cx host edit`.
cx_editor() {
  if [ -n "${CX_EDITOR:-}" ]; then
    printf '%s' "$CX_EDITOR"
  elif [ -n "${VISUAL:-}" ]; then
    printf '%s' "$VISUAL"
  elif [ -n "${EDITOR:-}" ]; then
    printf '%s' "$EDITOR"
  else
    printf 'vi'
  fi
}

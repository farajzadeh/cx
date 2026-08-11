#!/usr/bin/env bash
# lib/cmd/new.sh — `cx new` — create and register a project on a server.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_new() {
  local target="" repo="" root=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        ;;
      --root)
        shift
        root="${1:-}"
        ;;
      -h | --help)
        cat <<EOF
${C_BOLD}cx new${C_RESET} — create a project on a server

  cx new <host>:<name>                  create an empty git repository
  cx new <host>:<name> --repo <url>     clone an existing repository
  cx new <name>                         use CX_DEFAULT_HOST

OPTIONS
  --repo URL    clone this repository instead of running git init
  --root DIR    project root on the server (default: the host's configured root)

The project is created on the server and recorded in that server's registry.
Nothing is downloaded to this machine.
EOF
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx new <host>:<name> [--repo URL]"
    return 3
  }

  # Split rather than resolve: the project must NOT exist yet, so a lookup
  # across hosts would be meaningless here.
  cx_target_split "$target" || {
    err "invalid target: $target"
    return 3
  }

  if [ -z "$CX_T_HOST" ]; then
    err "no host given and CX_DEFAULT_HOST is not set"
    hint "use: cx new <host>:$CX_T_PROJECT"
    hint "or set CX_DEFAULT_HOST in $CX_CONFIG_FILE"
    return 3
  fi

  cx_host_exists "$CX_T_HOST" || {
    err "unknown host: $CX_T_HOST"
    hint "configured hosts: $(cx_hosts_list | tr '\n' ' ')"
    return 2
  }

  local out rc=0
  # stdout only. The agent's contract is JSON on stdout, human text on stderr;
  # merging them with 2>&1 corrupts the payload the moment the agent logs
  # anything (a clone progress line, a warning).
  #
  # Arguments go through cx_agent, which quotes each one for the remote shell,
  # so a --repo URL containing shell metacharacters is safe.
  if [ -n "$repo" ] && [ -n "$root" ]; then
    out=$(cx_agent "$CX_T_HOST" new "$CX_T_PROJECT" --repo "$repo" --root "$root") || rc=$?
  elif [ -n "$repo" ]; then
    out=$(cx_agent "$CX_T_HOST" new "$CX_T_PROJECT" --repo "$repo") || rc=$?
  elif [ -n "$root" ]; then
    out=$(cx_agent "$CX_T_HOST" new "$CX_T_PROJECT" --root "$root") || rc=$?
  else
    out=$(cx_agent "$CX_T_HOST" new "$CX_T_PROJECT") || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    # The agent already wrote its diagnosis to stderr, which reached the
    # terminal directly. Only add the suggested next step.
    case "$rc" in
      4) hint "pick a different name, or open the existing one: cx open $(cx_target_str)" ;;
      255) hint "could not reach $CX_T_HOST — check with: cx host test $CX_T_HOST" ;;
      *) hint "check the server with: cx host test $CX_T_HOST" ;;
    esac
    return "$rc"
  fi

  # Success invalidates this host's cached listing, so the very next `cx ls`
  # shows the new project without needing -r.
  cx_cache_invalidate "$CX_T_HOST" 2>/dev/null || true

  # `|| true` on every extraction: under `set -e` a failed command
  # substitution in an assignment aborts the function silently, which is
  # exactly how this went wrong before.
  local path=""
  path=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null) || true

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}' || printf '%s\n' "$out"
    return 0
  fi

  say "  $(ok_mark) created $(cx_target_str)"
  [ -n "$path" ] && note "    $path"
  say ""
  hint "start working: cx open $(cx_target_str)"
}

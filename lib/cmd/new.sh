#!/usr/bin/env bash
# lib/cmd/new.sh — `cx new` — create and register a project on a server.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"
# shellcheck source=../create.sh
. "$CX_HOME/lib/create.sh"

_new_usage() {
  cat <<EOF
${C_BOLD}cx new${C_RESET} — create a project on a server

  cx new <host>:<name>                  create an empty git repository
  cx new <host>:<name> --repo <url>     clone an existing repository
  cx new <name>                         use CX_DEFAULT_HOST
  cx new <host>:<name> --open           create it, then attach a session
  cx new <host>:<name> -d               create it, then start one detached
  cx new                                at a terminal: asks for each part

OPTIONS
  --repo URL    clone this repository instead of running git init
  --root DIR    project root on the server (default: the host's configured root)
  --open        attach a Claude session once it exists, exactly as cx open does
  --no-open     do not open one, and do not ask
  -d, --detach  start that session without attaching
  --label L     open the session as <host>:<name>@L
  --dangerously-skip-permissions, --permission-mode M, --model M,
  --effort E, --no-hooks
                for the session, as cx open takes them

Every option describing the session implies --open.

The project is created on the server and recorded in that server's registry.
Nothing is downloaded to this machine.

Without --open or --no-open, CX_OPEN_AFTER_CREATE decides: ${C_BOLD}ask${C_RESET} (the
default) asks at a terminal, ${C_BOLD}always${C_RESET} opens whenever there is a terminal to
attach, ${C_BOLD}never${C_RESET} does not. A script, --json and -y are never asked, and
never get a session they did not ask for.

With no target at a terminal, cx new asks which server (when there is more
than one), the project's name, and a repository to clone (empty for git init).
Without a terminal, a missing target is a usage error, exit 3.
EOF
}

# _new_interactive — ask for what the command line left out. Sets the
# caller's `target`, and `repo` unless --repo was given.
_new_interactive() {
  local hosts n host
  hosts=$(cx_hosts_list)
  n=$(printf '%s' "$hosts" | grep -c . || true)
  case "$n" in
    0)
      err "no servers configured"
      hint "add one with: cx host add"
      return 2
      ;;
    # Nothing to choose between, so no question.
    1) host="$hosts" ;;
    *) host=$(cx_pick_host "server") || return $? ;;
  esac

  cx_ask_valid "project name on $host" cx_project_name_ok || return $?
  target="$host:$CX_ASK_REPLY"

  if [ "$repo_given" = 0 ]; then
    cx_ask_line "repository to clone (empty for a new git repository)" || return $?
    repo="$CX_ASK_REPLY"
  fi
  return 0
}

cmd_new() {
  local target="" repo="" root="" repo_given=0

  cx_create_opts_reset
  while [ $# -gt 0 ]; do
    # Checked first, as cx open checks its Claude options first, so that the
    # value of --label or --model is never mistaken for the target.
    local rc=0
    cx_create_opt "$1" "${2:-}" || rc=$?
    if [ "$rc" = 0 ]; then
      shift "$CX_CREATE_USED"
      continue
    fi
    [ "$rc" = 2 ] && return 3 # already said what was wrong

    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        repo_given=1
        ;;
      --root)
        shift
        root="${1:-}"
        ;;
      -h | --help)
        _new_usage
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

  # Before anything exists: a contradiction found after creating would leave
  # a project behind for a command that failed.
  cx_create_check || return $?

  if [ -z "$target" ]; then
    # Asking is for a human at a terminal; everything else keeps exit 3.
    cx_pick_ok || {
      err "no target given"
      hint "usage: cx new <host>:<name> [--repo URL]"
      return 3
    }
    _new_interactive || return $?
  fi

  # Split rather than resolve: the project must NOT exist yet, so a lookup
  # across hosts would be meaningless here.
  cx_target_split "$target" || {
    [ -n "$CX_T_PROJECT" ] || err "invalid target: $target"
    return 3
  }

  # `/` and `@` are target syntax, not name characters. Without this the
  # components are parsed off and then silently dropped — `cx new web1:a/b`
  # would create a project called "a" and say nothing about the "b".
  if [ -n "$CX_T_WORKTREE" ] || [ -n "$CX_T_SESSION" ]; then
    err "a project name cannot contain '/' or '@': $target"
    if [ -n "$CX_T_WORKTREE" ]; then
      hint "to add a worktree to an existing project: cx wt add $target"
    fi
    if [ -n "$CX_T_SESSION" ]; then
      hint "to open a session with that label once it exists: --label $CX_T_SESSION"
    fi
    hint "to create a project: cx new $CX_T_HOST:$CX_T_PROJECT"
    return 3
  fi

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
  # shows the new project without needing -r. Before opening, too: an
  # attached open never comes back to do it.
  cx_cache_invalidate "$CX_T_HOST" 2>/dev/null || true

  # `|| true` on every extraction: under `set -e` a failed command
  # substitution in an assignment aborts the function silently, which is
  # exactly how this went wrong before.
  local path="" created
  path=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null) || true
  # Kept aside: cmd_open resolves its own target into the same CX_T_* globals.
  created=$(cx_target_str)

  if [ "${CX_JSON:-0}" = 1 ]; then
    local j=""
    j=$(printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}' 2>/dev/null) || true
    [ -n "$j" ] && out="$j"
    if cx_create_want_open; then
      cx_create_open_json "$out" "$created"
      return $?
    fi
    printf '%s\n' "$out"
    return 0
  fi

  say "  $(ok_mark) created $created"
  [ -n "$path" ] && note "    $path"
  say ""

  if cx_create_want_open; then
    rc=0
    cx_create_open "$created" || rc=$?
    [ "$rc" = 0 ] || hint "the project exists; open it later with: cx open $created"
    return "$rc"
  fi
  hint "start working: cx open $created"
}

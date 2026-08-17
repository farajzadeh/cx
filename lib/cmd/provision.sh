#!/usr/bin/env bash
# lib/cmd/provision.sh — `cx provision` — install or update the server agent.
#
# Two steps: upload cx-agent to a temp path, then run bootstrap.sh over ssh.
# bootstrap.sh moves the agent into place. Splitting it this way means the
# agent is transferred as a file rather than embedded in a command string.
#
# Idempotent, and re-running is the upgrade path.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

_provision_one() {
  local alias="$1" root probe summary rc

  hdr "$alias"

  cx_host_exists "$alias" || {
    err "unknown host: $alias"
    hint "add it with: cx host add"
    return 2
  }

  printf '  connecting... '
  if ! probe=$(cx_probe "$alias"); then
    say "$(bad_mark) $probe"
    say ""
    cx_probe_explain "$probe" "$alias" | sed 's/^/  /'
    return 1
  fi
  say "$(ok_mark)"

  local agent="$CX_HOME/server/cx-agent"
  local bootstrap="$CX_HOME/server/bootstrap.sh"
  [ -r "$agent" ] || {
    err "missing $agent — reinstall cx"
    return 1
  }
  [ -r "$bootstrap" ] || {
    err "missing $bootstrap — reinstall cx"
    return 1
  }

  printf '  uploading... '
  # Both files are uploaded rather than piping bootstrap over stdin. Piping
  # would occupy stdin, and `ssh -t` needs a local terminal on stdin to
  # allocate a remote TTY — without which sudo cannot prompt for a password.
  if ! cx_scp "$agent" "$alias" '/tmp/cx-agent.incoming' ||
    ! cx_scp "$bootstrap" "$alias" '/tmp/cx-bootstrap.sh'; then
    say "$(bad_mark)"
    err "could not copy files to $alias"
    return 1
  fi
  say "$(ok_mark)"

  root=$(cx_host_root "$alias")

  say "  running bootstrap:"
  # `sh`, not bash: a minimal server may not have bash yet, and bootstrap is
  # what installs it.
  #
  # Only request a TTY when we have one to give. In a pipeline or CI there is
  # no terminal, and -t would fail; sudo is then only usable if it is already
  # passwordless, which is the normal case for automation.
  local opts tflag=""
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  [ -t 0 ] && tflag="-t"

  # stderr is deliberately left unredirected: inside $(...) only stdout is
  # captured, so bootstrap's progress reaches the user's terminal live while
  # its final JSON line is collected here.
  #
  # The exception is an interactive run: with a TTY (-t), ssh runs the remote
  # under a pseudo-terminal that MERGES its stderr into stdout, so bootstrap's
  # error messages are captured into $summary rather than shown live. That is
  # exactly the case where a human is watching and most wants to see what went
  # wrong — so on failure the captured output is printed below, not discarded.
  rc=0
  # shellcheck disable=SC2086
  summary=$(ssh $tflag $opts "$alias" \
    "sh /tmp/cx-bootstrap.sh --root $(cx_remote_quote "$root"); rm -f /tmp/cx-bootstrap.sh") || rc=$?

  if [ "${rc:-0}" -ne 0 ]; then
    say ""
    err "bootstrap failed on $alias"
    # Surface what bootstrap actually said. Under a TTY this holds the full
    # transcript including the failing line; without one it may be empty
    # because the error already streamed live — so print only when there is
    # something, and mark it as the remote's own words.
    if [ -n "$summary" ]; then
      printf '%s\n' "$summary" | tr -d '\r' | sed 's/^/  bootstrap| /' >&2
    fi
    hint "re-run is safe (bootstrap is idempotent): cx provision $alias"
    return 1
  fi

  # bootstrap prints a JSON summary as its final stdout line.
  summary=$(printf '%s' "$summary" | tr -d '\r' | grep '^{' | tail -1)
  if [ -z "$summary" ]; then
    warn "bootstrap finished but produced no summary — verify with: cx host test $alias"
    return 0
  fi

  # A new agent version invalidates anything cached from the old one, and a
  # successful provision proves the host is reachable.
  cx_cache_invalidate "$alias"

  say ""
  printf '%s' "$summary" | jq -r '
    "  agent:   " + .agent_version,
    "  root:    " + .project_root,
    "  claude:  " + (if .claude_installed then
        (if .claude_logged_in then "installed, signed in" else "installed, NOT SIGNED IN" end)
      else "NOT INSTALLED" end)'

  if ! printf '%s' "$summary" | jq -e '.claude_logged_in' >/dev/null 2>&1; then
    say ""
    hint "one-time sign-in required: cx login $alias"
  fi
  return 0
}

cmd_provision() {
  local targets="" all=0 rc=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --all | -a) all=1 ;;
      -h | --help)
        cat <<EOF
${C_BOLD}cx provision${C_RESET} — install or update the agent on a server

  cx provision <host>     provision one server
  cx provision --all      provision every configured server

Safe to re-run: this is also how you upgrade servers after updating cx.
Nothing is installed on a server that already has everything it needs.
EOF
        return 0
        ;;
      *) targets="$targets $1" ;;
    esac
    shift
  done

  if [ "$all" = 1 ]; then
    targets=$(cx_hosts_list | tr '\n' ' ')
  fi

  targets="${targets# }"
  if [ -z "$targets" ]; then
    err "no host given"
    hint "usage: cx provision <host>   |   cx provision --all"
    return 3
  fi

  local h
  for h in $targets; do
    _provision_one "$h" || rc=1
  done
  return "$rc"
}

#!/usr/bin/env bash
# lib/cmd/doctor.sh — `cx doctor` — check this machine and every server.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

_doctor_local() {
  local rc=0 v
  hdr "This machine"

  v="${BASH_VERSION%%(*}"
  if cx_version_ge "$v" 3.2; then
    say "  $(ok_mark) bash $v"
  else
    say "  $(bad_mark) bash $v (need >= 3.2)"
    rc=1
  fi

  for t in ssh scp jq git; do
    if cx_have "$t"; then
      say "  $(ok_mark) $t"
    else
      say "  $(bad_mark) $t not found"
      rc=1
    fi
  done

  if cx_have code; then
    say "  $(ok_mark) code (VS Code integration available)"
  else
    say "  $(dash_mark) code not found — cx code unavailable"
  fi

  # The Include line is what makes cx-managed hosts visible to ssh at all.
  if grep -q 'cx/ssh.d' "${CX_SSH_CONFIG:-$HOME/.ssh/config}" 2>/dev/null; then
    say "  $(ok_mark) ssh Include configured"
  else
    say "  $(bad_mark) ssh Include missing from ~/.ssh/config"
    hint "re-run install.sh, or add: Include ~/.config/cx/ssh.d/*.conf"
    rc=1
  fi

  return "$rc"
}

_doctor_host() {
  local alias="$1" probe doctor rc=0

  printf '  %-14s ' "$alias"

  if ! probe=$(cx_probe "$alias"); then
    say "$(bad_mark) $probe"
    cx_probe_explain "$probe" "$alias" | sed 's/^/      /' >&2
    return 1
  fi

  if ! doctor=$(cx_agent "$alias" doctor 2>/dev/null); then
    say "$(bad_mark) agent not installed"
    hint "cx provision $alias"
    return 1
  fi

  local agentv claude_ok logged_in
  agentv=$(printf '%s' "$doctor" | jq -r '.agent_version')
  claude_ok=$(printf '%s' "$doctor" | jq -r '.claude.installed')
  logged_in=$(printf '%s' "$doctor" | jq -r '.claude.logged_in')

  if [ "$claude_ok" != true ]; then
    say "$(bad_mark) agent $agentv, Claude Code not installed"
    hint "cx provision $alias"
    return 1
  fi
  if [ "$logged_in" != true ]; then
    say "$(dash_mark) agent $agentv, not signed in"
    hint "cx login $alias"
    return 1
  fi

  # A client newer than a server means the agent is missing fixes the client
  # may already depend on.
  if [ "$agentv" != "$CX_VERSION" ]; then
    say "$(dash_mark) agent $agentv (client is $CX_VERSION)"
    hint "cx provision $alias   # update the agent"
    return 0
  fi

  say "$(ok_mark) agent $agentv, signed in"
  return "$rc"
}

cmd_doctor() {
  local rc=0 hosts

  case "${1:-}" in
    -h | --help)
      cat <<USAGE
${C_BOLD}cx doctor${C_RESET} — check requirements and connectivity

  cx doctor           check this machine and every server
  cx doctor <host>    check one server
USAGE
      return 0
      ;;
  esac

  if [ -n "${1:-}" ]; then
    cx_host_exists "$1" || {
      err "unknown host: $1"
      return 2
    }
    hdr "Servers"
    _doctor_host "$1" || rc=1
    return "$rc"
  fi

  _doctor_local || rc=1

  hosts=$(cx_hosts_list)
  hdr "Servers"
  if [ -z "$hosts" ]; then
    note "  none configured — add one with: cx host add"
  else
    # Serial rather than parallel: doctor is a diagnostic, and interleaved
    # output from concurrent probes is harder to read than it is fast.
    printf '%s\n' "$hosts" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      _doctor_host "$h" || true
    done
  fi

  say ""
  if [ "$rc" -eq 0 ]; then
    say "$(ok_mark) client ready"
  else
    say "$(bad_mark) issues above need attention"
  fi
  return "$rc"
}

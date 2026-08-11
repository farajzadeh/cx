#!/usr/bin/env bash
# lib/remote.sh — SSH transport.
#
# THE INVARIANT THIS FILE EXISTS TO ENFORCE:
# cx never interpolates user data into a remote shell command. Arguments are
# quoted individually by cx_remote_quote before being handed to ssh, so a
# project named "my project", a prompt containing "$(rm -rf ~)", or a path
# with a quote in it all arrive at cx-agent as single intact argv entries.
#
# Connection tuning is passed as -o flags rather than written into
# ~/.ssh/config, so cx never changes how the user's other SSH sessions behave
# and the options apply identically to cx-managed and imported hosts.

[ -n "${_CX_REMOTE_LOADED:-}" ] && return 0
_CX_REMOTE_LOADED=1

CX_AGENT_PATH='$HOME/.local/bin/cx-agent'

# cx_ssh_opts — connection options, as an argv fragment for `eval set --`.
#
# ControlMaster/ControlPersist are what make repeated commands fast: the first
# connection pays the handshake, the rest reuse the socket for a few ms.
# ConnectTimeout bounds how long a dead host can stall a fan-out — without it
# ssh waits ~2 minutes and one powered-off server appears to hang everything.
# ControlPath uses %C (a hash) because %r@%h:%p overflows the ~104 byte Unix
# socket path limit on long hostnames.
cx_ssh_opts() {
  # -F only when explicitly overridden. OpenSSH resolves the default config
  # path from the passwd database rather than $HOME, so setting HOME is not
  # enough to redirect it — this is the supported way to point cx at a
  # different SSH config, and what makes the test suite hermetic.
  local fflag=""
  [ -n "${CX_SSH_CONFIG:-}" ] && fflag="-F $CX_SSH_CONFIG "

  printf '%s' \
    "$fflag-o ControlMaster=auto \
-o ControlPath=$HOME/.ssh/cm-%C \
-o ControlPersist=${CX_CONTROL_PERSIST:-10m} \
-o ConnectTimeout=${CX_CONNECT_TIMEOUT:-5} \
-o ServerAliveInterval=30 \
-o ServerAliveCountMax=6 \
-o BatchMode=${CX_SSH_BATCH:-yes}"
}

# cx_remote_quote ARG... — single-quote each argument for the remote shell.
#
# ssh concatenates its command arguments with spaces and hands the result to
# the remote login shell, which re-splits on whitespace. Anything not quoted
# here is re-interpreted on the far side. This is the single most
# security-relevant function in the client.
cx_remote_quote() {
  local out="" a
  for a in "$@"; do
    out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
  done
  printf '%s' "$out"
}

# cx_ssh HOST ARG... — run a command on HOST, no TTY.
# For queries whose stdout we parse. stdin is passed through so callers can
# pipe data (cx ask sends its prompt this way, avoiding quoting entirely).
cx_ssh() {
  local host="$1"
  shift
  local opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh $opts "$host" "$(cx_remote_quote "$@")"
}

# cx_ssh_tty HOST ARG... — run a command on HOST with a TTY allocated.
# For anything interactive: tmux attach, claude, sudo prompts during
# provisioning. BatchMode is disabled so password and passphrase prompts work.
cx_ssh_tty() {
  local host="$1"
  shift
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh -t $opts "$host" "$(cx_remote_quote "$@")"
}

# cx_ssh_raw HOST ARG... — ssh with our options but the caller's own argv.
# Used for connectivity probes where we want ssh's exit status, not output.
cx_ssh_raw() {
  local host="$1"
  shift
  local opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh $opts "$host" "$@"
}

# cx_scp LOCAL HOST REMOTE — copy a file to HOST.
cx_scp() {
  local src="$1" host="$2" dest="$3" opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  scp -q $opts "$src" "$host:$dest"
}

# cx_agent HOST ARG... — invoke cx-agent on HOST.
#
# Called by absolute path rather than relying on PATH: a non-interactive
# `ssh host cmd` does not read .bashrc, and ~/.profile is only read by login
# shells, so ~/.local/bin is frequently absent from PATH here. This is a
# common source of "works when I ssh in, fails from the tool" bugs.
cx_agent() {
  local host="$1"
  shift
  local opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh $opts "$host" "$CX_AGENT_PATH$(cx_remote_quote "$@")"
}

# cx_agent_tty HOST ARG... — same, with a TTY.
cx_agent_tty() {
  local host="$1"
  shift
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh -t $opts "$host" "$CX_AGENT_PATH$(cx_remote_quote "$@")"
}

# ---------------------------------------------------------------------------
# Reachability
# ---------------------------------------------------------------------------

# cx_probe HOST — classify a connection failure.
#
# Prints one of: ok | auth | refused | timeout | dns | unknown
# and returns 0 only for ok.
#
# The classification exists because "connection failed" is useless to a user
# setting up their first server: a missing key, a firewall, and a typo in the
# hostname need three completely different fixes.
cx_probe() {
  local host="$1" out rc opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  out=$(ssh $opts -o LogLevel=ERROR "$host" true 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'ok'
    return 0
  fi

  case "$out" in
    *"Permission denied"* | *"Too many authentication failures"* | *"no mutual signature"*)
      printf 'auth'
      ;;
    *"Connection refused"*)
      printf 'refused'
      ;;
    *"Connection timed out"* | *"Operation timed out"* | *"timed out"*)
      printf 'timeout'
      ;;
    *"Could not resolve"* | *"Name or service not known"* | *"nodename nor servname"*)
      printf 'dns'
      ;;
    *"Host key verification failed"*)
      printf 'hostkey'
      ;;
    *"No route to host"* | *"Network is unreachable"*)
      printf 'unreachable'
      ;;
    *)
      printf 'unknown'
      ;;
  esac
  return 1
}

# cx_probe_explain KIND HOST — actionable next step for a probe result.
cx_probe_explain() {
  case "$1" in
    auth)
      printf 'SSH reached %s but rejected the credentials.\n' "$2"
      printf '  Add your key:  ssh-copy-id %s\n' "$2"
      printf '  Or debug with: ssh -v %s\n' "$2"
      ;;
    refused)
      printf '%s answered but refused the connection.\n' "$2"
      printf '  Is sshd running, and is the port correct?\n'
      ;;
    timeout)
      printf 'No response from %s within %ss.\n' "$2" "${CX_CONNECT_TIMEOUT:-5}"
      printf '  Usually a firewall or a wrong address. Check with: ping %s\n' "$2"
      ;;
    dns)
      printf 'The hostname for %s could not be resolved.\n' "$2"
      printf '  Check the HostName in: cx host edit %s\n' "$2"
      ;;
    hostkey)
      printf "%s's host key does not match your known_hosts entry.\\n" "$2"
      printf '  If the server was rebuilt: ssh-keygen -R <hostname>\n'
      printf '  If it was not, stop and investigate — this can be an interception.\n'
      ;;
    unreachable)
      printf 'No network route to %s.\n' "$2"
      printf '  Are you on the right network or VPN?\n'
      ;;
    *)
      printf 'Could not connect to %s.\n' "$2"
      printf '  Debug with: ssh -v %s\n' "$2"
      ;;
  esac
}

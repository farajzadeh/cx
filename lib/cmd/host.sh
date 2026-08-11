#!/usr/bin/env bash
# lib/cmd/host.sh — `cx host` — manage servers.
#
# This is the step where a new user either succeeds or gives up, so it
# diagnoses rather than merely failing: it distinguishes a missing key from a
# firewall from a typo, and offers to fix what it can.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

host_usage() {
  cat <<EOF
${C_BOLD}cx host${C_RESET} — manage servers

  cx host add [OPTIONS]        add a server (interactive when no options given)
  cx host import <ssh-alias>   adopt a host already in your ~/.ssh/config
  cx host ls                   list servers
  cx host test <alias>         check connectivity and agent status
  cx host edit <alias>         edit the definition in \$EDITOR
  cx host rm <alias>           remove (the server itself is untouched)

${C_BOLD}ADD OPTIONS${C_RESET}
  --alias NAME       short name you will type (required non-interactively)
  --hostname HOST    address or DNS name (required non-interactively)
  --user NAME        login user (default: $USER)
  --port N           SSH port (default: 22)
  --identity PATH    private key file
  --root PATH        project root on the server (default: ${CX_PROJECT_ROOT:-projects})
  --no-test          skip the connection check
EOF
}

# ---------------------------------------------------------------------------
# Key discovery
# ---------------------------------------------------------------------------

# _host_default_key — the most reasonable existing key, newest algorithm first.
_host_default_key() {
  local k
  for k in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$k" ] && {
      printf '%s/.ssh/%s' "$HOME" "$k"
      return 0
    }
  done
  return 1
}

# _host_offer_keygen — create a key when the user has none. Ed25519 because
# it is the modern default and small; no passphrase prompt is forced here
# since ssh-agent handling is the user's business.
_host_offer_keygen() {
  local key="$HOME/.ssh/id_ed25519"
  warn "No SSH key found in ~/.ssh"
  if ! cx_confirm "  Generate one now (ed25519)?"; then
    hint "create one yourself with: ssh-keygen -t ed25519"
    return 1
  fi
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$key" -N "" -C "cx@$(hostname 2>/dev/null || printf 'localhost')" ||
    return 1
  say "  created $key"
  printf '%s' "$key"
}

# ---------------------------------------------------------------------------
# Connection check
# ---------------------------------------------------------------------------

# _host_check ALIAS — probe, and try to repair an auth failure.
_host_check() {
  local alias="$1" kind

  printf '  checking %s... ' "$alias"
  kind=$(cx_probe "$alias") && {
    say "$(ok_mark) connected"
    return 0
  }
  say "$(bad_mark) $kind"
  say ""
  cx_probe_explain "$kind" "$alias" | sed 's/^/  /'
  say ""

  # An auth failure is the one we can usually fix from here.
  if [ "$kind" = auth ]; then
    if cx_confirm "  Copy your public key to $alias now? (asks for the password)"; then
      if ssh-copy-id "$alias" 2>&1 | sed 's/^/    /'; then
        printf '  re-checking... '
        if cx_probe "$alias" >/dev/null; then
          say "$(ok_mark) connected"
          return 0
        fi
        say "$(bad_mark) still failing"
      fi
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

_host_add() {
  local alias="" hostname="" user="" port="" identity="" root="" do_test=1
  local interactive=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --alias)
        shift
        alias="${1:-}"
        interactive=0
        ;;
      --hostname)
        shift
        hostname="${1:-}"
        interactive=0
        ;;
      --user)
        shift
        user="${1:-}"
        ;;
      --port)
        shift
        port="${1:-}"
        ;;
      --identity)
        shift
        identity="${1:-}"
        ;;
      --root)
        shift
        root="${1:-}"
        ;;
      --no-test) do_test=0 ;;
      -h | --help)
        host_usage
        return 0
        ;;
      *)
        err "unknown option: $1"
        return 3
        ;;
    esac
    shift
  done

  if [ "$interactive" = 1 ]; then
    if [ ! -t 0 ]; then
      err "cx host add needs a terminal, or --alias and --hostname"
      hint "example: cx host add --alias web1 --hostname 10.0.0.5 --user me"
      return 3
    fi
    hdr "Add a server"
    note "  cx will store this in $(cx_hosts_dir)/ and pull it into ssh."
    say ""

    while [ -z "$alias" ]; do
      printf '  Short name (what you will type, e.g. web1): '
      read -r alias || return 1
      if cx_host_exists "$alias"; then
        err "  $alias already exists — use 'cx host edit $alias' or pick another"
        alias=""
      fi
    done

    while [ -z "$hostname" ]; do
      printf '  Hostname or IP: '
      read -r hostname || return 1
    done

    printf '  Login user [%s]: ' "${USER:-root}"
    read -r user || true
    [ -n "$user" ] || user="${USER:-root}"

    printf '  SSH port [22]: '
    read -r port || true
    [ -n "$port" ] || port=22

    if identity=$(_host_default_key); then
      printf '  Identity file [%s]: ' "$identity"
      local reply=""
      read -r reply || true
      [ -n "$reply" ] && identity="$reply"
    else
      identity=$(_host_offer_keygen || printf '')
    fi

    printf '  Project root on the server [%s]: ' "${CX_PROJECT_ROOT:-projects}"
    read -r root || true
    [ -n "$root" ] || root="${CX_PROJECT_ROOT:-projects}"
  fi

  [ -n "$alias" ] || {
    err "--alias is required"
    return 3
  }
  [ -n "$hostname" ] || {
    err "--hostname is required"
    return 3
  }
  [ -n "$user" ] || user="${USER:-root}"
  [ -n "$port" ] || port=22
  [ -n "$root" ] || root="${CX_PROJECT_ROOT:-projects}"

  case "$alias" in
    *[!A-Za-z0-9._-]*)
      err "alias may only contain letters, digits, dot, underscore and hyphen"
      return 3
      ;;
  esac

  if cx_host_exists "$alias"; then
    err "host '$alias' already exists"
    hint "edit it with: cx host edit $alias"
    return 1
  fi

  # Refuse to shadow a Host block the user already wrote — ours would win via
  # the Include and silently change where their `ssh alias` goes.
  if cx_ssh_config_defines "$alias"; then
    err "'$alias' is already defined in ~/.ssh/config"
    hint "adopt it instead: cx host import $alias"
    return 1
  fi

  cx_host_write "$alias" "$hostname" "$user" "$port" "$identity" "$root"
  say ""
  say "  $(ok_mark) wrote $(cx_host_file "$alias")"

  if [ "$do_test" = 1 ]; then
    say ""
    if _host_check "$alias"; then
      say ""
      if cx_confirm "  Install the cx agent on $alias now?"; then
        load_cmd provision && cmd_provision "$alias"
        return $?
      fi
      hint "when ready: cx provision $alias"
    else
      say ""
      note "  The host is saved. Fix the problem above, then: cx host test $alias"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# import
# ---------------------------------------------------------------------------

_host_import() {
  local alias="${1:-}" root=""
  shift 2>/dev/null || true

  while [ $# -gt 0 ]; do
    case "$1" in
      --root)
        shift
        root="${1:-}"
        ;;
      *) ;;
    esac
    shift
  done

  [ -n "$alias" ] || {
    err "usage: cx host import <ssh-alias>"
    return 3
  }

  if cx_host_exists "$alias"; then
    err "cx already knows about '$alias'"
    return 1
  fi

  if ! cx_ssh_config_defines "$alias"; then
    err "'$alias' is not a Host entry in ~/.ssh/config"
    hint "add it there first, or create a new one: cx host add --alias $alias ..."
    return 1
  fi

  [ -n "$root" ] || root="${CX_PROJECT_ROOT:-projects}"
  cx_host_write_import "$alias" "$root"

  say "  $(ok_mark) adopted '$alias' — your ~/.ssh/config was not modified"
  note "  hostname: $(cx_host_field "$alias" hostname)  user: $(cx_host_field "$alias" user)"
  say ""
  _host_check "$alias" || return 1
  say ""
  if cx_confirm "  Install the cx agent on $alias now?"; then
    load_cmd provision && cmd_provision "$alias"
  else
    hint "when ready: cx provision $alias"
  fi
}

# ---------------------------------------------------------------------------
# ls
# ---------------------------------------------------------------------------

_host_ls() {
  local hosts
  hosts=$(cx_hosts_list)

  if [ -z "$hosts" ]; then
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  fi

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$hosts" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      jq -n --arg alias "$h" \
        --arg kind "$(cx_host_kind "$h")" \
        --arg hostname "$(cx_host_field "$h" hostname)" \
        --arg user "$(cx_host_field "$h" user)" \
        --arg port "$(cx_host_field "$h" port)" \
        --arg root "$(cx_host_root "$h")" \
        '{alias:$alias, kind:$kind, hostname:$hostname, user:$user, port:$port, root:$root}'
    done | jq -s .
    return 0
  fi

  {
    printf 'HOST\tKIND\tADDRESS\tROOT\n'
    printf '%s\n' "$hosts" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      printf '%s\t%s\t%s@%s\t%s\n' \
        "$h" "$(cx_host_kind "$h")" \
        "$(cx_host_field "$h" user)" "$(cx_host_field "$h" hostname)" \
        "$(cx_host_root "$h")"
    done
  } | cx_table
}

# ---------------------------------------------------------------------------
# test / edit / rm
# ---------------------------------------------------------------------------

_host_test() {
  local alias="${1:-}" rc=0 doctor
  [ -n "$alias" ] || {
    err "usage: cx host test <alias>"
    return 3
  }
  cx_host_exists "$alias" || {
    err "unknown host: $alias"
    return 2
  }

  hdr "$alias"
  note "  address: $(cx_host_field "$alias" user)@$(cx_host_field "$alias" hostname):$(cx_host_field "$alias" port)"
  note "  root:    $(cx_host_root "$alias")"
  say ""

  _host_check "$alias" || return 1

  printf '  agent... '
  if doctor=$(cx_agent "$alias" doctor 2>/dev/null); then
    say "$(ok_mark) $(printf '%s' "$doctor" | jq -r '.agent_version')"
    printf '%s' "$doctor" | jq -r '
      "  claude:  " + (if .claude.installed then
          ((.claude.version // "installed")
           + (if .claude.logged_in then "  (signed in)" else "  NOT SIGNED IN" end))
        else "not installed" end),
      "  tmux:    " + (if .tools.tmux.present then .tools.tmux.version else "missing" end),
      "  registry:" + (if .registry.valid then " ok" else " missing or invalid" end)'
    printf '%s' "$doctor" | jq -e '.claude.logged_in' >/dev/null 2>&1 ||
      hint "sign in once with: cx login $alias"
  else
    say "$(bad_mark) not installed"
    hint "install it with: cx provision $alias"
    rc=1
  fi
  return "$rc"
}

_host_edit() {
  local alias="${1:-}" f
  [ -n "$alias" ] || {
    err "usage: cx host edit <alias>"
    return 3
  }
  f=$(cx_host_file "$alias")
  [ -f "$f" ] || {
    err "unknown host: $alias"
    return 2
  }
  if [ "$(cx_host_kind "$alias")" = imported ]; then
    note "'$alias' is imported — its connection settings live in ~/.ssh/config."
    note "This file only holds cx settings such as the project root."
    say ""
  fi
  # shellcheck disable=SC2086
  $(cx_editor) "$f"
}

_host_rm() {
  local alias="${1:-}"
  [ -n "$alias" ] || {
    err "usage: cx host rm <alias>"
    return 3
  }
  cx_host_exists "$alias" || {
    err "unknown host: $alias"
    return 2
  }

  note "This removes $alias from cx only."
  note "The server, its projects, and its agent are left untouched."
  if [ "$(cx_host_kind "$alias")" = imported ]; then
    note "Your ~/.ssh/config entry for $alias also stays."
  fi
  say ""
  cx_confirm "Remove '$alias'?" || {
    say "cancelled"
    return 0
  }

  cx_host_remove "$alias"
  cx_cache_invalidate "$alias" # drop data for a host we no longer track
  say "  $(ok_mark) removed $alias"
}

# ---------------------------------------------------------------------------

cmd_host() {
  local sub="${1:-ls}"
  shift 2>/dev/null || true
  case "$sub" in
    add) _host_add "$@" ;;
    import) _host_import "$@" ;;
    ls | list) _host_ls "$@" ;;
    test | check) _host_test "$@" ;;
    edit) _host_edit "$@" ;;
    rm | remove | delete) _host_rm "$@" ;;
    -h | --help | help)
      host_usage
      ;;
    *)
      err "unknown subcommand: cx host $sub"
      say ""
      host_usage
      return 3
      ;;
  esac
}

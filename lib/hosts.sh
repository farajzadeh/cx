#!/usr/bin/env bash
# lib/hosts.sh — which servers cx knows about.
#
# Hosts live in ~/.config/cx/ssh.d/<alias>.conf, pulled into ssh by the single
# Include line the installer adds. Two kinds:
#
#   managed   the file contains a `Host <alias>` block that cx wrote
#   imported  the file contains only `#cx:import=<alias>` metadata, and the
#             Host block lives in the user's own ~/.ssh/config
#
# The imported form exists so adopting an existing server never requires
# editing a file the user maintains by hand. Both kinds are equal citizens
# everywhere else in the tool.
#
# File format (comments are cx metadata, invisible to ssh):
#
#   #cx:root=/srv/work        project root on this server
#   #cx:import=web1           present only for imported hosts
#   Host web1
#       HostName 10.0.0.5
#       User me

[ -n "${_CX_HOSTS_LOADED:-}" ] && return 0
_CX_HOSTS_LOADED=1

cx_hosts_dir() {
  printf '%s' "${CX_SSHD_DIR:-$HOME/.config/cx/ssh.d}"
}

cx_host_file() {
  printf '%s/%s.conf' "$(cx_hosts_dir)" "$(cx_sanitize "$1")"
}

# cx_host_exists ALIAS
cx_host_exists() {
  [ -f "$(cx_host_file "$1")" ]
}

# cx_hosts_list — one alias per line, sorted.
#
# Parsed from the files rather than by asking ssh, because `ssh -G` resolves
# wildcards and would report every Host pattern in the user's config as a cx
# server.
cx_hosts_list() {
  local dir
  dir=$(cx_hosts_dir)
  [ -d "$dir" ] || return 0

  # One awk over every file rather than sed+grep+awk per file. `cx ls` calls
  # this on its hot path, and three processes per host adds up fast.
  # FNR==1 resets per file so each contributes at most one alias.
  awk '
    FNR == 1 { done = 0 }
    done { next }
    /^[[:space:]]*#cx:import=/ {
      sub(/^[[:space:]]*#cx:import=/, "")
      print; done = 1; next
    }
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
      print $2; done = 1; next
    }
  ' "$dir"/*.conf 2>/dev/null | sort -u
}

# cx_host_meta_file FILE KEY — read a #cx:KEY=value line from FILE.
cx_host_meta_file() {
  [ -r "$1" ] || return 0
  sed -n "s/^[[:space:]]*#cx:$2=//p" "$1" 2>/dev/null | head -1
}

# cx_host_meta ALIAS KEY — read #cx:KEY for a host.
cx_host_meta() {
  cx_host_meta_file "$(cx_host_file "$1")" "$2"
}

# cx_host_root ALIAS — project root on that server, falling back to the
# global default. Relative values are interpreted relative to the remote
# $HOME, which is why this can return a non-absolute path.
cx_host_root() {
  local root
  root=$(cx_host_meta "$1" root)
  [ -n "$root" ] || root="${CX_PROJECT_ROOT:-projects}"
  printf '%s' "$root"
}

# cx_host_kind ALIAS — managed | imported | unknown
cx_host_kind() {
  local f
  f=$(cx_host_file "$1")
  [ -f "$f" ] || {
    printf 'unknown'
    return 1
  }
  if [ -n "$(cx_host_meta_file "$f" import)" ]; then
    printf 'imported'
  else
    printf 'managed'
  fi
}

# cx_host_field ALIAS FIELD — resolved ssh option, e.g. hostname, user, port.
#
# Uses `ssh -G`, which applies the user's whole config including Match
# blocks, Include chains, and defaults. Parsing the file ourselves would be
# wrong for imported hosts and for anything relying on ssh's own resolution.
cx_host_field() {
  local fflag=""
  [ -n "${CX_SSH_CONFIG:-}" ] && fflag="-F $CX_SSH_CONFIG"
  # shellcheck disable=SC2086
  ssh $fflag -G "$1" 2>/dev/null | awk -v k="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
    'tolower($1) == k { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Writing host definitions
# ---------------------------------------------------------------------------

# cx_host_write ALIAS HOSTNAME USER PORT IDENTITY ROOT
# Creates or replaces a managed host definition.
cx_host_write() {
  local alias="$1" hostname="$2" user="$3" port="$4" identity="$5" root="$6"
  local dir file
  dir=$(cx_hosts_dir)
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  file=$(cx_host_file "$alias")

  {
    printf '# Managed by cx. Edit with: cx host edit %s\n' "$alias"
    printf '# Removing this file removes the host from cx and from ssh.\n'
    printf '#cx:root=%s\n' "$root"
    printf '\n'
    printf 'Host %s\n' "$alias"
    printf '    HostName %s\n' "$hostname"
    [ -n "$user" ] && printf '    User %s\n' "$user"
    [ -n "$port" ] && [ "$port" != 22 ] && printf '    Port %s\n' "$port"
    [ -n "$identity" ] && {
      printf '    IdentityFile %s\n' "$identity"
      # Without this, ssh offers every key in the agent before the one named
      # here, which trips "Too many authentication failures" on servers with a
      # low MaxAuthTries.
      printf '    IdentitiesOnly yes\n'
    }
  } >"$file"

  chmod 600 "$file"
}

# cx_host_write_import ALIAS ROOT — adopt a host defined in the user's config.
cx_host_write_import() {
  local alias="$1" root="$2" dir file
  dir=$(cx_hosts_dir)
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  file=$(cx_host_file "$alias")

  # Metadata only: no Host block, because one already exists in the user's
  # own config and defining it twice would shadow theirs.
  {
    printf '# Imported by cx from your ~/.ssh/config.\n'
    printf '# The Host block stays in your file; this only records cx settings.\n'
    printf '# Remove this file to stop cx managing %s.\n' "$alias"
    printf '#cx:import=%s\n' "$alias"
    printf '#cx:root=%s\n' "$root"
  } >"$file"

  chmod 600 "$file"
}

# cx_host_remove ALIAS
cx_host_remove() {
  local f
  f=$(cx_host_file "$1")
  [ -f "$f" ] || return 1
  rm -f "$f"
}

# cx_ssh_config_defines ALIAS — is ALIAS a literal Host entry in the user's
# own ~/.ssh/config? Wildcards are excluded: `Host *` matches everything and
# adopting it would be meaningless.
cx_ssh_config_defines() {
  local alias="$1" cfg="${CX_SSH_CONFIG:-$HOME/.ssh/config}"
  [ -r "$cfg" ] || return 1
  awk -v want="$alias" '
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++) {
        if ($i == want) { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$cfg"
}

# cx_hosts_mtime — newest mtime across the host definitions and the user's
# ssh config. The cache keys the parsed host list on this instead of a TTL,
# so an edit is picked up on the very next command and a stale list is
# impossible.
cx_hosts_mtime() {
  local dir newest=0 m f
  dir=$(cx_hosts_dir)

  if [ -d "$dir" ]; then
    m=$(cx_mtime "$dir" 2>/dev/null || printf 0)
    [ "${m:-0}" -gt "$newest" ] && newest="$m"
    for f in "$dir"/*.conf; do
      [ -e "$f" ] || continue
      m=$(cx_mtime "$f" 2>/dev/null || printf 0)
      [ "${m:-0}" -gt "$newest" ] && newest="$m"
    done
  fi

  local usercfg="${CX_SSH_CONFIG:-$HOME/.ssh/config}"
  if [ -e "$usercfg" ]; then
    m=$(cx_mtime "$usercfg" 2>/dev/null || printf 0)
    [ "${m:-0}" -gt "$newest" ] && newest="$m"
  fi

  printf '%s' "$newest"
}

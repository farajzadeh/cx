#!/usr/bin/env bash
# lib/cmd/cache.sh — `cx cache` — inspect or drop cached server data.

# shellcheck source=../projects.sh
. "$CX_HOME/lib/projects.sh"

cx_cache_status() {
  local d hosts h age fresh_s down_age
  d=$(cx_cache_dir)
  hosts=$(cx_hosts_list)

  if [ -z "$hosts" ]; then
    note "No servers configured."
    return 0
  fi

  {
    printf 'HOST\tCACHED\tSTATE\tPROJECTS\n'
    printf '%s\n' "$hosts" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      local n="—"
      if age=$(cx_cache_age "$h"); then
        n=$(jq -r '.projects | length' "$(_cc_list "$h")" 2>/dev/null || printf '?')
        if cx_cache_fresh "$h"; then
          fresh_s="fresh"
        else
          fresh_s="stale"
        fi
        printf '%s\t%s ago\t%s\t%s\n' "$h" "$(cx_human_age "$age")" "$fresh_s" "$n"
      elif cx_cache_is_down "$h"; then
        down_age=$(cx_cache_down_age "$h")
        printf '%s\t—\tunreachable (%s ago)\t—\n' "$h" "$(cx_human_age "${down_age:-0}")"
      else
        printf '%s\t—\tnot cached\t—\n' "$h"
      fi
    done
  } | cx_table

  say ""
  note "  ttl ${CX_CACHE_TTL:-30}s   unreachable ttl ${CX_UNREACHABLE_TTL:-60}s   dir $d"
  note "  the cache is disposable — deleting it changes speed, never correctness"
}

cmd_cache() {
  local sub="${1:-status}"
  shift 2>/dev/null || true

  case "$sub" in
    status | ls)
      cx_cache_status
      ;;
    clear | clean | purge)
      if [ -n "${1:-}" ]; then
        cx_cache_invalidate "$1"
        say "  $(ok_mark) cleared cache for $1"
      else
        cx_cache_invalidate
        say "  $(ok_mark) cleared all cached data"
      fi
      ;;
    refresh)
      # Also the entry point used by background refreshes.
      local host="${1:-}"
      [ -n "$host" ] || {
        err "usage: cx cache refresh <host>"
        return 3
      }
      local out
      if out=$(cx_projects_fetch "$host"); then
        printf '%s' "$out" |
          jq -c --arg h "$host" '. + {host:$h, ok:true}' |
          cx_cache_write "$host"
        cx_cache_clear_down "$host"
      else
        cx_cache_mark_down "$host"
      fi
      # Release the lock the parent took on our behalf.
      [ "${CX_CACHE_LOCK_HELD:-0}" = 1 ] && cx_lock_release "$(_cc_lock "$host")"
      return 0
      ;;
    -h | --help | help)
      cat <<EOF
${C_BOLD}cx cache${C_RESET} — inspect or drop cached server data

  cx cache status          what is cached, how old, and which hosts are down
  cx cache clear [host]    drop cached data (all hosts, or one)
  cx cache refresh <host>  fetch now and update the cache

The cache is disposable. Deleting ~/.cache/cx changes speed, never
correctness — every command falls back to asking the servers directly.

Related flags: -r/--refresh, --no-cache, --stale
EOF
      ;;
    *)
      err "unknown subcommand: cx cache $sub"
      return 3
      ;;
  esac
}

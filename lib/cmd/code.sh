#!/usr/bin/env bash
# lib/cmd/code.sh — `cx code` — open a project in VS Code over Remote-SSH.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_code() {
  local target="${1:-}"

  case "$target" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx code${C_RESET} — open a project in VS Code over Remote-SSH

  cx code <host>:<project>

Opens the project folder in VS Code with the Remote-SSH extension, so editing
happens on the server. Claude Code still runs there too — run it from VS
Code's integrated terminal, or keep using cx open in a separate window.

Requires VS Code and the Remote-SSH extension:
  https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh
EOF
      return 0
      ;;
  esac

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx code <host>:<project>"
    return 3
  }

  local editor="code"
  cx_have "$editor" || {
    # Cursor and VSCodium take the same --remote flag.
    for alt in cursor codium code-insiders; do
      cx_have "$alt" && {
        editor="$alt"
        break
      }
    done
  }
  cx_have "$editor" || {
    err "VS Code is not installed (no 'code' on PATH)"
    hint "install it: https://code.visualstudio.com"
    hint "on macOS also run: Shell Command: Install 'code' command in PATH"
    return 1
  }

  cx_target_resolve "$target" || return $?

  local path
  path=$(cx_agent "$CX_T_HOST" path "$CX_T_PROJECT" 2>/dev/null) || {
    err "could not resolve the project path on $CX_T_HOST"
    hint "check the server with: cx host test $CX_T_HOST"
    return 1
  }

  # VS Code resolves the host through the user's real ~/.ssh/config, which it
  # reads itself. A CX_SSH_CONFIG override is invisible to it.
  if [ -n "${CX_SSH_CONFIG:-}" ]; then
    warn "CX_SSH_CONFIG is set, but VS Code reads ~/.ssh/config directly"
    hint "if the window fails to connect, that mismatch is why"
  fi

  say "  opening $CX_T_HOST:$path in ${editor}"
  "$editor" --remote "ssh-remote+$CX_T_HOST" "$path"
}

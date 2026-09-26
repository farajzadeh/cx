#!/usr/bin/env bash
# lib/cmd/completion.sh — `cx completion bash|zsh|fish` — print the script.
#
# For shells set up by hand, dotfiles, and machines where install.sh's guesses
# about where completions live are wrong: `eval "$(cx completion bash)"` always
# loads the completion matching the cx that printed it. The scripts themselves
# live in completions/, which install.sh also links into place.

cmd_completion() {
  local shell="${1:-}" file

  case "$shell" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx completion${C_RESET} — print the shell completion script

  cx completion bash | zsh | fish

${C_BOLD}bash${C_RESET}   in ~/.bashrc:              eval "\$(cx completion bash)"
${C_BOLD}zsh${C_RESET}    in ~/.zshrc, after compinit: source <(cx completion zsh)
       or as a file on \$fpath:   cx completion zsh > ~/.zfunc/_cx
${C_BOLD}fish${C_RESET}   cx completion fish > ~/.config/fish/completions/cx.fish

oh-my-zsh has a plugin instead — install.sh links it into
\$ZSH_CUSTOM/plugins/cx; add ${C_BOLD}cx${C_RESET} to plugins=(...) in ~/.zshrc.

Completion never touches the network. It completes hosts from your server
list and targets from what cx last saw — run ${C_BOLD}cx ls${C_RESET} once for projects and
worktrees, and ${C_BOLD}cx peek${C_RESET} for sessions and what they are doing (cx bar keeps
that fresh on its own if you use it).
EOF
      return 0
      ;;
    bash | zsh | fish) ;;
    '')
      err "which shell?"
      hint "usage: cx completion bash|zsh|fish"
      return 3
      ;;
    *)
      err "no completion for $shell"
      hint "one of: bash, zsh, fish"
      return 3
      ;;
  esac

  file="$CX_HOME/completions/cx.$shell"
  [ -r "$file" ] || {
    err "missing $file"
    hint "re-run install.sh to repair the installation"
    return 1
  }
  cat "$file"
}

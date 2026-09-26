# cx — oh-my-zsh plugin
#
# Install (install.sh does this for you when it finds oh-my-zsh):
#
#   ln -s ~/.local/share/cx/completions/omz/cx "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/cx"
#
# then add cx to the plugins in ~/.zshrc — plugins=(... cx) — and open a new
# shell.
#
# Completion is _cx, next to this file: oh-my-zsh puts every plugin directory
# on $fpath before it runs compinit, so there is nothing to do here for it —
# unless the directory was copied rather than linked and _cx (a symlink to
# ../../cx.zsh) came along dangling. Then fall back to what cx prints itself,
# written once into oh-my-zsh's own completion cache.

if [[ ! -r ${0:A:h}/_cx ]] && (( $+commands[cx] )); then
  if [[ -n $ZSH_CACHE_DIR && ! -s $ZSH_CACHE_DIR/completions/_cx ]]; then
    mkdir -p "$ZSH_CACHE_DIR/completions" 2>/dev/null &&
      cx completion zsh >|"$ZSH_CACHE_DIR/completions/_cx" 2>/dev/null
    (( ${fpath[(Ie)$ZSH_CACHE_DIR/completions]} )) || fpath=("$ZSH_CACHE_DIR/completions" $fpath)
  fi
  if [[ -s ${ZSH_CACHE_DIR:-/nonexistent}/completions/_cx ]]; then
    autoload -Uz _cx
    (( $+functions[compdef] )) && compdef _cx cx
  fi
fi

# A handful of aliases. Opt out with, before oh-my-zsh is sourced:
#   zstyle ':omz:plugins:cx' aliases no
if zstyle -T ':omz:plugins:cx' aliases; then
  alias cxl='cx ls'
  alias cxo='cx open'
  alias cxp='cx peek'
  alias cxs='cx status'
fi

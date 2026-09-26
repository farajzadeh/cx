#!/usr/bin/env zsh
# capture.zsh LINE — print what zsh's completion offers at the end of LINE.
#
#   zsh -f capture.zsh 'cx open web1:'
#
# One line per match:  tag<TAB>match<TAB>suffix<TAB>description
# where suffix is "-" when zsh would add its usual space, else what is added
# instead (empty for "nothing", ":" for a host).
#
# A real interactive zsh runs in a pseudo-terminal (zsh/zpty) with compinit
# loaded exactly as a user's would be; compadd is wrapped to print what it is
# given, after zsh's own matching has run. The technique is the one from
# Valodim's zsh-capture-completion. CX_ZTEST_MODE picks how the completion is
# loaded: "fpath" (autoloaded as _cx, the oh-my-zsh way) or "source".

zmodload zsh/zpty || exit 2

HERE=${0:A:h}
ROOT=${HERE:h:h:h}

zpty z zsh -f -i

init=$(mktemp "${TMPDIR:-/tmp}/cx-zcap.XXXXXX")
trap 'rm -f "$init"' EXIT
cat >"$init" <<EOF
PROMPT=
unsetopt zle_bracketed_paste 2>/dev/null
if [[ \${CX_ZTEST_MODE:-fpath} == fpath ]]; then
  fpath=("$ROOT/completions/omz/cx" \$fpath)
  autoload -Uz compinit && compinit -u -d "\${TMPDIR:-/tmp}/cx-zcap-dump.\$\$"
elif [[ \$CX_ZTEST_MODE == omz ]]; then
  # What oh-my-zsh.sh does for plugins=(cx): the plugin directory on fpath,
  # compinit, then the plugin file sourced.
  fpath=("\${CX_ZTEST_PLUGIN:-$ROOT/completions/omz/cx}" \$fpath)
  autoload -Uz compinit && compinit -u -d "\${TMPDIR:-/tmp}/cx-zcap-dump.\$\$"
  source "\${CX_ZTEST_PLUGIN:-$ROOT/completions/omz/cx}/cx.plugin.zsh"
else
  autoload -Uz compinit && compinit -u -d "\${TMPDIR:-/tmp}/cx-zcap-dump.\$\$"
  source "$ROOT/completions/cx.zsh"
fi
bindkey '^M' undefined
bindkey '^J' undefined
bindkey '^I' complete-word
null-line() { print -rn -- \$'\\0\\n' }
compprefuncs=( null-line )
comppostfuncs=( null-line exit )
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zmodload zsh/zutil
compadd() {
  # Calls that only compute matches (-O/-A/-D) are zsh's own plumbing.
  if [[ \${@[1,(i)(-|--)]} == *-(O|A|D)\\ * ]]; then
    builtin compadd "\$@"
    return \$?
  fi
  local -a __hits __dscr __tmp asuf
  if (( \$@[(I)-d] )); then
    __tmp=\${@[\$[\${@[(i)-d]}+1]]}
    if [[ \$__tmp == \\(* ]]; then eval "__dscr=\$__tmp"; else __dscr=( "\${(@P)__tmp}" ); fi
  fi
  builtin compadd -A __hits -D __dscr "\$@"
  setopt localoptions norcexpandparam extendedglob
  zparseopts -E -a __ignored S:=asuf
  (( \$#__hits )) || return
  local i sfx d
  for i in {1..\$#__hits}; do
    # -S and its value arrive as one word or as two.
    case \$#asuf in
      0) sfx=- ;;
      1) sfx=\${asuf[1]#-S} ;;
      *) sfx=\$asuf[2] ;;
    esac
    d=\${\${__dscr[\$i]}##\$__hits[\$i] #}
    d=\${d#-- }
    print -r -- "\$curtag"\$'\\t'"\$IPREFIX\$__hits[\$i]"\$'\\t'"\$sfx"\$'\\t'"\$d"
  done
}
print ok
EOF

zpty -w z "source ${(q)init}"
local line
repeat 10; do
  zpty -r z line || break
  [[ $line == ok* ]] && break
done

zpty -w z "$1"$'\t'
integer tog=0
while zpty -r z line; do
  line=${line%$'\r'}
  line=${line%$'\n'}
  line=${line%$'\r'}
  if [[ $line == *$'\0'* ]]; then
    (( tog++ )) && break || continue
  fi
  (( tog )) && print -r -- "$line"
done
zpty -d z 2>/dev/null
exit 0

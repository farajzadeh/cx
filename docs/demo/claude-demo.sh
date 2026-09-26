#!/bin/sh
# A stand-in for Claude Code, for the demo GIFs only.
#
# The integration tests' stub (test/integration/node/claude-stub.sh) prints
# `STUB: ...` lines, which is right for assertions and useless in a picture.
# This one draws something that reads as a Claude Code session — a prompt
# box, a spinner, tool calls, a permission question — and answers from a
# short script. It is labelled "demo" in its own banner: nobody looking
# closely should mistake it for the real thing.
#
# What it has to get RIGHT is everything cx reads, because `cx peek`, `cx
# nudge` and `cx status` in the GIFs are the real code paths:
#
#   * the transcript, ~/.claude/projects/<encoded cwd>/<uuid>.jsonl, in the
#     layout CLAUDE.md "The Claude session store" describes — .type,
#     .isSidechain and .message.stop_reason, with sidechain and bookkeeping
#     lines interleaved the way a real one has them;
#   * the per-process status file, ~/.claude/sessions/<pid>.json — idle, busy,
#     or waiting while a permission question is on screen;
#   * the hooks and status line cx passes in --settings, run with the JSON
#     Claude would send;
#   * --help listing the flags cx checks for before it passes them.
#
# Behaviour per session comes from ~/.cx-demo/scenarios on the node, one
# `<slug> <mode>` line each (setup.sh writes it):
#
#   quick   the default: think for a moment, answer, go back to idle
#   slow    a turn that keeps working for many minutes    → cx peek: working
#   ask     stop on a permission question until answered  → cx peek: blocked

# Run under a copy of sh named `claude`, so that tmux reports the pane's
# command as claude rather than sh. cx reads a pane sitting at a shell as
# "Claude exited" — see the same trick, and why, in claude-stub.sh.
_self_sh="$HOME/.local/share/cx-demo/bin/claude"
if [ "${CX_DEMO_TUI:-0}" != 1 ] && [ -x "$_self_sh" ]; then
  CX_DEMO_TUI=1
  export CX_DEMO_TUI
  exec "$_self_sh" "$0" "$@"
fi

# Box drawing is padded by character count, which needs a UTF-8 locale; a
# pane started over non-interactive ssh may have none at all.
LC_ALL=C.UTF-8
export LC_ALL

session=""
tag=plain
mode=interactive
prompt=""
dispname=""
settings=""
perm=""
model=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      echo "0.0.0 (demo stand-in, not Claude Code)"
      exit 0
      ;;
    --help)
      # The agent greps this before passing --name, --settings and friends.
      cat <<'HELP'
Usage: claude [options] [command] [prompt]

Options:
  -c, --continue                        Continue the most recent conversation
  -r, --resume [value]                  Resume a conversation by session ID
  --session-id <uuid>                   Use a specific session ID
  --permission-mode <mode>              Permission mode for the session
  --dangerously-skip-permissions        Bypass all permission checks.
  --model <model>                       Model for the current session
  --effort <level>                      Effort level for the current session
  -n, --name <name>                     Set a display name for this session
  --settings <file-or-json>             Additional settings
  -p, --print                           Print response and exit
HELP
      exit 0
      ;;
    -p | --print) mode=print ;;
    --session-id)
      shift
      session="${1:-}"
      tag=new
      ;;
    --resume)
      if [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; then
        shift
        session="$1"
        tag=resume
      fi
      ;;
    --permission-mode)
      shift
      perm="${1:-}"
      ;;
    --dangerously-skip-permissions) perm=bypassPermissions ;;
    --model)
      shift
      model="${1:-}"
      ;;
    --effort) shift ;;
    -n | --name)
      shift
      dispname="${1:-}"
      ;;
    --settings)
      shift
      settings="${1:-}"
      ;;
    -*) ;;
    *) prompt="${prompt:+$prompt }$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Looks
# ---------------------------------------------------------------------------

ESC=$(printf '\033')
B="${ESC}[1m"
D="${ESC}[2m"
R="${ESC}[0m"
ORANGE="${ESC}[38;5;173m"
GREEN="${ESC}[38;5;114m"
RED="${ESC}[38;5;174m"
BLUE="${ESC}[38;5;110m"
GREY="${ESC}[38;5;245m"

_cols() {
  _c=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
  case "$_c" in '' | *[!0-9]*) _c=100 ;; esac
  [ "$_c" -gt 110 ] && _c=110
  printf '%s' $((_c - 2))
}

# _rule LEFT RIGHT WIDTH — a box edge.
_rule() {
  printf '%s' "$1"
  _i=2
  while [ "$_i" -lt "$3" ]; do
    printf '─'
    _i=$((_i + 1))
  done
  printf '%s\n' "$2"
}

# _row WIDTH TEXT — one boxed line; TEXT may hold colour codes, so pad by the
# length of the text with them stripped.
_row() {
  _plain=$(printf '%s' "$2" | sed "s/$ESC\[[0-9;]*m//g")
  _pad=$(($1 - 4 - $(printf '%s' "$_plain" | wc -m)))
  [ "$_pad" -lt 0 ] && _pad=0
  printf '%s│%s %s%*s %s│%s\n' "$GREY" "$R" "$2" "$_pad" "" "$GREY" "$R"
}

_banner() {
  _w=$(_cols)
  [ "$_w" -gt 64 ] && _w=64
  _dir=$(pwd | sed "s|^$HOME|~|")
  printf '%s' "$ORANGE"
  _rule '╭' '╮' "$_w"
  printf '%s' "$R"
  _row "$_w" "${ORANGE}✻${R} ${B}Claude Code${R} ${D}(demo stand-in)${R}"
  _row "$_w" ""
  _row "$_w" "${D}cwd:${R} $_dir"
  [ -n "$dispname" ] && _row "$_w" "${D}session:${R} $dispname"
  printf '%s' "$ORANGE"
  _rule '╰' '╯' "$_w"
  printf '%s\n' "$R"
}

# The input box. The cursor is left inside it, after the "> ", so what is
# typed — or pasted by cx nudge — appears where it would in the real thing.
_input_box() {
  _w=$(_cols)
  printf '%s' "$GREY"
  _rule '╭' '╮' "$_w"
  printf '│%s > %*s%s│%s\n' "$R" $((_w - 5)) "" "$GREY" "$R"
  _rule '╰' '╯' "$_w"
  printf '%s  ? for shortcuts%*s%s%s\n' "$D" $((_w - 30)) "" "${dispname:-}" "$R"
  printf '%s[3A%s[5G' "$ESC" "$ESC"
}

# After Enter: wipe the box and leave the prompt in the scrollback.
_took() {
  printf '%s[2A%s[1G%s[J' "$ESC" "$ESC" "$ESC"
  printf '%s> %s%s\n\n' "$D" "$1" "$R"
}

# _spin SECONDS WORD — the thinking line, animated.
_spin() {
  _n=$(($1 * 5))
  _t=0
  _f=0
  while [ "$_t" -lt "$_n" ]; do
    case $((_f % 6)) in
      0) _g='·' ;; 1) _g='✢' ;; 2) _g='✳' ;; 3) _g='✶' ;; 4) _g='✻' ;; *) _g='✽' ;;
    esac
    printf '\r%s%s %s…%s %s(%ss · esc to interrupt)%s%s[K' \
      "$ORANGE" "$_g" "$2" "$R" "$D" $((_t / 5)) "$R" "$ESC"
    sleep 0.2
    _t=$((_t + 1))
    _f=$((_f + 1))
  done
  printf '\r%s[K' "$ESC"
}

_say() { printf '%s⏺%s %s\n' "$B" "$R" "$1"; }
_tool() { printf '%s⏺%s %s%s%s(%s)\n' "$GREEN" "$R" "$B" "$1" "$R" "$2"; }
_out() { printf '  %s⎿%s  %s\n' "$D" "$R" "$1"; }

# ---------------------------------------------------------------------------
# What cx reads — the same shapes claude-stub.sh writes, for the same reasons.
# ---------------------------------------------------------------------------

_enc_dir() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'; }
_store_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(_enc_dir "$(pwd)")"; }

# _append TYPE STOP TEXT — one main-thread message, with a sidechain entry and
# a bookkeeping line after it, as a real transcript interleaves them.
_append() {
  [ -n "$session" ] || return 0
  _d=$(_store_dir)
  mkdir -p "$_d" 2>/dev/null || return 0
  _txt=$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g')
  {
    printf '{"type":"%s","isSidechain":false,"sessionId":"%s","timestamp":"%s",' \
      "$1" "$session" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"message":{"role":"%s","stop_reason":%s,"content":[{"type":"text","text":"%s"}]}}\n' \
      "$1" "$2" "$_txt"
    printf '{"type":"assistant","isSidechain":true,"sessionId":"%s","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}\n' \
      "$session"
    printf '{"type":"file-history-snapshot","sessionId":"%s"}\n' "$session"
  } >>"$_d/$session.jsonl" 2>/dev/null || true
}

_hook() {
  [ -n "$settings" ] && [ -n "$session" ] && command -v jq >/dev/null 2>&1 || return 0
  _cmd=$(printf '%s' "$settings" | jq -r --arg e "$1" '.hooks[$e][0].hooks[0].command // empty' 2>/dev/null)
  [ -n "$_cmd" ] || return 0
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"%s}' \
    "$session" "$1" "$(pwd)" "${2:-}" | sh -c "$_cmd" >/dev/null 2>&1 || true
}

_statusline() {
  [ -n "$settings" ] && [ -n "$session" ] && command -v jq >/dev/null 2>&1 || return 0
  _sl=$(printf '%s' "$settings" | jq -r '.statusLine.command // empty' 2>/dev/null)
  [ -n "$_sl" ] || return 0
  _turns=${_turns:-0}
  printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"demo","display_name":"%s"},"cost":{"total_cost_usd":%s,"total_lines_added":%s,"total_lines_removed":0},"context_window":{"context_window_size":200000,"used_percentage":%s,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":%s,"cache_read_input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":18,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' \
    "$session" "$(_store_dir)" "$session" "$(pwd)" "$(pwd)" "$(pwd)" "${model:-Demo}" \
    "0.$((_turns * 7 + 12))" "$((_turns * 23))" "$((_turns * 6 + 9))" "$((_turns * 12000))" \
    "$(($(date +%s) + 7200))" "$(($(date +%s) + 259200))" |
    sh -c "$_sl" >/dev/null 2>&1 || true
}

_status() {
  [ -n "$session" ] || return 0
  mkdir -p "$HOME/.claude/sessions" 2>/dev/null || return 0
  if [ -z "${_start+x}" ]; then
    _start=$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
    _tmux=""
    [ -n "${TMUX:-}" ] && _tmux=$(tmux display-message -p '#{session_name}:@0.%0' 2>/dev/null)
  fi
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"interactive","tmux":"%s","name":"%s","status":"%s","statusUpdatedAt":%s000}\n' \
    "$$" "$session" "$_start" "$_tmux" "$dispname" "$1" "$(date +%s)" \
    >"$HOME/.claude/sessions/$$.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The script
# ---------------------------------------------------------------------------

_scenario() {
  awk -v s="$dispname" '$1 == s { print $2; exit }' "$HOME/.cx-demo/scenarios" 2>/dev/null
}

# _ask CMD WHY — a permission question, held until someone answers it.
_ask() {
  _w=$(_cols)
  printf '%s' "$BLUE"
  _rule '╭' '╮' "$_w"
  printf '%s' "$R"
  _row "$_w" "${B}Bash command${R}"
  _row "$_w" ""
  _row "$_w" "  $1"
  _row "$_w" "  ${D}$2${R}"
  _row "$_w" ""
  _row "$_w" "Do you want to proceed?"
  _row "$_w" "${BLUE}❯ 1. Yes${R}"
  _row "$_w" "  2. Yes, and don't ask again for this command"
  _row "$_w" "  3. No, and tell Claude what to do differently ${D}(esc)${R}"
  printf '%s' "$BLUE"
  _rule '╰' '╯' "$_w"
  printf '%s' "$R"
  _status waiting
  _hook PermissionRequest ',"tool_name":"Bash"'
  IFS= read -r _answer || exit 0
  printf '%s[12A%s[J' "$ESC" "$ESC"
}

# _turn TEXT — one exchange, chosen by what was asked.
_turn() {
  _append user null "$1"
  _status busy
  _hook UserPromptSubmit
  _sc=$(_scenario)
  case "$_sc" in
    slow)
      _hook PreToolUse ',"tool_name":"Bash"'
      _append assistant '"tool_use"' "running the load test"
      _tool Bash "k6 run load/ratelimit.js --duration 20m"
      _out "running (1m12s) 400 VUs · 38211 requests"
      echo
      _spin 1800 Load-testing
      ;;
  esac
  case "$1" in
    *test*)
      _spin 3 Testing
      _hook PreToolUse ',"tool_name":"Bash"'
      _append assistant '"tool_use"' "running the tests"
      _tool Bash "npm test"
      _out "${GREEN}✓${R} 214 passing ${D}(6.2s)${R}"
      _out "${RED}✗${R} 1 failing: session › refresh rotates the token"
      _spin 2 Fixing
      _tool Update "src/auth/session.ts"
      _out "Updated src/auth/session.ts with 3 additions and 1 removal"
      _tool Bash "npm test -- session"
      _out "${GREEN}✓${R} 31 passing ${D}(0.9s)${R}"
      echo
      _say "All 215 tests pass. The failure was the refresh test reusing a"
      echo "  rotated token; it now requests a fresh one per case."
      ;;
    *review*)
      _spin 3 Reviewing
      _tool Bash "git diff main...authfix --stat"
      _out "4 files changed, 96 insertions(+), 31 deletions(-)"
      _tool Read "src/auth/session.ts"
      _out "Read 142 lines"
      echo
      _say "Two things before this merges:"
      echo "  1. refresh() can race when two requests expire together — lock it."
      echo "  2. The new cookie is missing SameSite=Lax."
      ;;
    *limit*)
      _spin 3 Thinking
      _hook PreToolUse ',"tool_name":"Read"'
      _append assistant '"tool_use"' "reading the login route"
      _tool Read "src/routes/login.ts"
      _out "Read 88 lines"
      _spin 2 Writing
      _tool Update "src/routes/login.ts"
      _out "Updated src/routes/login.ts with 9 additions"
      _tool Bash "npm test -- login"
      _out "${GREEN}✓${R} 17 passing ${D}(1.4s)${R}"
      echo
      _say "Login is now limited to 5 attempts a minute per IP, with a"
      echo "  Retry-After header on the 429. Tests cover both paths."
      ;;
    *document* | *docs*)
      _spin 3 Writing
      _tool Read "docs/auth.md"
      _out "Read 64 lines"
      _tool Update "docs/auth.md"
      _out "Updated docs/auth.md with 21 additions"
      echo
      _say "Documented the session cookie: lifetime, SameSite, rotation."
      ;;
    *migrat* | *deploy*)
      _spin 2 Preparing
      _append assistant '"tool_use"' "about to run the migration"
      _ask "npm run migrate -- --env staging" "Apply 2 pending migrations to staging"
      _tool Bash "npm run migrate -- --env staging"
      _out "applied 20260926_add_sessions, 20260926_token_index"
      echo
      _say "Both migrations are applied on staging."
      ;;
    *)
      _spin 3 Thinking
      _hook PreToolUse ',"tool_name":"Grep"'
      _tool Search "pattern: \"refreshToken\""
      _out "Found 6 files"
      _tool Read "src/auth/session.ts"
      _out "Read 142 lines"
      echo
      _say "Tokens are refreshed in session.ts, 60s before expiry. I can"
      echo "  move that into middleware so every route gets it — want me to?"
      ;;
  esac
  _append assistant '"end_turn"' "done: $1"
  _turns=$((${_turns:-0} + 1))
  _status idle
  _hook Stop
  _statusline
  echo
}

# One-shot, for cx ask: an answer made of this repository's real history, so
# it is at least about the project it was asked in.
if [ "$mode" = print ]; then
  echo "Three changes landed recently:"
  echo
  git log -3 --format='  • %s (%cr)' 2>/dev/null
  echo
  echo "Nothing is uncommitted, and main is in sync with origin."
  exit 0
fi

clear 2>/dev/null || printf '%s[H%s[2J' "$ESC" "$ESC"
_banner
if [ "$tag" = resume ]; then
  printf '%s  resumed conversation %s%s\n\n' "$D" "${session%%-*}" "$R"
fi
if [ "$perm" = bypassPermissions ]; then
  printf '%s  ⏵⏵ bypass permissions on%s\n\n' "$RED" "$R"
fi

_src=startup
[ "$tag" = resume ] && _src=resume
_hook SessionStart ",\"source\":\"$_src\""
_status idle
_statusline

while :; do
  _input_box
  IFS= read -r line || break
  [ -n "$line" ] || {
    printf '%s[2A%s[1G%s[J' "$ESC" "$ESC" "$ESC"
    continue
  }
  _took "$line"
  _turn "$line"
done
_hook SessionEnd
rm -f "$HOME/.claude/sessions/$$.json" 2>/dev/null || true

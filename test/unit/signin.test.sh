#!/usr/bin/env bash
# Unit tests for how the agent's doctor decides Claude Code is signed in —
# what `cx doctor`, `cx host test`, `cx login` and the warning on `cx open`
# all rest on.
#
# The regression this pins: Claude writes ~/.claude.json the first time it
# runs at all, so "the file is there and not empty" reported a server nobody
# had signed in to as signed in. A sign-in is a token in the files, or
# Claude's own `auth status` saying so.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

describe "doctor: is Claude Code signed in?"

if ! command -v jq >/dev/null 2>&1; then
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-signin.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$HOME/.claude"
export CX_CLAUDE_JSON="$HOME/.claude.json"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_AGENT_NO_MAIN=1

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

# A Claude Code that answers `auth status` with FAKE_AUTH (yes, no or a line
# that is not JSON) and lists `auth` in --help unless FAKE_AUTH=old. Every
# call is logged, so a test can tell whether Claude was asked at all.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMP/claude.log"
case "$1" in
  --version) echo "2.1.307 (Claude Code)" ;;
  --help)
    echo "Usage: claude [options] [command] [prompt]"
    echo "Commands:"
    echo "  agents [options]                      Manage background agents"
    [ "$FAKE_AUTH" = old ] ||
      echo "  auth                                  Manage authentication"
    echo "  doctor                                Check the health of Claude Code"
    ;;
  auth)
    case "$FAKE_AUTH" in
      yes) printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n' ;;
      no) printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'; exit 1 ;;
      *) echo "something went wrong"; exit 1 ;;
    esac
    ;;
  *) echo "STARTED A SESSION WITH: $*" ;;
esac
EOF
chmod +x "$TMP/bin/claude"
export TMP FAKE_AUTH=no
PATH="$TMP/bin:$PATH"

# What Claude Code 2.1.307 wrote into ~/.claude.json on its first run in an
# empty home, before anyone signed in (values altered, keys as seen).
FIRST_RUN='{
  "firstStartTime": "2026-10-24T22:40:11.512Z",
  "firstStartVersion": "2.1.307",
  "machineID": "0f3c5d2e9a7b41d6a8c2e1f0b3d4c5a6",
  "migrationVersion": 11,
  "opusProMigrationComplete": true,
  "sonnet1m45MigrationComplete": true,
  "hasResetAutoModeOptInForDefaultOffer": true,
  "seenNotifications": {}
}'

fresh() {
  rm -rf "$HOME" "$TMP/claude.log"
  mkdir -p "$HOME/.claude" "$CX_DATA_DIR"
}
signed_in() { cmd_doctor 2>/dev/null | jq -r '.claude.logged_in'; }
asked() { grep -c '^auth status$' "$TMP/claude.log" 2>/dev/null || true; }

fresh
printf '%s\n' "$FIRST_RUN" >"$CX_CLAUDE_JSON"
it "a fresh server whose ~/.claude.json Claude wrote on its first run is not signed in"
assert_eq "$(FAKE_AUTH=no signed_in)" false
it "because the file says nothing, so Claude itself was asked"
assert_eq "$(asked)" 1

fresh
printf '%s\n' "$FIRST_RUN" >"$CX_CLAUDE_JSON"
it "nor with a Claude Code too old to have \`auth\`"
assert_eq "$(FAKE_AUTH=old signed_in)" false
it "which is never handed \`auth status\`, since it would start a session with it"
assert_eq "$(asked)" 0
assert_not_contains "$(cat "$TMP/claude.log")" "auth"

fresh
printf '%s\n' "$FIRST_RUN" >"$CX_CLAUDE_JSON"
it "nor when \`auth status\` answers with something that is not its JSON"
assert_eq "$(FAKE_AUTH=garbage signed_in)" false

fresh
it "nor with no ~/.claude.json at all"
assert_eq "$(FAKE_AUTH=no signed_in)" false

fresh
printf '%s\n' "$FIRST_RUN" >"$CX_CLAUDE_JSON"
it "is signed in when Claude says so, though the files do not (Keychain, an API key in the environment)"
assert_eq "$(FAKE_AUTH=yes signed_in)" true

fresh
printf '%s\n' '{"claudeAiOauth":{"accessToken":"x","expiresAt":1}}' >"$CX_CLAUDE_DIR/.credentials.json"
it "is signed in with a claude.ai token in .credentials.json"
assert_eq "$(FAKE_AUTH=no signed_in)" true
it "and does not spend Claude's 0.4 s on the question"
assert_eq "$(asked)" 0

fresh
printf '%s\n' "$FIRST_RUN" | jq '. + {oauthAccount: {accountUuid: "x"}}' >"$CX_CLAUDE_JSON"
it "is signed in with a claude.ai account in ~/.claude.json"
assert_eq "$(FAKE_AUTH=no signed_in)" true

fresh
printf '%s\n' "$FIRST_RUN" | jq '. + {primaryApiKey: "sk-ant-x"}' >"$CX_CLAUDE_JSON"
it "is signed in with an API key in ~/.claude.json"
assert_eq "$(FAKE_AUTH=no signed_in)" true

fresh
printf '%s\n' "$FIRST_RUN" | jq '. + {oauthAccount: null, primaryApiKey: ""}' >"$CX_CLAUDE_JSON"
it "is not signed in by a key that is there but empty"
assert_eq "$(FAKE_AUTH=no signed_in)" false

fresh
printf '{"firstStartTime":"2026-10-24T22:40' >"$CX_CLAUDE_JSON"
printf '{}' >"$CX_CLAUDE_DIR/.credentials.json"
it "reads a half-written ~/.claude.json or an empty credentials file as no answer, and asks"
assert_eq "$(FAKE_AUTH=no signed_in)" false
assert_eq "$(asked)" 1

summary

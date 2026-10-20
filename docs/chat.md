# cx chat

`cx chat` lets a program hold a conversation with Claude Code on any cx host,
with no terminal: JSON lines in on stdin, JSON lines out on stdout, and
Claude's requests for approval and its questions arriving as lines to answer.
It is to a program what `cx open` is to a person, and it holds the same
conversation — the one pinned for that session in `sessions.json` — so a chat
started here carries on in tmux with `cx open`, and the other way round.

```sh
cx chat web1:api [--model M] [--permission-mode default|acceptEdits|plan]
                 [--allowed-tools "Read,Edit,Bash(npm test:*)"]
                 [--append-system-prompt-file FILE] [--effort E] [-- ARGS]
```

Every option applies to this one chat. `--permission-mode` also takes cx
open's other modes; `default` is Claude's own and passes nothing.
`--append-system-prompt-file` names a file on the machine running `cx chat`;
its text travels to the server over stdin, ahead of your own lines, never on a
command line.

## The wire

### Lines in (stdin)

| Line | Meaning |
|---|---|
| `{"type":"user","message":{"role":"user","content":"…"}}` | A user turn, in Claude Code's own stream-json input format, passed through unchanged. `content` may be a string or content blocks. Sent while a turn is running, it is queued by Claude for after it. |
| `{"type":"cx","op":"permission","id":"…","behavior":"allow"}` | Allow a pending request as it stands. |
| `{"type":"cx","op":"permission","id":"…","behavior":"allow","updatedInput":{…}}` | Allow it with different input. `updatedInput` **replaces** the input — except for AskUserQuestion, where it is laid over it (below). |
| `{"type":"cx","op":"permission","id":"…","behavior":"deny","message":"…"}` | Deny it. Claude sees `message` as the tool's (failed) result; without one, "The user denied this." |
| `{"type":"cx","op":"interrupt"}` | Stop the current turn. The chat, the process and the conversation stay; send the next turn as usual. |
| `{"type":"cx","op":"close"}` | Finish the current turn, then exit. Nothing after it is read. |

Anything else gets an `error` line and is otherwise ignored: an unknown op
(`"message":"unknown op"`), a line that is not a JSON object, or another
`type` — Claude Code's control protocol is not passed through from the client.

### Lines out (stdout)

1. **First, always:** `{"type":"cx","event":"ready","target":"web1:api","session_id":"<uuid>","resumed":false,"cwd":"/home/u/projects/api"}`.
   `resumed` is whether the conversation already existed.
2. **Claude Code's own `--output-format stream-json --verbose
   --include-partial-messages` lines, unchanged:** `system` (`init` once per
   turn, `status`, `hook_started`/`hook_response` for the hooks cx installs, and
   others), `stream_event` (the text as it is written), `assistant`, `user`
   (tool results), `rate_limit_event`, `control_response` (the answer to an
   interrupt) and `result` (one per turn). Ignore what you do not know, and do
   not depend on key order: a `result` line does not start with `"type"`.
3. **`{"type":"cx","event":"permission_request","id":"…","tool_name":"Bash","tool_use_id":"toolu_…","input":{…}}`**
   whenever Claude wants a tool its permission mode and `--allowed-tools` do
   not already allow. The turn waits until the matching `op: permission`
   arrives. Several can be pending at once; answer each by its `id`. In every
   run observed it came after the `assistant` line holding that `tool_use`, but
   it travels separately, so do not rely on the order.
4. **`{"type":"cx","event":"permission_cancelled","id":"…"}`** when Claude
   stops waiting for an answer — an interrupt does this to a pending request.
   The id can no longer be answered.
5. **`{"type":"cx","event":"error","message":"…"}`** for a line in that cx
   could not use. The chat carries on.
6. **`{"type":"cx","event":"refused","reason":"live"}`**, then the exit line,
   exit 4, when a live tmux session holds the conversation (`cx open` is
   attached to it, or detached and running); `"reason":"chat"` when another
   `cx chat` holds it. One conversation has one writer (invariant 12).
7. **Last, always:** `{"type":"cx","event":"exit","code":0,"reason":"eof|close|claude_exited|error","message":"…"}`.
   `code` is the exit status: non-zero when Claude Code exited with an error,
   or when the chat never started (`reason: error`, with the status below).

### Questions (AskUserQuestion)

A question is a permission request whose `tool_name` is `AskUserQuestion`:

```json
{"type":"cx","event":"permission_request","id":"p1234-3","tool_name":"AskUserQuestion",
 "tool_use_id":"toolu_…","input":{"questions":[{"question":"Which color do you prefer?",
 "header":"Color","multiSelect":false,"options":[{"label":"Red","description":"…"},
 {"label":"Blue","description":"…"}]}]}}
```

Answer it with `behavior: allow` and the answers in `updatedInput`, keyed by
each question's exact `question` text:

```json
{"type":"cx","op":"permission","id":"p1234-3","behavior":"allow",
 "updatedInput":{"answers":{"Which color do you prefer?":"Blue"}}}
```

- The value is the chosen option's `label`. For `multiSelect: true`, join the
  labels with `", "` (`"Apple, Cherry"`). Any other text is accepted as a
  free-form answer (`"Purple, actually"`) and Claude reads it as written.
- `updatedInput` is laid over the original input, so `{"answers":{…}}` alone is
  enough; the `questions` are kept.
- `allow` without `answers` tells Claude "The user did not answer the
  questions." `deny` with a `message` tells it that message.
- Headless Claude Code offers AskUserQuestion **only** when it has a
  permission prompt tool, which cx chat always gives it. Without one (a plain
  `claude -p`) the tool is not in the session's tool list at all, and Claude
  asks in plain text instead — which a client would see as an ordinary
  assistant reply.

### Lifetime, and exit status

A chat runs until stdin reaches EOF or `op: close` arrives, then exits once the
turn in progress has finished (a turn's `result` line is its end). Requests
still waiting for an answer at that point are denied with "The chat was closed
before this was answered.", so the turn can finish. Nothing keeps running
afterwards: there is no daemon.

| Exit | |
|---|---|
| `0` | ended normally |
| `1` | an error, or Claude Code exited with one |
| `2` | no such project or worktree |
| `3` | usage |
| `4` | refused: a live session or another chat holds the conversation |
| `255` | ssh failed or the connection dropped; cx writes the exit line itself |

The hooks `cx open` installs are installed here too, so `cx peek` and `cx bar`
report a chat like any other session: `blocked` while a request waits for the
client, then `working`, `idle` or `fresh`. `cx peek --json` carries a `chat`
fact, `{"pid":…,"pending":N}`, for a session a chat holds.

While a chat holds a conversation, `cx open` (creating a session), `cx ask
<target>@<label>` and `cx forget` refuse it with exit 4, as `cx chat` refuses
a conversation tmux holds.

## What Claude Code does

Established against the real Claude Code 2.1.302 on 2026-10-18, with short
prompts on Haiku. Most of this is not documented anywhere; like the session
store (see ARCHITECTURE.md), it is an observed layout, so the code degrades
rather than hangs when it changes, and these are the facts to re-check first.

1. **Multi-turn over stdin works.** `claude -p --input-format stream-json
   --output-format stream-json --verbose` reads `{"type":"user",…}` lines for
   as long as stdin is open, and answers each with `system/init`, the
   messages, and a `result`. `--session-id <uuid>` starts the conversation,
   `--resume <uuid>` carries it on under the same id, with its history.
   `--include-partial-messages` adds `stream_event` lines as text is written.
2. **EOF ends it politely.** When stdin closes mid-turn, Claude finishes the
   turn, writes its `result`, and exits 0.
3. **A `claude -p` keeps a status file** in `~/.claude/sessions/<pid>.json`,
   like an interactive one, with `kind: "interactive"`, `entrypoint:
   "sdk-cli"` and `status` `busy` or `idle`. It stays `busy`, never `waiting`,
   while a permission tool is deciding — which is why a chat reports its own
   pending count.
4. **`--permission-prompt-tool mcp__<server>__<tool>`** (hidden from `--help`,
   but named by `--permission-prompts`) works with an MCP stdio server given
   by `--mcp-config`. The server sees a `server/discover` probe first (answer
   it with -32601 and Claude falls back), then `initialize` (protocol
   `2025-11-25`), `notifications/initialized` and `tools/list`, and then one
   `tools/call` per decision with `arguments: {tool_name, input, tool_use_id}`
   and `_meta: {"claudecode/toolUseId", progressToken}`. It answers with one
   text content block holding JSON:
   - `{"behavior":"allow","updatedInput":{…}}` runs the tool with that input;
     `{"behavior":"allow"}` alone is also accepted (cx sends the original input
     back regardless, which every version accepts);
   - `{"behavior":"deny","message":"…"}` makes the tool's result an error
     holding the message, and lists the call in the `result`'s
     `permission_denials`.
   The tool is not offered to the model (it is absent from `init`'s tools), a
   45-second wait for an answer was fine, and the `PermissionRequest` hook still
   fires. Each call is subject to Claude's MCP tool-call timeout: a
   per-server `timeout`, else `MCP_TOOL_TIMEOUT`, else 100,000,000 ms — about
   28 hours (read from the 2.1.302 build, not documented). cx leaves it there.
5. **AskUserQuestion is offered only with a permission prompt tool**, arrives
   through it, and takes the answer shape above. Claude's tool result reads
   `"The user answered: \"<question>\"=\"<answer>\", …"`.
6. **Interrupting.** `{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}`
   on stdin — Claude Code's own control protocol, the one its SDK uses — is
   answered with a `control_response` (`subtype: success`), the turn ends with
   a `user` line `[Request interrupted by user]` and a `result` with `subtype:
   error_during_execution`, and the process takes the next turn as usual. A
   SIGINT, by contrast, ends `claude -p` altogether. Interrupted while a
   permission request is pending, Claude sends the MCP server
   `notifications/cancelled` with that request's id, rejects the tool (`[Request
   interrupted by user for tool use]`) and ignores any later answer.
7. **A turn can start without a user line.** A background command finishing
   (`run_in_background`) starts a turn of its own: `system/task_notification`,
   then `init`, the messages and a `result`.
8. `--append-system-prompt-file` works with `-p`, and `--permission-mode
   default` is accepted though `--help` does not list it.

## How it is built

The client half (`lib/cmd/chat.sh`) runs `cx-agent chat` over ssh like every
other verb, with stdin and stdout passed straight through; it only puts the
host into the first line's `target`, and writes the exit line itself when ssh
fails. Everything else is the agent's `chat` verb and its `chat-mcp` helper,
both in `server/cx-agent`, in bash and jq like the rest of it.

- `chat` starts `claude -p` in the session's directory with the pinned id,
  `--mcp-config` naming `cx-agent chat-mcp <rundir>` as the server `cx_chat`,
  and `--permission-prompt-tool mcp__cx_chat__permission`. Claude's stdin and
  stdout are FIFOs in a private run directory under `$TMPDIR`.
- One process copies the client's lines to Claude (and handles `cx` ops),
  another copies Claude's lines to the client. `chat-mcp` is started by Claude,
  so it reaches the client through a third FIFO, drained by one `cat` onto
  stdout. Each writer holds a lock for the length of one line, because a
  stream-json line can be megabytes and the kernel only writes small ones in
  one piece. The lock is a token in a FIFO — both halves are shell builtins,
  where `mkdir` would be a fork per line.
- Each `tools/call` becomes a job that registers a FIFO named for its id,
  announces itself to the client and reads one line: the client's answer, a
  denial from a chat that is closing, or a cancellation from Claude.
- `~/.local/share/cx/chat/<uuid>/owner` holds the conversation while the chat
  runs (pid, start time, run directory). It is what `open`, `ask`, `forget`,
  a second chat and `observe` consult; a claim whose process has gone is
  taken over.

The unit test (`test/unit/chat.test.sh`) runs all of this for real against a
fake Claude that replays recorded stream-json (`test/fixtures/chat/`) and
speaks MCP to `chat-mcp` the way Claude does.

## Not done

- **Changing the permission mode mid-chat.** Claude's control protocol has a
  `set_permission_mode` request, but it is not a documented interface, and a
  chat that needs another mode can be closed and started again: the
  conversation carries over.
- **Long-unanswered approvals.** cx sets no timeout of its own, and Claude's
  MCP tool-call timeout defaults to about 28 hours. What happens to an
  approval left longer was not tested: presumably the tool fails, and the
  client hears of it only if Claude sends `notifications/cancelled` then too.
- **Very long lines are slow to relay.** bash reads a pipe a byte at a time,
  about 0.8 MB/s here: a 2 MB line — an image a tool read, say — reaches the
  client a few seconds after Claude wrote it. Ordinary lines (text deltas,
  tool calls, capped tool output) are small enough not to notice. A relay in
  awk, holding the same FIFO lock, would remove the cost.
- **A chat survives its client only until the turn ends.** That is the design
  (no daemon), but it means a client that loses its connection loses the
  approvals it had not answered: they are denied so the turn can finish.

# cx live — watching and steering sessions from a browser

**Status: design, approved 2026-10-21.** The decisions are recorded at the
end. Sections are updated as each part is built and checked.

Two layers, built in this order:

1. **Remote Control for cx sessions.** Claude Code's own `--remote-control`
   puts a session on claude.ai/code and in the Claude mobile app, with
   everything Claude Code does: the conversation, sending messages, approving
   permission prompts, slash commands, interrupting. cx's part is small:
   starting a session with it, naming it after its cx target, and showing
   which sessions have it.
2. **`cx web`, a live board.** One page, served from the client side, showing
   every session on every server: its state, a live tail of its conversation,
   a message box that goes through `cx nudge`, and goal controls. It does
   **not** rebuild Claude Code in a browser. Layer 1 already does that, so the
   board's "Open in Claude" button links to the session's Remote Control page.

## What was verified, and against what

These were run against host `local` (Claude Code 2.1.306, agent 0.7.0,
tmux 3.4) on 2026-10-21.

| Claim | How it was checked |
|---|---|
| `claude --session-id U --name N --remote-control 'local:salam2@rcprobe'` starts normally in a tmux pane | started in a trusted directory, captured the pane |
| The pane shows `/remote-control is active · … https://claude.ai/code/session_…` | the same capture |
| Claude's status file (`~/.claude/sessions/<pid>.json`) gains `bridgeSessionId: "session_…"` | read the file for the pane's pid |
| The status file's `name` is the `--name` value, not the Remote Control name | the same file |
| **A Remote Control session writes its transcript at startup**, before any message: `custom-title`, `agent-name`, `mode`, `permission-mode`, `bridge-session`, `system`, `last-prompt`, `cost-state` | `jq` over the `.jsonl` it left |
| In a directory Claude has not trusted, the trust prompt comes first and Remote Control is not active until it is answered | started in an untrusted directory |
| `claude --help` lists `--remote-control [name]` and `--remote-control-session-name-prefix <prefix>` (default: hostname) | the installed binary |

Still to verify while building Layer 1, each recorded in this file once checked:
which name claude.ai/code shows when `--name` and `--remote-control <name>`
disagree; `--resume <uuid> --remote-control`; `--resume` (the picker) with
`--remote-control`; whether hooks fire for a message sent from claude.ai; what
happens when the account cannot use Remote Control (API-key auth, a plan
without it).

## Layer 1: Remote Control

### Flags and defaults

```
cx open      <target> --remote-control | --no-remote-control
cx resume    <target> --remote-control | --no-remote-control
cx new       <host>:<name> --remote-control        (implies --open, like every session option)
cx wt add    <host>:<project>/<name> --remote-control
```

Whether a session gets Remote Control is decided in this order. The first
one that says anything wins:

1. `--remote-control` / `--no-remote-control` on the command line.
2. The project's own setting, in the server's `projects.json`
   (`remote_control: true|false`), set with `cx rc on|off|default <target>`.
3. The host's `#cx:remote_control=1|0` line in `~/.config/cx/ssh.d/<host>.conf`.
4. `CX_REMOTE_CONTROL=0|1` in the config or the environment. Default `0`.

The project setting is on the server because a preference that cannot be
derived from anything is exactly what invariant 5 allows the server to record,
and because the server is what every client shares. A laptop and an always-on
host running `cx web` then agree with no copying. This adds one field to
invariant 5's list of recorded fields, and CLAUDE.md is updated in the same
commit.

Steps 1, 3 and 4 are known to the client, and step 2 only to the agent. So the
client sends one of:

| argv to `cx-agent open` | meaning |
|---|---|
| *(nothing)* | no flag, no host or global default: exactly the argv sent today |
| `--remote-control NAME` | on, because the command line said so: wins over the project |
| `--no-remote-control` | off, because the command line said so |
| `--remote-control-default NAME` | on unless the project says off (from the host or global default) |

The agent applies the project setting between them. When nothing turns it
on, the argv is unchanged, so an older agent keeps working. When something
does, the client gates on the agent version, as it does for `--no-hooks`.

### Launch-time only

Remote Control is a flag on the `claude` process the pane runs, so like the
permission mode (invariant 9a) it is **fixed when the session is created**.
Reattaching to a live session with `--remote-control` changes nothing, and
the agent says so on stderr, as it does today for `--permission-mode`. To add
it, run `cx stop` and then `cx open --remote-control`.

`cmd_open` records `remote_control: true` on the session's entry in
`sessions.json` (`_session_set_remote_control`, the same pattern as
`_session_set_hooks`: only the positive is stored, it is cleared explicitly
on every creation, and the clearing path is guarded with `has($s)`).

### The name

Each Remote Control session is named after its cx target, which is the thing
you type: `local:salam2@rcprobe`, `jaryan:yektanet42/rafugar@impl`. The host
part is the client's alias for the server, which only the client knows, so
the client builds the name and passes it. `--remote-control-session-name-prefix`
is not used: it only affects generated names, and cx never lets Claude
generate one.

cx keeps passing `--name <slug>` as it does today, without the host, because
that name shows inside the session's prompt box and the session already knows
which server it is on.

### Showing it

- **`observe`** gains, per session, `remote_control: {enabled, name, url}`.
  `enabled` comes from the pin. `url` is `https://claude.ai/code/<bridgeSessionId>`,
  read from Claude's status file **for the running process**. It is derived
  on every call and never stored, so a stopped session has no link, and a
  restarted one has its new link (invariant 5). observe also gains
  `perm_mode`, which until now only `sessions` reported, so that `cx peek
  --json` and the board need no second call to show a mode.
- **`cx status`** shows `rc` in MODE, joined to the permission mode:
  `rc`, `no-perms+rc`, `acceptEdits+rc`. `--json` gains `remote_control: true|false`.
- **`cx peek`** gets a MODE column with the same values. `--json` gains the
  `remote_control` object and `perm_mode`.

### The classifier needs one fix

An RC session writes its transcript at startup with no message in it. Today
"there is a transcript" means the conversation has started, so a fresh RC
session would read as `unknown` rather than `fresh`, and `cx nudge` would
refuse it. The fix is in `lib/activity.sh`, not in observe's facts: a
transcript that is present but has no main-thread message is classified like
an absent one. A fixture for this goes in `test/fixtures/transcript/`.

The same fact means the next `cx open` of that slug chooses `--resume`
rather than `--session-id`, because the `.jsonl` exists. That is correct, as
long as `claude --resume` accepts a conversation with no messages. That is the
first thing to verify, and if it does not, `cmd_open` looks for a message
rather than just the file.

### How it interacts with the rest of cx

| With | What happens | Status |
|---|---|---|
| A pinned conversation (`--session-id` / `--resume <uuid>`) | Remote Control is a property of the process, not the conversation. Resuming keeps the conversation and gets a new `session_…` link. | session-id verified; resume to verify |
| `--dangerously-skip-permissions` | Allowed, and loud. Anyone who can open your claude.ai account can then run any command on the server with no prompt. `cx open` adds a line to its existing bypass warning. | design |
| cx's hooks | The same process runs them, so a message sent from the phone should fire `UserPromptSubmit`/`Stop` like a typed one. If it does, the state stays exact. If not, the status file still is. | to verify |
| `cx nudge` | Unchanged. A Remote Control viewer is not a tmux client, so it does not count as `attached`. There is a race: you type on the phone at the moment a driver nudges. Nudge checks state just before pasting, which narrows the window but cannot close it. | design |
| `cx goal on-stop` | A turn finished from the phone fires Stop and can start a driver pass, which may then nudge a session you are steering by hand. Pause the goal while you drive. The driver's own `claude -p` gets no Remote Control: it has no person to show it to. | design |
| Invariant 12 (one writer) | Kept. claude.ai is a remote screen for the one process that writes the conversation, not a second writer. | by construction |
| The trust prompt | Comes first, and RC is not active until it is answered. Still `starting`, still unsteerable. | verified |

## Layer 2: `cx web`

### Process model: the browser is the loop

`cx web` is the only cx command that keeps running. Invariant 11 is kept by
what it does while it runs: **it only answers requests.** It has no timer, no
poller and no background fetch, and it holds no state beyond its own
configuration. Every request runs one-shot cx verbs and returns, so killing it
loses nothing, and restarting it changes nothing.

The loop is the browser's, the same way `status-interval` is tmux's loop for
`cx bar`:

- **The board** re-fetches `/api/sessions` on an interval set in the page
  (default 10 s), and only while the tab is visible.
- **The live tail** is Server-Sent Events. **Each SSE connection does exactly
  one incremental read and then closes.** It sends the new messages, an
  `id:` holding the transcript byte offset it read up to, and `retry: 2000`.
  `EventSource` reconnects by itself and sends the offset back as
  `Last-Event-ID`. The cursor lives in the browser. No connection is held
  open between reads, and no server process waits on a transcript.

Concurrent identical reads are coalesced. If two pages ask for the board at
the same moment, one `cx --json peek --tail 0` runs and both get its answer. That is
de-duplication of a request in flight, not a cache: nothing outlives the
request.

CLAUDE.md's invariant 11 gets one paragraph naming `cx web` as the listening
process, and stating the rule that keeps it inside the invariant: it serves,
and never polls.

### How it gets its data

Through the `cx` CLI, never around it. That keeps one source of truth, one
classifier, and one implementation of every refusal rule.

| Page needs | cx web runs |
|---|---|
| sessions, state, quiet, mode, RC link | `cx --json peek --tail 0` (1.2 s for 32 sessions on `local`; the default tail makes it 4.6 s) |
| branch | `cx --json ls` (the cached listing: branch is not urgent) |
| goals, members, log | `cx --json goal ls --host H`, then `cx --json goal show NAME --host H` |
| the conversation tail | `cx --json tail TARGET --from OFFSET` (new, below) |
| send | `cx --json nudge TARGET [--force]`, with the text on **stdin** |
| open -d | `cx --json open -d TARGET [--remote-control]` |
| stop | `cx -y stop TARGET` |
| goal pause / resume / done | `cx goal pause|resume|done NAME --host H` |

Every call is `exec` with an argv array, never a shell. Targets are checked
against the target grammar before they reach argv. A target cannot begin with
`-`, so none can be read as an option. Only stdout is parsed. stderr is
captured separately and shown in the page when a command fails (invariant 2).

### One new verb: `cx tail`

The board needs the conversation as it grows, read incrementally. `cx peek
--json --tail N` re-reads a 256 KB window per session every time, which is
the wrong shape for a stream. So:

```
cx tail <target> [--from OFFSET] [--max N]   →   cx-agent tail ... (one shot)
```

It returns:

```json
{"target":"salam2@impl","uuid":"…","offset":183522,"size":183522,"reset":false,
 "messages":[{"role":"user","text":"…","ts":"…"},
             {"role":"assistant","text":"…","tools":[{"name":"Bash","summary":"ls -la"}]}]}
```

- With `--from`, it reads only the bytes after OFFSET, up to the last
  complete line, so a half-written last line waits for the next read. This is
  the same rule as `cx usage`'s incremental cache, except that the offset
  lives in the browser and not on disk.
- Without `--from`, or when the file is now smaller than OFFSET, or the
  session's pinned uuid changed, it reads the last 256 KB, returns the last
  `--max` messages (default 40), and sets `reset: true`.
- Main thread only (`isSidechain` false), messages only (`type` user or
  assistant), parsed with `fromjson?`, exactly as `_transcript_messages` does.
- Tool calls become `{name, summary}`, where the summary is a short line from
  the input (a command, a path). Tool results are cut to 2 KB. The page shows
  both collapsed.
- It is one-shot like every verb (invariant 11), and it is a CLI command too,
  because the board must not have abilities the CLI lacks.

### API

Every route requires authentication. Every `POST` also requires the CSRF
header. All responses are JSON unless noted.

| Method | Route | Does |
|---|---|---|
| GET | `/` | the page (HTML). Without a valid cookie: a small sign-in form, no data |
| POST | `/api/login` | body `{token}`. Sets the session cookie, returns the CSRF token |
| POST | `/api/logout` | clears the cookie |
| GET | `/api/sessions` | `cx --json peek`, joined with branch from `cx --json ls` |
| GET | `/api/goals` | every goal on every host, with members, state, and the last 20 log entries |
| GET | `/api/tail?target=T` | **SSE**. One `cx tail` read per connection; offset in `Last-Event-ID` |
| POST | `/api/nudge` | `{target, text, force, confirm}`. The `cx nudge` result, refusal included |
| POST | `/api/open` | `{target, remote_control}`. Runs `cx open -d` |
| POST | `/api/stop` | `{target, confirm}` |
| POST | `/api/goal` | `{host, name, action: pause|resume|done, confirm}` |

A refusal from `cx nudge` is a normal `200` with `sent: false` and `reason`,
exactly as the CLI reports it, and the page shows the reason in words. `403`
is only for authentication and CSRF failures.

### The page

One HTML file, `web/index.html`, with inline CSS and JS, no framework and no
build step. It is read from disk on each request, so editing it needs no
rebuild of the server. It uses `prefers-color-scheme` for light and dark, and
one column at phone width.

- **Board.** Grouped by host, and by goal for sessions that belong to one. Each
  row shows the target, a state chip (blocked, idle, working, starting, fresh,
  dead), quiet time, mode (`rc`, `no-perms`, the permission mode), and branch.
  Blocked rows sort first, with a coloured left border and a count in the tab
  title, so a backgrounded tab still says something needs you.
- **Session view.** A live tail: user and assistant text in full, tool calls
  as one collapsed line each. The message box sits below it, with a send
  button that is disabled, with the reason shown, while the last observed
  state is not steerable. The server still decides.
- **Buttons.** *Open in Claude* is the Remote Control link when the session
  has one. Otherwise it says how to get one: "This session was started
  without Remote Control. Stop it and open it again with Remote Control:", with
  a button that does exactly that after a confirmation. Also *open -d*,
  *stop*, and goal *pause*, *resume* and *done*. Stop and done ask for
  confirmation in the page.
- **No-perms sessions** get a red NO-PERMS badge and a standing warning: "A
  message sent here runs with no permission checks, which is remote code
  execution on this server." Every send to one needs the target name typed
  back. `--force` needs a second, separate confirmation on top of that.
- **Goals panel.** Definition of done, members (each linking to its session),
  state, and the latest log entries.

Everything from a transcript is inserted with `textContent`, never
`innerHTML`. Transcript text comes from the code Claude reads and writes, so
it is the main source of hostile input, and it is never treated as markup.

### Running it

```
cx web [--listen 127.0.0.1:8377] [--interval 10]
cx web --rotate-token
cx web --print-url
```

On start it prints `http://127.0.0.1:8377/#token=…`. The token is in the URL
**fragment**, which browsers never send to a server or write to its logs.
The page reads it once, posts it to `/api/login`, and removes it from the
address bar.

## Threat model

**What is at stake.** Code execution on every server cx can reach. A nudge is
a prompt to a Claude that can run commands, and in a no-perms session it runs
them with no prompt at all. The board is therefore a remote shell with extra
steps, and it is secured as one.

**Who it defends against.** Other users on the machine running `cx web`. Other
sites open in the same browser (CSRF, DNS rebinding). Anyone on the network
path when it is reached remotely. Hostile text inside transcripts (XSS).

**Out of scope.** Anyone who already has your client user account. They have
your SSH keys, and so every server, without the board. A compromised server:
it can already lie in its observe output, and the page renders that output
only as text.

| Threat | Defence |
|---|---|
| Reached from the network | Binds `127.0.0.1` by default. Any other address needs `--listen` explicitly and prints a warning. |
| Request with no credentials | Every route checks the session cookie or an `Authorization: Bearer` header, with a constant-time compare. |
| Stolen or leaked token | Token is 32 random bytes in `~/.config/cx/web.token`, mode 0600, created with a 077 umask. `cx web --rotate-token` replaces it. The server reads the file on each check, so rotation takes effect at once, and every cookie issued from the old token stops working. |
| CSRF from another site | The cookie is `HttpOnly; SameSite=Strict; Path=/`, plus `Secure` behind HTTPS. Every POST also needs `X-CX-CSRF`, an HMAC of the token, which another origin cannot read. The `Origin` header must match the request's own host. |
| DNS rebinding | The `Host` header must be one the server is listening as (`127.0.0.1:PORT`, `localhost:PORT`), or a name passed with `--allow-host`. |
| Cross-origin reads | No CORS headers at all. A preflight gets `403`. |
| XSS through transcript text | `textContent` only. Plus `Content-Security-Policy: default-src 'none'; script-src 'self' 'nonce-…'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'`. |
| Clickjacking | `frame-ancestors 'none'` and `X-Frame-Options: DENY`. |
| Injection into cx argv | Target grammar check, argv `exec`, text on stdin (invariant 1). |
| Remote code execution through a nudge | Inherent in the feature. It gets the no-perms warnings and confirmations above, and the refusal rules are the CLI's own. |
| Brute force | 32-byte token. Failed logins are slowed down per address. |

### Reaching it from a phone

**An SSH tunnel** to the host running `cx web`, which is not exposed at all:

```
ssh -N -L 8377:127.0.0.1:8377 always-on-host
# then open http://127.0.0.1:8377/#token=…   (Termius and Blink both forward ports on iOS/Android)
```

**An authenticating reverse proxy** in front of `127.0.0.1:8377`, which handles
TLS and identity, while cx web keeps its own token as a second factor:

- Caddy with `basic_auth` or `forward_auth`, or nginx with `auth_request`, on
  a name you pass to `cx web --allow-host board.example.com`.
- Tailscale `serve`, which keeps it on your tailnet only.

**Never** `--listen 0.0.0.0` on a network you do not control, and never
without TLS in front.

## How each invariant is kept

| # | Invariant | In Layer 1 | In Layer 2 |
|---|---|---|---|
| 1 | No shell strings for the server | The RC name goes through `cx_remote_quote` like every argument, and through `cx_q` into the pane | cx web runs `cx` by argv, never a shell. Text goes on stdin. Targets are grammar-checked |
| 2 | stdout is data, stderr is for people | New observe fields are JSON. Notices go to stderr | Only stdout is parsed. stderr is shown on failure |
| 3 | Minimal PATH over SSH | `tail` lives in the agent, which already fixes PATH | — |
| 4 | Cache is not truth | Actions invalidate as before | cx web caches nothing. Concurrent requests share one run, and nothing outlives a request |
| 5 | Servers own registries, record only what is not derivable | `remote_control` project preference (not derivable) and the pin's `remote_control: true` (launch-time, like `perm_mode`). The link is derived from the status file every time | No state of its own. Everything comes from cx verbs |
| 6 | Agent is one file | `tail` and `rc` are agent verbs inside `cx-agent` | — |
| 7 | bootstrap is POSIX sh | untouched | untouched |
| 8 | Exact-match tmux targets | No new tmux calls | No tmux at all |
| 9 / 9a | Pinned conversations; launch-time facts are recorded | RC recorded at creation and cleared on every creation; a reattach says it cannot be applied | Reads the pin through observe |
| 10 | Names tmux mangles | Targets come from peek JSON verbatim | Same |
| 11 | No judgment, no loop | Flags and facts only | The browser is the loop. One read per request, one read per SSE connection |
| 12 | One conversation, one writer | claude.ai is a screen for the same process. The driver's `-p` has no RC | Steering is `cx nudge` only, never a second `claude` |

## Layout

```
web/main.go        the server (Go, standard library only, no go.sum)
web/index.html     the page, read at runtime
lib/cmd/web.sh     `cx web`: finds or builds the binary, then execs it
lib/cmd/tail.sh    `cx tail`
lib/cmd/rc.sh      `cx rc on|off|default <target>`
```

## Decisions

Made on 2026-10-21, with the review of this design.

- **Invariant 11.** The browser is the loop: cx web serves and never polls.
- **Runtime.** Go, standard library only, no third-party modules. Bash has
  no way to listen on a socket. Go builds one static binary with no
  interpreter on the host, and `net/http` gives HTTP/1.1, SSE and timeouts
  without anything else. The page stays one HTML file, so it needs no build
  step.
- **Getting the binary: both.** CI attaches `cx-web-<os>-<arch>` binaries
  (linux and darwin, amd64 and arm64) to every release. `install.sh` downloads
  the one that matches, checks it against the release's `SHA256SUMS`, and puts
  it in `web/bin/`. When there is none (a checkout, an unknown platform, no
  network), `cx web` builds from `web/*.go` with the local `go` into
  `~/.cache/cx/web/`, keyed by a hash of the sources. That is a cache under
  invariant 4: delete it, and the next run rebuilds. With neither a binary
  nor Go, `cx web` says which of the two to get and exits 1.
- **Remote Control per project.** A `remote_control` field in the server's
  `projects.json`, set with `cx rc on|off|default <target>`. `cx rc` on its
  own lists the effective setting for every project.
- **No-perms sessions.** Sending is allowed, with a warning and a typed
  confirmation. `--force` needs a second confirmation.
- **Board refresh.** 10 s by default, changeable in the page, paused while the
  tab is hidden.
- **Web terminal.** Built after Layer 2, as an option (see below).

## Read-only terminal (`cx web --terminal`)

Optional, and off unless asked for. It shows the raw TUI of one session in
the page, for when the tail is not enough and Remote Control is not on.

- `ttyd` runs **on the client host** and attaches **read-only** (no `-W`),
  bound to `127.0.0.1` on a random port. It runs
  `ssh -t HOST cx-agent open … --view`, a new agent mode that runs `tmux
  attach -r` (read-only) to the existing session. It never creates a session.
- cx web starts one ttyd per terminal view, on request, and proxies it
  (HTTP and WebSocket) under `/term/<id>/`, behind cx web's own
  authentication, so ttyd's port is never handed to the browser. The ttyd
  process ends when its viewer disconnects (`--once`), so nothing lingers.
- A read-only attach is still a tmux client. It counts as `attached`, so
  while someone watches, `cx nudge` declines exactly as it does when you are
  attached in a terminal. That is deliberate. The watcher is a person, and
  the same rule protects them.
- With no `ttyd` installed, the button is not shown, and `cx web --terminal`
  says how to get it.

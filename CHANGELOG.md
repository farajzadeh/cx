# Changelog

All notable changes to cx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and cx uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — while it is
below 1.0, a minor version may change behaviour, and every such change is
listed under **Behaviour changes**.

cx has two halves with their own versions: the client (`cx --version`) and
the agent on each server (`cx doctor`, `cx host test`). From 0.5.0 on, a
release sets both to the same number. After upgrading the client, run
`cx provision --all` to bring every server's agent up to date.

## [Unreleased]

### Behaviour changes

- **`cx peek` has a MODE column** between STATE and WHO: the permission mode
  a session was started with (`no-perms` for none) and `rc` for Remote
  Control, joined as in `no-perms+rc`. A script that splits the table on
  whitespace sees one more column; `--json` is the stable form.

### Added

- **Remote Control** (2026-10-21): `cx open`, `resume`, `new` and `wt add`
  take `--remote-control`, which starts Claude Code with its own Remote
  Control so the session is also on claude.ai/code and in the Claude app,
  named after its cx target (`web1:api@review`). `--no-remote-control` turns
  it off for one session. The default comes from, in order, the project's own
  setting, the host file's `#cx:remote_control=0|1` and `CX_REMOTE_CONTROL`
  (default `0`). Like the permission mode it is fixed when a session starts.
  Needs agent 0.8.0 and Claude Code signed in with a claude.ai account.
  Claude Code turns Remote Control back on whenever it resumes a conversation
  that had it, so `--no-remote-control` cannot remove it from one: cx says
  so, and records the session as `rc`.
- **`cx rc [on|off|default <host>:<project>]`** (2026-10-21): a project's own
  Remote Control setting, kept in its server's registry so every machine you
  run cx from sees the same one. Bare, it lists every project and what its
  new sessions get.
- **`cx status` shows `rc` in MODE and takes `--json`** (2026-10-21).
- **`cx peek --json`** has, per session, `remote_control` (`enabled`, `name`,
  and `url`, the claude.ai link, read from Claude's own status file while the
  session runs) and `perm_mode`.

### Fixed

- A session whose transcript holds no message yet is `fresh`, not `idle` or
  `unknown`. A Remote Control session writes its transcript the moment it
  starts, so a file on disk no longer meant the conversation had begun.
  `cx nudge` sends to it as to any other fresh session.

## [0.7.0] - 2026-10-20

### Added

- **`cx usage [host] [--days N]`** (2026-10-20): how much of Claude each
  server's account has used. The five-hour and weekly limits as Claude last
  reported them — its status line in a cx session, or its own copy of its
  `/usage` screen — with their reset times and how old the reading is; and
  tokens per day and per project over the last N days (1-90, default 30),
  counted from the transcripts on the server, subagents included and each
  message once. `--json` gives one object per host, with `ok` and `error` for
  a server that could not answer. Nothing reads a login or calls Anthropic.
  The agent remembers what it has read of each transcript (a cache under
  `~/.local/share/cx/usage/`), so only the first run on a busy server is slow.
  Needs agent 0.7.0: `cx provision <host>`.
- **`cx chat --ask-tools "Bash(git push:*),Bash(sudo:*)"`** (2026-10-20): tools
  Claude must always ask about first, even in auto mode, whose safety check
  lets such steps through when the conversation asks for them. They go into
  the `--settings` cx already passes, as `permissions.ask` rules, so cx's
  hooks stay. An agent older than 0.7.0 or a Claude Code without `--settings`
  refuses the chat instead of dropping them.

## [0.6.0] - 2026-10-20

### Behaviour changes

- **A conversation a `cx chat` holds is refused by `cx open` (when it would
  start the session), `cx ask <target>@<label>` and `cx forget`, with exit
  `4`.** Each would otherwise be a second writer on one conversation. Needs
  agent 0.6.0.

### Added

- **`cx chat <target>`**: a conversation with Claude Code for a program, as
  JSON lines on stdin and stdout, on the same pinned conversation `cx open`
  uses. Claude's replies are its own stream-json, streamed as written;
  approvals and AskUserQuestion questions arrive as `permission_request` lines
  and are answered with `op: permission`; `op: interrupt` stops a turn and
  keeps the chat. Takes `--model`, `--permission-mode`, `--effort`,
  `--allowed-tools` and `--append-system-prompt-file`, whose text travels over
  stdin. The protocol, and what it relies on in Claude Code, is in
  `docs/chat.md`. Needs agent 0.6.0.
- `cx peek` and `cx bar` report a session a chat holds — `blocked` while an
  approval waits for the program — and `cx peek --json` carries its `chat`
  fact. The agent's `observe` reports it.

## [0.5.0] - 2026-09-26

The release that makes cx about running several Claude sessions at once and
knowing which one needs you, rather than about opening one.

### Behaviour changes

Read these first if you script cx or have been using 0.1.0.

- **Re-provision your servers.** Most features below need the 0.5.0 agent.
  `cx provision --all` updates every server in place; nothing on them is lost.
  Against an older agent, the plain commands of 0.1.0 keep working, and
  anything newer stops with "the cx agent on web1 is too old for …" and the
  command to fix it, instead of an unknown-option error. `cx doctor` flags
  every server whose agent differs from the client.
- **`cx ls <word>` treats an unknown word as a pattern.** A first word naming
  a configured host still means that host. Anything else now filters the
  listing and exits `0` — a mistyped host name used to be an error with
  exit `2`, and now gives an empty (or unexpectedly short) listing instead.
- **Commands ask when a target is missing, but only at a terminal.** `open`,
  `resume`, `shell`, `code`, `stop`, `nudge`, `forget`, `rm` and `wt rm`
  offer a menu, and backing out of it exits `130`. Without a human — a pipe,
  a script, `--json`, `-y` or `CX_PICKER=none` — they print the same error
  and exit `3` as before.
- **Bare `cx new` and `cx wt add` are interactive at a terminal.** They ask
  for what is missing and then whether to open a session in the result
  (`CX_OPEN_AFTER_CREATE=ask|always|never`). Scripts see the old behaviour.
- **Exiting Claude now ends the session.** The pane runs Claude itself rather
  than a shell with Claude in it, so quitting Claude no longer leaves a shell
  prompt on the server. `cx shell` is the way to get one.
- **Each session keeps its own conversation.** `cx open` used to resume "the
  newest conversation in this directory", so two sessions on one project
  shared — and corrupted — one conversation. Every session now pins its own.
  The first open after upgrading adopts the conversation it would have
  resumed before, so no history appears lost.
- **`cx ask` refuses a session that is running** (exit `4`), because two
  writers on one conversation silently lose turns. Use `cx nudge` to talk to
  a running session.
- **`cx open` passes Claude per-session settings**: hooks that report the
  session's state, and a status line for the server's tmux bar. Your own
  `settings.json` is never modified, and your own `statusLine` still runs.
  `--no-hooks` and `CX_SERVER_BAR=0` turn them off.
- **Two terminals can share a session** on servers with tmux 3.1 or later;
  attaching no longer throws the other one out.
- **`cx peek` counts finished sessions instead of listing them.** `--all`
  lists them; `--json` is unchanged.

### Added

**Working in parallel**

- Targets extend to `[host:]project[/worktree][@session]`.
- `@label` sessions: another conversation on the same files, e.g.
  `cx open web1:api@review`.
- Worktrees: `cx wt add`, `cx wt ls` and `cx wt rm` (alias `worktree`) give a
  task its own branch and directory. cx records nothing about them — they come
  from git, so one made by hand appears and one deleted by hand disappears.
- `cx ls` marks merged worktrees, and `cx wt rm web1:api --merged` removes
  every one that is merged, clean and has no running session.

**Finding things**

- An interactive picker, using fzf when it is installed and a numbered menu
  with a filter when it is not.
- `cx find [query]` (alias `cx pick`): browse every project, worktree and live
  session, then open, shell, code, peek, nudge, stop or start a new `@session` on
  it. `cx find --print` prints the choice, for `cx ask "$(cx find --print)"`.
- `cx new --open` and `cx wt add --open` create and attach in one step, with
  `-d`, `--label` and the Claude options below passed through.
- `cx ls` filters, groups and sorts: a pattern or `-f`, `--host`, `--live`,
  `--active 2h`, `--idle 7d`, `--dirty`, `--no-worktrees`,
  `--group host|none`, `--sort name|active|sessions|host|none`, with
  `CX_LS_GROUP` and `CX_LS_SORT` as defaults. Plain `cx ls` prints exactly
  what it did before.
- `cx host ls` takes a pattern, `--reachable` and `--down`, and shows each
  server's project count and last known state — from the cache, without
  connecting.
- `cx wt ls -f PATTERN`, matching the same way as `cx ls`.

**Watching and steering sessions**

- `cx peek`: what each session is doing — `idle`, `working`, `blocked`,
  `starting`, `fresh` or `dead` — from Claude's own status reports, falling
  back to the transcript. `--goal NAME` narrows it to a goal's members.
- `cx nudge`: type a prompt, multi-line included, into a running session. It
  declines (exit `0`, `sent: false`) a session that is busy, still starting,
  or attached in front of you.
- `cx goal`: a definition of done and the sessions working on it, stored on
  the server and able to span servers. `new`, `ls`, `show`, `dod` (keeps the
  earlier text), `member add|rm`, `pause`, `resume`, `done`, `log`, `rm`.
- `cx goal on-stop`: a goal that drives itself — when a member finishes a
  turn, the server runs one pass of the driver. Bounded by an hourly cap and
  stopped by pausing the goal.
- `cx driver` prints the cx-driver Claude Code subagent, which moves sessions
  towards their goals through the CLI.
- A notifier hook: `~/.config/cx/notify` on a server runs when a session
  starts waiting on you.
- `cx forget`: drop a finished session from the lists. The conversation
  itself is kept, and `cx resume` still reaches it.

**Your terminal**

- `cx bar`: the sessions waiting for you on one line, for a tmux status bar.
  `cx bar --setup` prints the lines to add to `~/.tmux.conf`.
- `cx tabs`: a local tmux tab per live session, each showing its state, and
  safe to re-run.
- `cx jump` (`prefix + j`): go to the tab of the session that needs you.
- The server's own tmux bar, inside an attached session, shows its state,
  model, context use, cost and the account's usage limits.
- Tab icons as plain shapes by default, Nerd Font icons with
  `CX_BAR_ICONS=nerd`, colour with `CX_BAR_COLOR=1`.

**Claude options**

- `cx open` and `cx ask` take `--permission-mode`, `--model`, `--effort`,
  `--dangerously-skip-permissions`, and `--` for anything else. The mode is
  recorded and shown in the MODE column of `cx status`, since it cannot be
  seen from inside a session.
- `cx ask` takes `--output-format`, `--json-schema` and `--max-budget-usd`.
- `cx open -d` starts a session without attaching to it.

**Shell completion**

- Rewritten for bash, zsh and fish around the target grammar: flags for every
  command, projects then worktrees and `@labels`, running sessions for `stop`
  and `nudge`, and goal names. Global flags before the command no longer
  break it. Completion never touches the network.
- An oh-my-zsh plugin, with optional aliases `cxl`, `cxo`, `cxp`, `cxs`.
- `cx completion bash|zsh|fish` prints the script for the installed cx.
- `install.sh` links the bash completion and the oh-my-zsh plugin into place,
  and `--uninstall` removes the links.

### Changed

- `cx peek`, `cx bar` and a single-session peek are several times faster on
  servers with many sessions.
- `cx provision` also copies the driver's instructions to the server, for
  goals that drive themselves.
- `cx bar --setup` suggests a 10-second status interval instead of 30.

### Fixed

- Sessions on a project whose name contains a dot were never found as
  running, and `cx stop` on one did nothing.
- A project `cx-api` could attach to `cx-api@review`, because tmux matched
  the session name as a prefix.
- `cx ls` showed no conversation history for any worktree.
- `cx peek <target> --json` returned every session on the server rather than
  the one asked for.
- A long `cx nudge` could report "sent" while the prompt sat unsubmitted.
- `cx nudge` right after `cx open -d` could answer Claude's "trust this
  folder?" prompt with "No, exit" and end the session.
- Sessions that were opened, never used and stopped stayed in `cx peek`
  forever.
- `cx provision` printed only "bootstrap failed" without the reason.
- `cx doctor` warned that every up-to-date agent was out of date.

## [0.1.0] - 2026-08-11

Initial release: manage servers (`cx host`), provision the agent and sign
Claude Code in on each one, create and list projects across servers, and
open, resume, stop and ask Claude sessions that live in tmux on the server.

[Unreleased]: https://github.com/farajzadeh/cx/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/farajzadeh/cx/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/farajzadeh/cx/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/farajzadeh/cx/compare/v0.1.0...v0.5.0
[0.1.0]: https://github.com/farajzadeh/cx/releases/tag/v0.1.0

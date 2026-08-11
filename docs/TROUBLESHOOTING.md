# Troubleshooting

Start here:

```sh
cx doctor
```

It checks this machine and every server, and names the fix for anything wrong.

---

## Installation

### `cx: command not found` after installing

`~/.local/bin` is not on your `PATH`. The installer prints the lines to add
but does not edit your shell config unless you ask:

```sh
./install.sh --shell-setup     # shows a diff, then appends
```

Or add it yourself and restart your shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### `install.sh --check` says jq is missing

`jq` is the one dependency most people do not already have. The check prints
the exact command for your platform — `sudo apt-get install -y jq`,
`brew install jq`, `sudo dnf install -y jq`, and so on.

### The installer refuses to run on macOS

If it reports a bash version below 3.2 something unusual is going on — macOS
has shipped 3.2 for years and that is the floor cx targets. Report it.

### `cx: broken installation`

The tree at `~/.local/share/cx` is missing or incomplete. Re-run
`./install.sh` to repair it.

---

## Servers

### A host is not listed by `cx host ls`

Either there is no file for it in `~/.config/cx/ssh.d/`, or the `Include` line
is missing from `~/.ssh/config`. Check:

```sh
grep 'cx/ssh.d' ~/.ssh/config
```

If it is absent, re-run `./install.sh`, or add it yourself **at the top** of
the file (ssh uses first-match-wins, so position matters):

```
Include ~/.config/cx/ssh.d/*.conf
```

### `cx host test` says `auth`

SSH reached the server and your credentials were rejected.

```sh
ssh-copy-id web1        # cx host add offers to do this for you
ssh -v web1             # see which keys were offered
```

If you have many keys, the server may hit `MaxAuthTries` before reaching the
right one. cx-managed hosts set `IdentitiesOnly yes` to avoid that; imported
hosts follow whatever your own config says.

### `cx host test` says `timeout`

No response at all — a firewall, a wrong address, or a VPN you are not
connected to. `ping` the hostname and check `HostName` with
`cx host edit <alias>`.

### `cx host test` says `hostkey`

The server's host key does not match your `known_hosts` entry.

If the server was genuinely rebuilt:

```sh
ssh-keygen -R <hostname>
```

**If it was not rebuilt, stop and investigate.** This is what an intercepted
connection looks like.

### Provisioning fails with `No supported package manager`

The server has none of apt-get, dnf, yum, pacman, zypper or apk. Install
`tmux`, `git`, `jq` and `curl` by hand, then re-run `cx provision` — it
installs nothing when nothing is missing.

### Provisioning asks for a sudo password in a script

`cx provision` only requests a TTY when it has one. In a pipeline or CI, sudo
must already be passwordless. On a server that is fully set up, `cx provision`
never invokes sudo at all.

---

## Claude

### `NOT SIGNED IN`

Sign-in is interactive and happens once per server:

```sh
cx login web1
```

Credentials are stored on that server and never reach your machine — that is
the point of the design, not an oversight.

### `claude: command not found` on the server

Almost always PATH. A non-interactive `ssh host cmd` does not read `.bashrc`,
and `~/.profile` is only read by login shells. `cx` calls the agent by
absolute path for this reason, and provisioning adds `~/.local/bin` to
`~/.profile`.

Check what the server actually sees:

```sh
ssh web1 'command -v claude || echo missing'
ssh web1 'ls ~/.local/bin/'
```

Re-run `cx provision web1` to reinstall.

### The `SESSIONS` column shows `?`

cx could not find Claude Code's session store on that server. That is expected
before Claude has ever run there. If it persists after real usage, the storage
layout may have changed — see the note in
[ARCHITECTURE.md](ARCHITECTURE.md#the-claude-session-store--a-known-assumption).
The column degrades on purpose; nothing else is affected.

---

## Sessions

### `cx open` says the agent is not installed

```sh
cx provision web1
```

### My session disappeared after the server rebooted

The tmux process died with the reboot. The conversation itself is on disk, so
`cx open` starts a new session and resumes it. Anything Claude was midway
through when the machine went down is lost.

### `cx open` reattaches but Claude is not running

The Claude process exited at some point — the shell it was running in stays,
by design, so you keep the session and its scrollback. Just run `claude` again
in that pane, or `cx stop` and `cx open` for a clean start.

### The display is squashed after reconnecting

That is tmux sizing the window to the smallest attached client. `cx open`
passes `attach -d` to detach stale clients, so this should not happen — if it
does, check for a genuine second attachment:

```sh
ssh web1 'tmux list-clients'
```

---

## Listing and the cache

### `cx ls` shows stale information

It should not: every command that changes server state invalidates its host's
cache before returning. If you see it anyway, force a fetch and please report
it:

```sh
cx ls -r
cx cache status     # shows the age of every entry
```

### `cx ls` is slow

```sh
cx cache status
```

- **Every host says `not cached`** — the cache is not being written. Check
  that `~/.cache/cx` is writable.
- **A host shows `unreachable`** — that one is down. Its projects still show
  from cache, and it is skipped without connecting until the mark expires.
- **Consistently slow even warm** — SSH multiplexing may not be engaging.
  Check `ls ~/.ssh/cm-*` after a command; if nothing appears, the socket path
  may be too long or `~/.ssh` may not be writable.

### One dead server slows everything

It should cost about five seconds once, then nothing. If every command is
slow, `CX_UNREACHABLE_TTL` may be `0`. Check with `cx cache status`.

### Working offline

```sh
CX_STALE_OK=1 cx ls
```

Renders entirely from cache, at any age, fetching nothing.

---

## Targets

### `'api' exists on more than one server`

Exactly what it says — cx refuses to guess. Name the host:

```sh
cx open web1:api
```

Or set `CX_DEFAULT_HOST` in `~/.config/cx/config` so bare names resolve to one
server.

### `no project named 'x' on any server`

```sh
cx ls               # what exists
cx new web1:x       # create it
```

If you expected it to exist, the server holding it may be unreachable — check
for an `unreachable` warning under the listing.

---

## Shell completion

### Tab completion does nothing

Completion reads `~/.cache/cx/targets`, which is written by any listing:

```sh
cx ls
```

It deliberately performs no network work, so it will never hang — but it also
will not populate itself until something has listed projects at least once.

Confirm the completion file is sourced (`--shell-setup` adds this):

```sh
[ -f "$HOME/.local/share/cx/completions/cx.bash" ] && . "$HOME/.local/share/cx/completions/cx.bash"
```

---

## Still stuck

Open an issue with:

```sh
cx doctor
cx --version
bash --version | head -1
uname -a
```

If it involves a specific server, `cx host test <alias>` output helps too.
Redact hostnames as needed — the failure classification is the useful part.

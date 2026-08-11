# Adding and managing servers

cx talks to your servers over ordinary SSH. If you can `ssh myserver`, cx can
use it.

This page covers the guided path, the manual path, and the awkward cases
(bastions, non-standard ports, existing configs).

---

## The short version

```sh
cx host add          # answer a few questions
cx login <alias>     # one-time Claude Code sign-in on that server
```

`cx host add` offers to run `cx provision` for you at the end, which installs
the agent. That is everything.

---

## How cx stores servers

Each server gets one file:

```
~/.config/cx/ssh.d/<alias>.conf
```

and the installer adds a single line to the top of `~/.ssh/config`:

```
Include ~/.config/cx/ssh.d/*.conf
```

That is the **only** edit cx makes to a file you own, it is backed up first,
and `install.sh --uninstall` removes it again.

Two consequences worth knowing:

- Servers cx manages are ordinary SSH hosts. `ssh web1`, `scp`, `rsync` and
  `git` all work against them with no extra configuration.
- Deleting `~/.config/cx/ssh.d/web1.conf` removes the host from cx **and**
  from SSH. Nothing on the server changes.

Connection tuning (multiplexing, timeouts) is **not** written into your
config — cx passes those as `-o` flags at call time, so your other SSH
sessions behave exactly as they did before.

---

## Adding a server interactively

```sh
cx host add
```

You will be asked for:

| Prompt | Meaning | Default |
|---|---|---|
| Short name | what you type: `cx open web1:api` | — |
| Hostname or IP | where to connect | — |
| Login user | remote account | your local username |
| SSH port | | 22 |
| Identity file | private key | your newest existing key |
| Project root | where projects are created on that server | `projects` (relative to remote `$HOME`) |

If you have no SSH key, cx offers to generate an ed25519 one. If the server
rejects your key, cx offers to run `ssh-copy-id` for you.

---

## Adding a server non-interactively

For dotfiles, scripts, or CI:

```sh
cx host add \
  --alias web1 \
  --hostname 10.0.0.5 \
  --user deploy \
  --port 2222 \
  --identity ~/.ssh/id_ed25519 \
  --root /srv/work \
  --no-test
```

`--alias` and `--hostname` are required; everything else has a default.
`--no-test` skips the connection check, which is what you want when the
server is not reachable from wherever the script is running.

---

## Adopting a server you have already configured

If `~/.ssh/config` already has an entry:

```
Host prod
    HostName prod.example.com
    User deploy
    ProxyJump bastion
    IdentityFile ~/.ssh/prod_ed25519
```

then import it:

```sh
cx host import prod
```

**Your `~/.ssh/config` is not modified.** cx writes a small metadata file
recording only its own settings (the project root), and defers to your entry
for everything about the connection — including `ProxyJump`, `Match` blocks,
and anything else you have configured.

This is the right choice when your SSH config is generated, shared, or under
version control.

---

## Awkward cases

### Behind a bastion / jump host

Configure it in your own `~/.ssh/config` and import:

```
Host bastion
    HostName bastion.example.com
    User me

Host internal-app
    HostName 10.0.1.20
    User deploy
    ProxyJump bastion
```

```sh
cx host import internal-app
```

cx uses your SSH config, so the jump is transparent.

### Non-standard port

`cx host add --port 2222`, or set `Port` in your own config and import.

### A key with a passphrase

Add it to your agent once per session:

```sh
ssh-add ~/.ssh/id_ed25519
```

Without an agent, every cx command prompts for the passphrase. Connection
multiplexing means it is far fewer prompts than you would expect — the first
command per 10-minute window — but an agent is still much better.

### Several servers sharing a project root

Nothing special: each server has its own registry, and project names only
need to be unique per server. `cx ls` shows the host alongside each project,
and `cx open api` will ask which one you meant if the name is ambiguous.

### A different SSH config file

Set `CX_SSH_CONFIG=/path/to/config`. cx passes it to every `ssh` and `scp`
call. Note that setting `HOME` is *not* enough: OpenSSH resolves the default
config path from the passwd database, not from `$HOME`.

---

## Checking a server

```sh
cx host test web1      # connectivity, agent version, sign-in state
cx doctor              # this machine plus every server
```

`cx host test` distinguishes the failure modes, because they need different
fixes:

| Result | Meaning | Fix |
|---|---|---|
| `auth` | reached the server, credentials rejected | `ssh-copy-id web1` |
| `refused` | server answered, port closed | is sshd running? right port? |
| `timeout` | no response | firewall, wrong address, or VPN not connected |
| `dns` | hostname does not resolve | fix `HostName` |
| `hostkey` | host key changed | if the server was rebuilt, `ssh-keygen -R <host>`; if not, **stop and investigate** |
| `unreachable` | no network route | wrong network or VPN |

---

## Updating servers

After updating cx itself, push the new agent everywhere:

```sh
cx provision --all
```

Provisioning is idempotent and safe to re-run. It installs nothing when
nothing is missing — so it does not even ask for `sudo` on a server that is
already set up.

---

## Removing a server

```sh
cx host rm web1
```

Removes the host from cx and from SSH. **The server is untouched**: its
projects, its agent, and its Claude Code credentials all remain. To clean up
the server itself:

```sh
ssh web1 'rm -rf ~/.local/bin/cx-agent ~/.local/share/cx'
```

Your projects under the project root are never touched by that command.

---

## What cx installs on a server

`cx provision` is deliberately minimal and conservative:

| Action | Notes |
|---|---|
| Installs `tmux`, `git`, `jq`, `curl` | only the ones missing; uses apt/dnf/yum/pacman/zypper/apk |
| Installs Claude Code | via its official installer, only if absent |
| Creates `~/.local/bin/cx-agent` | the agent |
| Creates `~/.local/share/cx/projects.json` | the project registry |
| Creates the project root | `~/projects` by default |
| Adds `~/.local/bin` to `PATH` | one guarded block in `~/.profile` |
| Writes `~/.tmux.conf` | **only if the file does not exist** |

It never overwrites an existing `~/.tmux.conf` or registry, never touches your
shell configuration beyond that one PATH block, and never runs `sudo` unless a
package genuinely needs installing.

Credentials are the one thing provisioning does **not** handle — sign-in is
interactive and happens once, via `cx login <host>`. Credentials are stored on
that server and never reach your local machine.

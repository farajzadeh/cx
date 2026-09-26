# Demo GIFs

The GIFs in [`docs/media/`](../media/) are recorded, not drawn: every one is
real `cx` running against two real SSH servers, from a script in this
directory. Re-record them whenever the output they show changes.

```sh
docs/demo/record.sh              # every GIF (about 20 minutes)
docs/demo/record.sh hero find    # just these
```

| GIF | shows |
|---|---|
| `hero` | `cx ls` across two servers, `cx find`, open a blocked session, answer it, detach |
| `picker` | `cx open` with no target: the fzf menu and its preview |
| `find` | `cx find` → action menu → peek; `cx find --print` inside `$(...)` |
| `create-open` | bare `cx new` asking its questions, then `cx wt add --open -d` |
| `ls-filter` | `cx ls` with a pattern, `--live`, `--group host --sort active`; `cx host ls` |
| `completion` | bash tab completion down the target tree, and a flag's values |
| `parallel` | `@label` and `/worktree` side by side, then `cx status` |
| `peek-nudge` | `cx peek`, `cx nudge`, a nudge declined, peek again |
| `tabs` | `cx tabs` in the laptop's own tmux with `cx bar --setup`: state icons in the tab titles changing, `prefix j` to the blocked one |

**Requirements: Docker.** Nothing else is installed on your machine and
nothing of yours is read — not `~/.ssh`, not `~/.config/cx`, not
`~/.cache/cx`. The first run builds two images and pulls
`ghcr.io/charmbracelet/vhs` (about 1 GB).

## What happens

1. **`setup.sh`** starts two servers, `web1` and `web2`, from the integration
   tests' sshd image (`test/integration/node`), on a private Docker network,
   and a "laptop" container from `Dockerfile` here: VHS plus the cx client,
   fzf and bash-completion, with the repository mounted at `/cx`. The
   laptop's home is a Docker volume holding its own SSH key and cx config.
   Then it runs the real `cx provision` on both servers.
2. **`inside.sh seed`** gives both servers the same projects (`api`, `web`,
   `docs`, `infra`), worktrees (`api/authfix`, `api/ratelimit`), and live
   sessions in known states. It runs again before every tape, so each GIF
   can be re-recorded on its own and comes out the same.
3. **`tapes/<name>.tape`** is recorded by VHS, then squeezed by gifsicle,
   into `docs/media/<name>.gif`. `tapes/settings.tape` holds the size, font
   and theme they share, and `tapes/prelude.tape` the shell setup — two
   files because VHS ignores a `Set` after any other command, so a tape
   that changes a setting (`tabs` swaps the font for one with `◐`) does it
   between them. `tabs` also runs a tmux on the laptop, configured by
   `cx bar --setup` plus `laptop.tmux.conf`.
4. **`teardown.sh`** removes the containers, network and volume. The images
   are kept; `docker rmi cx-demo-vhs cx-test-node` removes them.

Everything is named `cx-demo-*`, so it never collides with an integration
test run (`cx-test-node-*`) on the same machine.

## The Claude in the pictures is a stand-in

`claude-demo.sh` is installed on the servers as `claude`. It draws a
Claude Code–like screen and answers from a short script, and it says
"demo stand-in" in its own banner. What it gets right is everything cx
reads — the transcript, the per-process status file, the hooks and status
line cx passes it — so `cx peek`, `cx nudge` and `cx status` in the GIFs are
the real code paths. `~/.cx-demo/scenarios` on a server picks how a session
behaves when prompted: `ask` stops on a permission question (peek shows
`blocked`), `slow` keeps working for many minutes (`working`).

## Working on a tape

```sh
docs/demo/record.sh --keep hero      # record, and leave the servers up
docs/demo/record.sh --no-setup hero  # re-record against them: much faster
docs/demo/teardown.sh                # when done
```

A tape is plain [VHS](https://github.com/charmbracelet/vhs) — `Type`,
`Enter`, `Sleep`. Keep each GIF short (10–25 s) and under about 1.5 MB;
`record.sh` prints each file's size. Before committing, look at the frames:
no errors, nothing cut off at the edges, and nothing from the machine that
recorded it.

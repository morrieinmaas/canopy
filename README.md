# canopy

canopy is a tmux configuration distribution written in POSIX shell. You clone it,
put its `bin/` on your `PATH`, and run `canopy install`. It takes ownership of your
tmux entry point, migrates whatever config was already there into a file that stays
yours, and records every path it touches in a transaction ledger so the whole change
can be undone.

There is no daemon, no build step, and nothing to compile.

## Status: milestones 1 and 2 of six

canopy is being built in six ordered milestones. **M1 and M2 exist today.** M1 is the
skeleton, the part whose job is to make everything after it safe to install. M2 is
the wedge: a reboot returns an agent pane to its own conversation.

| M | Delivers | State |
|---|---|---|
| **M1** | A machine can adopt canopy and shed it again without a trace | **shipped** |
| **M2** | A reboot returns every agent pane to its own conversation | **shipped** |
| M3 | Agent state is visible across four agents without polling | not started |
| M4 | Every command is reachable by key, CLI and palette from one definition | not started |
| M5 | A theme repaints tmux and, where opted in, ghostty and starship | not started |
| M6 | Worktrees are navigable as peers, with optional autostart | not started |

What M1 ships:

- seven commands: `canopy`, `caps`, `doctor`, `index`, `install`, `restore`, `version`
- a tmux config loader with a fixed layer order, ending in a config file you own
- a capability probe that writes tool availability into tmux options
- a transaction ledger that makes install reversible

What M2 adds:

- three commands: `agent`, `reboot-check`, `adopt`
- tmux-resurrect and tmux-continuum vendored at pinned commits, no plugin manager
- a save-command strategy that rewrites an agent pane's saved command into the
  command that resumes **that pane's** conversation
- an adapter contract, and one adapter, for Claude Code
- `canopy reboot-check`, which answers "is it safe to reboot?" from what was
  actually saved rather than from what canopy meant to save

What is **not** shipped: adapters beyond Claude Code, a command palette, key
bindings beyond tmux's own, themes, the worktree layer, and autostart. Nothing
starts a tmux server at login, so a restore happens when you next start tmux, not
at boot.

Persistence needs `bash` and a `ps` that can report a process's parent. Without
either, it does nothing at all, and `canopy doctor` says so. See
[docs/07-persistence.md](docs/07-persistence.md).

## The guarantee

> `canopy restore --all` returns every file that existed before canopy to its exact
> original bytes.

That includes a `tmux.conf` that was a symlink into a dotfiles repo, which goes back
as the same symlink pointing at the same target, with the target untouched. It
includes directories: one canopy created and you did not is removed again, and one
that predates canopy is kept, along with anything else in it.

The single exception is canopy's own state directory, `~/.local/state/canopy`. It
holds the restore points themselves, so removing it would make the guarantee last
only until the first restore. Deleting it is a separate, deliberate act, described
in [docs/01-installation-and-removal.md](docs/01-installation-and-removal.md).

How the guarantee is enforced:

| Check | What it does | Where |
|---|---|---|
| Restore proof | Three scenarios: a home with real configs, an empty home, a symlinked `tmux.conf` pointing outside `$HOME`. Records hashes and a full `find` listing before install, restores, and diffs both. | `test/restore-proof.sh`, run in CI on Ubuntu and macOS |
| Container acceptance | Eight scenarios inside Debian (`/bin/sh` is dash) and Alpine (BusyBox userland), from a bare environment with no `CANOPY_*` set. Covers a virgin box, an existing config, a symlinked config, a dangling symlink, an interrupted install, two user accounts on one machine, and a simulated reboot that must return three panes to their own three conversations. | `test/smoke/run.sh`, run in CI on Linux |
| Unit suite | 276 bats tests over the libraries and every command. | `test/*.bats`, run in CI on Ubuntu and macOS |

A restore promise that is not in CI stops being true around version three.

## Install

```sh
git clone https://github.com/morrieinmaas/canopy.git ~/.local/share/canopy
export PATH="$HOME/.local/share/canopy/bin:$PATH"   # add this to your shell rc

canopy install --dry-run    # prints every path it would touch, changes nothing
canopy install              # add --yes if you already have a tmux config
```

Clone anywhere you like. canopy finds its own store from the real path of the running
script, following symlinks first, so symlinking `bin/canopy` into a directory already
on your `PATH` works just as well as putting the clone's `bin/` there:

```sh
ln -s ~/.local/share/canopy/bin/canopy ~/.local/bin/canopy
```

`canopy install` refuses without `--yes` when a tmux config already exists, because
taking it over is a migration rather than a merge. Your config is copied into
`~/.config/canopy/user.conf` and sourced last, so it still wins over every canopy
default.

## Uninstall

```sh
canopy restore --all                 # puts every file back, byte for byte
rm -rf ~/.config/canopy              # your canopy overrides, kept until you say so
rm -rf ~/.local/state/canopy         # restore points; the guarantee ends here
rm -rf ~/.local/share/canopy         # the clone
```

Run them in that order. `canopy restore --all` reads the restore points, so removing
state first leaves you with nothing to restore from. Then drop the `PATH` line from
your shell rc.

`canopy restore --all` exits 1 and changes nothing for any file you edited after
canopy wrote it, naming each one. Add `--force` to revert those too, after canopy has
backed up their current bytes.

## Requirements

| | |
|---|---|
| tmux | 3.4 or newer |
| shell | any POSIX shell (`dash`, `ash`, `bash`, `ksh`) |
| for persistence only | `bash`, and a `ps` that reports a process's parent |
| everything else | nothing |

The two persistence requirements are not optional where persistence is wanted, and
canopy installs neither. The vendored resurrect and continuum are bash scripts, so
without `bash` the plugin layer loads nothing. canopy recognises an agent pane by
asking `ps` what the pane is running, so a `ps` that cannot answer, BusyBox ships
one, means no pane is ever recognised as an agent. `canopy doctor` reports both, and
probes `ps` by running it rather than by looking for the binary.

canopy calls only standard userland utilities (`awk`, `sed`, `grep`, `cut`, `cp`,
`mv`, `rm`, `mkdir`, `rmdir`, `chmod`, `touch`, `date`, `sort`, `tail`, `id`, `env`,
`stat`, `readlink`, `dirname`) plus one of `sha256sum` or `shasum`. Both GNU and
BusyBox userlands are tested in CI. `git` is how you obtain canopy, not something
canopy runs.

Optional tools (`wt`, `fzf`, `gum`, `ghostty`, `starship`, `mise`) are detected and
recorded, never installed. A missing one leaves its layer dormant, never broken.

## What canopy does to your machine

Every path canopy reads or writes, and nothing else:

| Path | What happens | Reversible |
|---|---|---|
| `~/.tmux.conf` **or** `~/.config/tmux/tmux.conf` | Whichever tmux would load is replaced with a short stub that sources canopy. If neither exists, the XDG one is created. | yes |
| `~/.config/canopy/user.conf` | Created, or appended to. Your previous entry point's contents are migrated here. | yes |
| `~/.config/mise/conf.d/canopy.toml` | Written only if `mise` is installed or that directory already exists. Declares `fzf`, `gum` and `starship` as tools. | yes |
| `~/.local/state/canopy/05-caps.conf` | Generated capability flags. Did not exist before canopy. | n/a |
| `~/.local/state/canopy/commands.tsv` | Generated command index. Did not exist before canopy. | n/a |
| `~/.local/state/canopy/resurrect/` | tmux-resurrect's save files. Did not exist before canopy. | n/a |
| `~/.claude/settings.json` | Only on `canopy agent install claude-code`, and only merged, never replaced. Recorded in a transaction first. | yes |
| `~/.local/state/canopy/backups/` | Restore points. Kept forever. | n/a |
| `/tmp/canopy-<uid>` or `$XDG_RUNTIME_DIR/canopy` | Scratch files, created mode 0700. canopy refuses to use it if anyone else owns it or can write to it. | n/a |

canopy never writes to `~/.config/ghostty`, `~/.config/starship.toml`, or anything
else on your machine. It does not install packages. It does not touch a running tmux
server.

Every path above honours `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, and each can be
overridden directly with `CANOPY_CONFIG`, `CANOPY_STATE`, `CANOPY_RUNTIME` and
`CANOPY_STORE`. All must be absolute.

## Documentation

| Page | Covers |
|---|---|
| [01 Installation and removal](docs/01-installation-and-removal.md) | Installing over an existing config, over a dotfiles symlink, `--dry-run`, and complete removal |
| [02 Commands](docs/02-commands.md) | Every command, its flags, its output and its exit codes |
| [03 The restore guarantee](docs/03-restore-guarantee.md) | The transaction model, restore points, the two rollback classes, and the `restore.sh` escape hatch |
| [04 Configuration](docs/04-configuration.md) | The `conf.d` layer order, `user.conf`, and the capability model |
| [05 Troubleshooting](docs/05-troubleshooting.md) | Symptoms and what to do about them |
| [06 Contributing and testing](docs/06-contributing-and-testing.md) | Running the three suites, and the rule every verification follows |
| [07 Persistence](docs/07-persistence.md) | What survives a reboot, the chain that makes it work, `reboot-check`, `adopt`, and how to verify with a real agent |
| [08 Agents](docs/08-agents.md) | Adapters, installing the Claude Code one, capability tiers, and what state reporting costs |

The full product design lives in
[docs/superpowers/specs/2026-09-17-canopy-design.md](docs/superpowers/specs/2026-09-17-canopy-design.md).
It describes all six milestones, so most of it is not implemented. Everything in it
that does not exist yet carries an explicit `[planned, M<n>]` marker, and its opening
section explains the convention, so a sentence with no marker describes what the code
does today. Where the design and the code disagree anyway, the code is what your
machine runs.

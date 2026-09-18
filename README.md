# canopy

canopy is a tmux configuration distribution written in POSIX shell. You clone it,
put its `bin/` on your `PATH`, and run `canopy install`. It takes ownership of your
tmux entry point, migrates whatever config was already there into a file that stays
yours, and records every path it touches in a transaction ledger so the whole change
can be undone.

There is no daemon, no build step, and nothing to compile.

## Status: milestone 1 of six

canopy is being built in six ordered milestones. **Only M1 exists today.** M1 is the
skeleton, the part whose job is to make everything after it safe to install.

| M | Delivers | State |
|---|---|---|
| **M1** | A machine can adopt canopy and shed it again without a trace | **shipped** |
| M2 | A reboot returns every agent pane to its own conversation | not started |
| M3 | Agent state is visible across four agents without polling | not started |
| M4 | Every command is reachable by key, CLI and palette from one definition | not started |
| M5 | A theme repaints tmux and, where opted in, ghostty and starship | not started |
| M6 | Worktrees are navigable as peers, with optional autostart | not started |

What M1 ships:

- seven commands: `canopy`, `caps`, `doctor`, `index`, `install`, `restore`, `version`
- a tmux config loader with a fixed layer order, ending in a config file you own
- a capability probe that writes tool availability into tmux options
- a transaction ledger that makes install reversible

What M1 does **not** ship: agent integration, reboot persistence, a command palette,
key bindings beyond tmux's own, themes, and the worktree layer. If you install canopy
today expecting agent panes to survive a reboot, what you get is a config loader and
a reliable way to undo it.

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
| Container acceptance | Six scenarios inside Debian (`/bin/sh` is dash) and Alpine (BusyBox userland), from a bare environment with no `CANOPY_*` set. Covers a virgin box, an existing config, a symlinked config, a dangling symlink, an interrupted install, and two user accounts on one machine. | `test/smoke/run.sh`, run in CI on Linux |
| Unit suite | 136 bats tests over the libraries and every command. | `test/*.bats`, run in CI on Ubuntu and macOS |

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
| everything else | nothing |

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

The full product design lives in
[docs/superpowers/specs/2026-09-17-canopy-design.md](docs/superpowers/specs/2026-09-17-canopy-design.md).
It describes all six milestones, so most of it is not implemented. Everything in it
that does not exist yet carries an explicit `[planned, M<n>]` marker, and its opening
section explains the convention, so a sentence with no marker describes what the code
does today. Where the design and the code disagree anyway, the code is what your
machine runs.

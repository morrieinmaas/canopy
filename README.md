# canopy

A tmux setup for people who run coding agents in their panes.

You have Claude Code open in six panes across three sessions, each deep in its own
conversation. Then the laptop reboots. Plain tmux-resurrect brings back the layout,
but every pane comes back as an empty shell, or as a *fresh* `claude` with no memory
of what it was doing.

With canopy, each pane comes back running **the same conversation it had before**.

It's also a sensible, reversible tmux config: vim-style pane keys, splits that keep
your working directory, a status line, autosave every five minutes. It's plain POSIX
shell with no daemon and nothing to compile, and one command undoes it all.

## Try it

```sh
git clone https://github.com/morrieinmaas/canopy.git ~/.local/share/canopy
export PATH="$HOME/.local/share/canopy/bin:$PATH"   # add this to your shell rc

canopy install --dry-run            # shows exactly what it would change, changes nothing
canopy install                      # add --yes if you already have a tmux config
canopy agent install claude-code    # lets Claude Code tell canopy which conversation it's in
```

Then start tmux. `canopy doctor` tells you if anything's missing.

You'll need tmux 3.4 or newer. For the reboot part you also need `bash` and a normal
`ps` (both standard on macOS and most Linux distros; BusyBox-only systems don't
qualify). canopy installs nothing on its own and tells you what's missing.

## Your existing config is safe

If you already have a `tmux.conf`, canopy moves its contents into
`~/.config/canopy/user.conf`, which loads **last**, so your settings still win over
canopy's defaults. That file is yours: canopy never edits it again.

Before touching anything, canopy records exactly what was there. To go back:

```sh
canopy restore --all
```

Every file comes back to its original bytes, including a `tmux.conf` that was a
symlink into your dotfiles repo. This is tested in CI on every commit, on Linux and
macOS. If you edited a file after canopy wrote it, restore stops and names it rather
than overwrite your work.

The full list of paths canopy touches is in
[docs/01](docs/01-installation-and-removal.md), along with how to remove canopy
completely.

## Before you reboot

```sh
canopy reboot-check
```

This reads the last save and tells you, pane by pane, which conversations will come
back and which won't. It checks what was actually written to disk, not what canopy
intended to write. Press `prefix M-s` to save right now instead of waiting for the
next autosave.

Restores happen when tmux next starts. canopy doesn't start tmux at login for you.

## Keys

The prefix is `Ctrl-s`. The main additions to stock tmux:

| Key | Does |
|---|---|
| `\|` and `-` | Split right or below, staying in the current directory |
| `h` `j` `k` `l` | Move between panes |
| `H` `J` `K` `L` | Resize; keep pressing to repeat, no prefix needed |
| `c` | New window with one big pane on the left and two stacked on the right |
| `C` | Plain new window |
| `t` | Jump back to the previous session |
| `r` | Reload the config |
| `M-s` / `M-r` | Save now / restore the last save |

`canopy keys --print` lists them all, and `canopy config` shows every option canopy sets next
to its default. Override anything in `~/.config/canopy/user.conf`.

## What works today

canopy is young. This first release covers the part that matters most: installing
and removing it safely, and getting agent conversations back after a reboot.

Only **Claude Code** is supported so far. The adapter format is small and documented
in [adapters/contract.md](docs/adapters/contract.md), and adapters for opencode, pi
and codex are planned. Also planned: a status view of what each agent is doing, a
command palette, themes, and git worktree navigation.

## Documentation

- [Installation and removal](docs/01-installation-and-removal.md)
- [Commands](docs/02-commands.md)
- [How restore works](docs/03-restore-guarantee.md)
- [Configuration](docs/04-configuration.md)
- [Troubleshooting](docs/05-troubleshooting.md)
- [Contributing and testing](docs/06-contributing-and-testing.md)
- [Persistence in detail](docs/07-persistence.md)
- [Agents and adapters](docs/08-agents.md)

## Contributing

Bug reports, fixes and adapters for other agents are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md); the short version is `mise install` then
`mise run check`. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache 2.0, see [LICENSE](LICENSE).

canopy bundles [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) by Bruno Sutic
(MIT), unmodified, at the commits in [plugins/VERSIONS](plugins/VERSIONS). See
[NOTICE](NOTICE).

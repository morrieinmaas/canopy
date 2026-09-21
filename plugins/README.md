# Vendored tmux plugins

`tmux-resurrect` and `tmux-continuum` live here as ordinary files, copied
out of upstream at a recorded commit. Together they are what makes a
reboot return a pane to where it was.

## Why vendored, and not fetched

canopy never reaches the network to run. There is no plugin manager, no
`set -g @plugin` line, no `git clone` on first launch. A user who checks
out canopy has, in that checkout, every byte that will ever execute.

That rules out three things on purpose:

- **Submodules.** A submodule is a promise to fetch later, and "later" is
  a machine that has just rebooted and may have no network at all. It is
  also one more command (`git submodule update --init`) between a fresh
  clone and a working config, and the failure when it is forgotten is
  silent: tmux loads a layer that does nothing.
- **A plugin manager.** tpm clones at runtime into `~/.tmux/plugins`, so
  what runs is whatever upstream's default branch said this morning. That
  is a moving dependency underneath the one feature canopy exists to
  provide.
- **Fetching in `vendor.sh` at install time.** `vendor.sh` is a
  maintainer tool. Nothing in `bin/` calls it and nothing needs it to run
  canopy.

## The three files

| File | Holds | Written by |
|---|---|---|
| `VERSIONS` | `<name> <upstream-url> <commit>` | by hand, when moving a pin |
| `CHECKSUMS` | `<name> <sha256-of-tree>` | `vendor.sh` |
| `<name>/` | the tree itself | `vendor.sh` |

`VERSIONS` says where a tree came from. `CHECKSUMS` says what it looked
like when it arrived, which is what lets `canopy doctor` distinguish
"present" from "unmodified": a tree edited in place still reports an
upstream commit, and debugging a persistence bug against source that is
not what is running is a long afternoon.

The digest is defined in `lib/plugins.sh`: one sha256 over every regular
file in C-collated path order, each contributing its own hash, its path,
and whether it is executable. The executable bit is in there because a
`.tmux` entry point that lost its `+x` is a broken tree that a
content-only digest would call intact.

## Updating a pin

```sh
# edit the commit on that plugin's line in VERSIONS, then:
plugins/vendor.sh tmux-resurrect
```

Commit the whole resulting diff, `CHECKSUMS` included. `vendor.sh`
refuses a name that `VERSIONS` does not pin, so the pin is always written
down before the tree changes.

## What `vendor.sh` strips, and why

One invariant governs it: **what `vendor.sh` writes must be exactly what
`git checkout` of canopy reproduces.** `CHECKSUMS` is worthless otherwise,
because every fresh clone would report as modified. Three things in an
upstream tree break that invariant, and all three are upstream repository
plumbing rather than plugin content:

- `.git`, the history, never vendored.
- `.gitignore` and `.gitmodules`. Git honours a nested `.gitignore`, so
  canopy's own `git add` would silently drop files `vendor.sh` had just
  written; resurrect's ignores three paths it also ships. `.gitmodules`
  describes the `lib/tmux-test` submodule canopy deliberately does not
  vendor.
- dangling symlinks, and the directories left empty under them.
  resurrect ships three links into that un-vendored submodule's mount
  point, and git stores neither a broken link's directory nor an empty
  one. A symlink whose target exists is kept; continuum ships one that
  resolves inside its own tree.

## Upstream behaviour worth knowing

- **Both plugins are bash scripts** (`#!/usr/bin/env bash`,
  `${BASH_SOURCE[0]}`, `local`, `[[ ]]`). On a userland with no bash, the
  plugin layer loads and does nothing at all, silently. `canopy doctor`
  reports bash's absence for that reason.
- **continuum disables its own autosave when a second tmux server is
  running.** `another_tmux_server_running` in `continuum.tmux` skips both
  `delay_saving_environment_on_first_plugin_load` and
  `add_resurrect_save_interpolation`, so `status-right` never gets the
  save hook. Upstream does this so two servers cannot overwrite each
  other's save file. It means "did continuum load" cannot be answered by
  looking at `status-right`; `#{continuum_status}` substitution is the
  deterministic signal, and `test/plugins.bats` uses it.
- **continuum touches `$HOME` on load.** With `@continuum-boot` off, which
  is the default, `handle_tmux_automatic_start.sh` runs the *disable*
  branch, and on macOS that is an unconditional
  `rm "$HOME/Library/LaunchAgents/Tmux.Start.plist"`. Every test here that
  starts tmux gets a scratch `$HOME` for that reason.
- **resurrect builds a save-command strategy's path out of one option, and
  does not sanitise it.** `_save_command_strategy_file` in
  `tmux-resurrect/scripts/save.sh` resolves
  `<its own tree>/save_command_strategies/<@resurrect-save-command-strategy>.sh`
  and falls back to its own `ps` strategy when that file does not exist.
  Both halves carry weight here. Because the option is interpolated
  unsanitised, a relative value reaches back out of the tree, which is how
  `plugins/strategies/canopy_save_command.sh` is reached with no patch
  against upstream at all. Because the path is checked before it is used, a
  value that ever stops resolving costs the agent rewrite and not the whole
  save. Both are asserted in `test/save_strategy.bats`, which builds the
  same path by hand and runs a real save through resurrect. If a future pin
  sanitises that option, that test is where it surfaces, and the answer is
  the recorded patch in `plugins/patches/` that §7.5 of the design provides
  for, applied by `vendor.sh`.
- **`continuum.tmux` carries a stray `set -x`** at the top, upstream, since
  the systemd-support commit. Its trace goes to the job's stderr, which
  tmux discards when the plugin is loaded from a config, so nothing is
  visible. It is noted here so nobody spends an hour rediscovering it.

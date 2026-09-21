# 02. Commands

Back to the [README](../README.md). Previous:
[01 Installation and removal](01-installation-and-removal.md).

Every command is a separate file in `bin/`, named `canopy-<name>`, carrying its own
metadata header. `canopy` itself is a dispatcher: it reads those headers to render
help, and `exec`s the matching file. `canopy index` writes the same metadata to a TSV
for later milestones to consume.

M1 ships seven: the dispatcher and six subcommands.

| Command | Summary | Group |
|---|---|---|
| [`canopy`](#canopy) | Dispatch subcommands, render help | (dispatcher) |
| [`canopy caps`](#canopy-caps) | Probe optional tool capabilities and write `05-caps.conf` | core |
| [`canopy doctor`](#canopy-doctor) | Report what is working, what is dormant, and why | core |
| [`canopy index`](#canopy-index) | Generate the command index from metadata headers | core |
| [`canopy install`](#canopy-install) | Install canopy, migrating any existing tmux config | core |
| [`canopy restore`](#canopy-restore) | Roll back transactions canopy recorded | core |
| [`canopy version`](#canopy-version) | Print the canopy version | core |

Each subcommand can also be run directly as `canopy-<name>`, provided the store's
`bin/` is on your `PATH`. The dispatcher adds two things: the lookup, and resolving the
store through a symlink to itself, which the subcommand files do not do.

Every command refuses an argument it does not recognise, with the same message shape
and the same exit code:

```
$ canopy version --shrot
canopy: canopy-version: unknown argument: --shrot
```

Exit 1, and nothing is written. The first unrecognised argument is the one named.

---

## `canopy`

```
canopy [command] [args...]
canopy help | --help | -h
```

With no argument, or with `help`, it prints one line per command, grouped and sorted:

```
$ canopy
core:
  caps         Probe optional tool capabilities and write 05-caps.conf
  doctor       Report what is working, what is dormant, and why
  index        Generate the command index from metadata headers
  install      Install canopy, migrating any existing tmux config
  restore      Roll back transactions canopy recorded
  version      Print the canopy version
```

An unrecognised command gets a suggestion based on the longest shared prefix or
substring:

```
$ canopy instal
canopy: unknown command "instal" (did you mean "install"?)
$ canopy zzz
canopy: unknown command "zzz"
```

Only files in the store's own `bin/` are dispatched. A `canopy-*` executable
elsewhere on your `PATH` is not picked up in M1.

The store is derived from the real path of `bin/canopy`: the dispatcher follows the
symlink chain of its own path before taking the parent of the directory it lands in, so
`~/.local/bin/canopy` pointing into the clone resolves the store to the clone. It then
exports `CANOPY_STORE`, so the subcommand it `exec`s inherits that rather than deriving
its own.

| Exit | Meaning |
|---|---|
| 0 | Help printed |
| 1 | `bin/canopy-<cmd>` exists but is not executable |
| 2 | No such command |
| other | Whatever the dispatched command exited with |

---

## `canopy caps`

```
canopy caps [--print]
```

Probes six optional tools and writes `$CANOPY_STATE/05-caps.conf`. Writes nothing to
stdout unless `--print` is given. The file is written to a temporary name and moved
into place, so a reader never sees a half-written file.

```
$ canopy caps --print
tmux: 3.7b
wt: yes
fzf: yes
gum: no
ghostty: no
starship: yes
mise: yes
```

The generated file, which tmux sources:

```
set -g @canopy_has_wt 1
set -g @canopy_has_fzf 1
set -g @canopy_has_gum 0
set -g @canopy_has_ghostty 0
set -g @canopy_has_starship 1
set -g @canopy_has_mise 1
set -g @canopy_tmux_version 3.7b
```

The tool list and its order are fixed in the script rather than discovered or sorted
at run time, which is what keeps the file byte-identical across machines and locales
for the same set of installed tools. `@canopy_tmux_version` is `unknown` when `tmux -V`
fails.

Run it again any time you install or remove one of those tools. `canopy install` runs
it for you.

| Exit | Meaning |
|---|---|
| 0 | Probe written |
| 1 | Unknown argument |

---

## `canopy doctor`

```
canopy doctor
```

Reports the machine, not the ledger. Takes no arguments.

```
$ canopy doctor
canopy doctor
=============

Environment:
  tmux: tmux 3.7b
  shell: /bin/sh
  store: /home/you/.local/share/canopy
  config: /home/you/.config/canopy
  state: /home/you/.local/state/canopy

Capabilities:
  wt: yes
  fzf: yes
  ...

Layers:
  worktree (wt): active
  fzf (fzf): active
  gum (gum): dormant (gum not found)
  ...

Load-bearing settings (M1):
  tmux version floor (>= 3.4): ok
  installed entry point: /home/you/.config/tmux/tmux.conf
  entry point loads from a bare environment: ok
  user.conf sourced last: ok

Restore points:
  count: 1
  pinned pre-install point: yes

Commands:
  all commands carry a summary header

Keybindings:
  cross-check stubbed for M1: the key table does not exist until M4

canopy doctor: OK
```

Sections, and what each one is actually checking:

| Section | Checks |
|---|---|
| Environment | The tmux version string and the three paths canopy resolved |
| Capabilities | A direct read of `05-caps.conf`. Doctor never re-probes; run `canopy caps` for that |
| Layers | The same data, named by feature. M1 ships no gated layer yet, so this says what each capability *will* enable |
| Load-bearing settings | tmux 3.4 floor; the installed entry point loading from a bare environment; `user.conf` being the last `source-file` in the store's `tmux.conf` |
| Restore points | How many committed points exist, whether the pinned pre-install one is among them, and any transaction interrupted before it committed |
| Commands | Every `bin/canopy-*` carries a `canopy:summary=` header |
| Keybindings | Deliberately stubbed. The key table does not exist until M4, so there is nothing to cross-reference `list-keys` against |

The entry point check is the one that matters most. It starts tmux on a throwaway
socket from an environment holding only `HOME`, `PATH` and `TMUX_TMPDIR`, and loads
the file your tmux would load. An earlier version validated the store's own
`tmux.conf` while the doctor process had `CANOPY_*` exported, and so reported OK on a
machine whose installed config loaded nothing whatsoever.

When a transaction was interrupted before it committed, doctor names it and the
command that undoes it:

```
Restore points:
  count: 1
  pinned pre-install point: yes
  INCOMPLETE transaction, interrupted before it committed: 1789742047-install
    your original files are backed up under /home/you/.local/state/canopy/backups/1789742047-install/files
    recover with: canopy restore --to 1789742047-install
```

Run that command and the warning goes. Doctor decides by comparing every path the
transaction recorded against the state it held before that transaction touched it, so
recovering by any route clears it: `canopy restore`, the transaction's own
`restore.sh`, or putting the file back by hand.

| Exit | Meaning |
|---|---|
| 0 | Everything checked passed |
| 1 | Warnings only. canopy is not installed, `caps`/`index` have not run, or a transaction needs recovery |
| 1 | Also: a bad argument, a relative `XDG_*`/`CANOPY_*` path, or an unusable runtime directory |
| 2 | A load-bearing check failed. The tmux floor, the entry point load, or `user.conf` ordering |

---

## `canopy index`

```
canopy index
```

Scans the first 40 lines of every `bin/canopy-*` file for its metadata headers and
writes `$CANOPY_STATE/commands.tsv`, sorted by group then name. Prints nothing.

Columns: `name`, `group`, `summary`, `args`, `examples`.

```
caps	core	Probe optional tool capabilities and write 05-caps.conf	[--print]	canopy caps --print
doctor	core	Report what is working, what is dormant, and why
index	core	Generate the command index from metadata headers
install	core	Install canopy, migrating any existing tmux config	[--yes] [--dry-run]	canopy install --yes
restore	core	Roll back transactions canopy recorded	[--list] [--to <id>] [--all] [--force]	canopy restore --all
version	core	Print the canopy version
```

The headers it reads, from `bin/canopy-caps`:

```sh
# canopy:summary=Probe optional tool capabilities and write 05-caps.conf
# canopy:group=core
# canopy:args=[--print]
# canopy:examples=canopy caps --print
```

A header value containing a tab or a carriage return fails the run, because it cannot
round-trip through the TSV. A missing `canopy:group=` defaults to `misc`; a missing
`canopy:summary=` is left empty and reported by `canopy doctor`.

Nothing reads `commands.tsv` yet. It exists so the palette and which-key menu in M4
can read one file instead of stat-ing thirty. `canopy install` runs it for you.

`canopy index` takes no arguments, and refuses one it does not recognise rather than
ignoring it:

```
$ canopy index --print
canopy: canopy-index: unknown argument: --print
```

| Exit | Meaning |
|---|---|
| 0 | Index written |
| 1 | A metadata value contains a tab or carriage return |
| 1 | Unknown argument |

---

## `canopy install`

```
canopy install [--yes] [--dry-run]
```

Covered in full in [01 Installation and removal](01-installation-and-removal.md).
In short:

| Flag | Effect |
|---|---|
| (none) | Install. Refuses with exit 1 if a tmux config already exists, or if canopy is already installed |
| `--yes` | Proceed with migrating an existing config |
| `--dry-run` | Print the plan, change nothing, exit 0 |

The sequence of a real run:

1. Open a transaction under `$CANOPY_STATE/backups/<epoch>-install/`.
2. Record and create `~/.config/canopy/user.conf`.
3. Record the entry point, migrate its contents into `user.conf`, write the stub.
4. Record and write `~/.config/mise/conf.d/canopy.toml`, if `mise` is present or that
   directory exists.
5. Run `canopy caps` and `canopy index`.
6. Load the entry point in a bare-environment tmux on a throwaway socket.
7. On success, commit the transaction and pin it. On failure, run the transaction's
   `restore.sh`, mark it failed, and exit 1.

Every directory install creates is recorded in the transaction's `dirs-created.txt`,
shallowest first, and removed by restore deepest first with `rmdir`. A directory that
predates canopy is never recorded, and one that still holds anything is never removed.

| Exit | Meaning |
|---|---|
| 0 | Installed, or dry run printed |
| 1 | Already installed; an existing config without `--yes`; unknown argument; validation failed and was rolled back |

---

## `canopy restore`

```
canopy restore [--list] [--to <id>] [--all] [--force]
```

Covered in full in [03 The restore guarantee](03-restore-guarantee.md).

| Invocation | Reverts |
|---|---|
| `canopy restore` | The most recent eligible transaction |
| `canopy restore --to <id>` | The named transaction and every eligible one newer than it |
| `canopy restore --all` | Every eligible transaction |
| `canopy restore --list` | Nothing. Prints the restore points, newest first |
| any of the above `+ --force` | Also reverts files you changed after canopy wrote them |

```
$ canopy restore --list
1789742071-restore  restore  2026-09-18 17:34:31  3 file(s)
1789742047-install  install  2026-09-18 17:34:07  3 file(s)  PINNED
```

Markers are `PINNED` (the pre-install point), `FAILED` (install reverted it itself),
and `INCOMPLETE` (interrupted before it committed). With no restore points at all it
prints `no restore points` and exits 0.

```
$ canopy restore --all
restore: 3 reverted, 0 kept
```

```
$ canopy restore --all
restore: 2 reverted, 1 kept
kept (changed since canopy wrote it): /home/you/.config/tmux/tmux.conf
```

Restore is idempotent. Running `--all` three times in a row leaves the machine at its
original bytes and exits 0 each time.

After a restore, canopy loads whatever tmux config it left behind, on a throwaway
socket, and reports what tmux says. A config tmux dislikes is a warning, not a
failure: what restore promises is your original bytes, and plugin-dependent configs
routinely carry lines a bare tmux rejects.

| Exit | Meaning |
|---|---|
| 0 | Everything targeted was reverted, or there was nothing to revert |
| 1 | At least one file was kept because it changed after canopy wrote it |
| 1 | Also: unknown argument, `--to` without an id, no such transaction |

---

## `canopy version`

```
canopy version
```

Prints the contents of the store's `VERSION` file and nothing else.

```
$ canopy version
0.0.0-dev
```

It takes no arguments either, and refuses one it does not recognise:

```
$ canopy version --short
canopy: canopy-version: unknown argument: --short
```

| Exit | Meaning |
|---|---|
| 0 | Version printed |
| 1 | `VERSION` not found in the store |
| 1 | Unknown argument |

---

Next: [03 The restore guarantee](03-restore-guarantee.md) ·
[04 Configuration](04-configuration.md) ·
[05 Troubleshooting](05-troubleshooting.md) ·
[06 Contributing and testing](06-contributing-and-testing.md)

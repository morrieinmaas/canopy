# 02. Commands

Back to the [README](../README.md). Previous:
[01 Installation and removal](01-installation-and-removal.md).

Every command is a separate file in `bin/`, named `canopy-<name>`, carrying its own
metadata header. `canopy` itself is a dispatcher: it reads those headers to render
help, and `exec`s the matching file. `canopy index` writes the same metadata to a TSV
for later milestones to consume.

There are ten: the dispatcher and nine subcommands. M1 shipped the `core` group,
M2 added the `agent` group.

| Command | Summary | Group |
|---|---|---|
| [`canopy`](#canopy) | Dispatch subcommands, render help | (dispatcher) |
| [`canopy caps`](#canopy-caps) | Probe optional tool capabilities and write `05-caps.conf` | core |
| [`canopy doctor`](#canopy-doctor) | Report what is working, what is dormant, and why | core |
| [`canopy index`](#canopy-index) | Generate the command index from metadata headers | core |
| [`canopy install`](#canopy-install) | Install canopy, migrating any existing tmux config | core |
| [`canopy restore`](#canopy-restore) | Roll back transactions canopy recorded | core |
| [`canopy version`](#canopy-version) | Print the canopy version | core |
| [`canopy adopt`](#canopy-adopt) | Restart agent panes in place so each one carries its own resume command | agent |
| [`canopy agent`](#canopy-agent) | Report an agent's state into its pane, and install adapters | agent |
| [`canopy reboot-check`](#canopy-reboot-check) | Say which agent panes survive a reboot, and why the rest do not | agent |

The three `agent` commands are described in full in
[07 Persistence](07-persistence.md) and [08 Agents](08-agents.md); their
reference entries are at the end of this page.

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

Plugins:
  bash (both plugins are bash scripts): yes
  ps (agent panes are recognised through it): yes
  tmux-resurrect: pinned cff343cf9e81983d3da0c8562b01616f12e8d548, tree matches
  tmux-continuum: pinned 0698e8f4b17d6454c71bf5212895ec055c578da0, tree matches

Load-bearing settings:
  tmux version floor (>= 3.4): ok
  installed entry point: /home/you/.config/tmux/tmux.conf
  entry point loads from a bare environment: ok
  @continuum-restore is on: ok
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
| Plugins | Each vendored plugin's pinned commit from `plugins/VERSIONS`, and whether the tree on disk still matches the digest `plugins/vendor.sh` recorded in `plugins/CHECKSUMS`. Also whether `bash`, which both plugins need, is present at all, and whether this machine's `ps` can report a process's parent, which is how an agent pane is recognised. `ps` is probed by running it: BusyBox ships one that exists and cannot answer |
| Load-bearing settings | tmux 3.4 floor; the installed entry point loading from a bare environment; `@continuum-restore` being on in the config this machine actually loads, without which a reboot restores nothing; `user.conf` being the last `source-file` in the store's `tmux.conf` |
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
0.1.0
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

## `canopy config`

```
canopy config [--all] [--defaults]
```

Prints every tmux option canopy sets, grouped, with the value your tmux holds
right now beside the value canopy ships. A `*` in the left margin marks the ones
that differ.

```
$ canopy config
status:
    @canopy_status_battery             on                           on
    @canopy_status_net                 on                           on
  * @pill_l                                                     
  * @pill_r                                                     

theme:
  * @theme_bg                          #faf6f0                      #fbf1c7
    @theme_red                         #cc241d                      #cc241d

persistence:
    @continuum-restore                 on                           on
    @resurrect-dir                     /home/you/.local/state/canopy/resurrect
    @resurrect-processes               claude "~^sleep [0-9.]* && claude" (generated: from installed adapters)
  * @canopy_resume_stagger_ms          (unset, default applies)     1000

9 option(s) marked * hold something other than the shipped default.
Override any of these in /home/you/.config/canopy/user.conf, which canopy sources last.
```

| Flag | Effect |
|---|---|
| `--all` | Include the `internal` group, which is hidden by default: options that carry no setting, only a fact canopy needs to remember about itself |
| `--defaults` | Print the table without consulting tmux at all. Every live value reads `?` |

The options are declared once, in
[`tmux/options.tsv`](https://github.com/morrieinmaas/canopy/blob/main/tmux/options.tsv),
and read from there rather than from a list inside the command, so the two
cannot disagree. A test asserts that every `set -g @…` in the shipped layers
appears in that table with the same default, which is what keeps it honest as
the layers change.

**What an unset option means depends on where its default lives**, and that is
the one part of this output worth knowing. The table records a source per option:

| Source | Unset means | Marked? |
|---|---|---|
| `layer` | A `conf.d` layer sets it, so unset means that layer did not load | Yes, that is a setting which did not take |
| `code` | The default is in a script, and the option is normally unset | No, unset is the default being in effect |
| `generated` | Computed at load from what is on the machine, so there is no fixed value to compare | Never |

`@canopy_resume_stagger_ms` is the `code` one: its default lives in
`lib/resume.sh` because it is read from inside a save, which has nobody to
report a bad value to.

Live values come from a single `tmux display-message` call rather than one per
option. Two dozen options asked separately is two dozen processes, for a command
somebody runs while wondering why their status bar looks wrong.

No tmux server running is a normal case here, not an error: you may well be
reading this to decide what to put in `user.conf` before starting tmux at all.
The command says so and prints the defaults. It does not start a server to
answer.

| Exit | Meaning |
|---|---|
| 0 | Table printed, with or without live values |
| 1 | No options table in the store |
| 1 | A table row has other than five columns, or an unknown source |
| 1 | Unknown argument |

---

## `canopy keys`

```
canopy keys [--print]
```

Reads the key table, `$CANOPY_STORE/tmux/keys.tsv`, and writes
`$CANOPY_STATE/10-keys.conf`, the layer tmux sources for every binding canopy
ships. Prints nothing. `--print` writes nothing and prints the table as a
cheatsheet, grouped, to stdout.

The table is tab-separated, six columns, and is the single declaration of every
binding canopy ships:

```
# name	key	flags	command	group	description
split-right	|	-	split-window -h -c "#{pane_current_path}"	pane	Split to the right, in the directory this pane is in
pane-wider-left	H	-r	resize-pane -L 5	pane	Grow the pane leftwards, repeatable
```

`flags` is `-` for none, or tmux's own bind flags; `-r` makes the binding
repeatable. `group` is what a menu would group the row under. `description` is
written for somebody who does not already know what the key does.

The point of the table is that there are no orphan keys. A binding that exists
only as a `bind` line somewhere has no name, no group and no description, so it
can never appear in a cheatsheet, a palette or a which-key menu, and the table
quietly stops being the truth. Everything canopy binds goes through here, and
M4's surfaces read this same file rather than a second copy of it.

Two things are deliberately not in the table. `prefix` itself, because it is an
option rather than a binding and belongs to `00-core.conf`; and any binding a
user adds, which belongs in `user.conf` and is theirs.

`canopy install` runs this for you. After editing the table, regenerate and
reload:

```sh
canopy keys && tmux source-file ~/.config/tmux/tmux.conf
```

`canopy doctor` compares the table's row count against the generated layer and
reports a layer that was not regenerated after the table grew.

| Exit | Meaning |
|---|---|
| 0 | Layer written, or table printed |
| 1 | No key table in the store |
| 1 | A row has other than six columns, or an empty column |
| 1 | Two rows declare the same key, or the same name |
| 1 | Unknown argument |

---

## `canopy status`

```
canopy status [--plain]
```

Renders the right-hand end of the status line and prints it, styled with tmux
format escapes. `--plain` prints the same segments with no styling, which is what
to use when checking it by eye.

It exists to be the *only* `#()` call in the status line. A status line with four
`#()` segments forks four processes every `status-interval`, forever, on every
machine; this is one process that renders all of them, and it reads everything it
needs from tmux in a single `display-message` call rather than once per segment.
Everything else in `20-status.conf` is a pure `#{...}` token, which costs nothing.

Segments render right to left: network, battery, date, clock. A segment with
nothing to say prints nothing at all, so its pill disappears rather than showing a
placeholder.

Two options gate the two segments that can be unwanted, and both default to on:

```tmux
set -g @canopy_status_battery off   # a desktop has no battery worth a pill
set -g @canopy_status_net off
```

Colour is data: every colour comes from an `@theme_*` option
(`@theme_bg`, `@theme_fg`, `@theme_blue`, `@theme_green`, `@theme_grey`,
`@theme_red`) and the pill glyphs from `@pill_l` and `@pill_r`. Set those in
`user.conf` and the whole line repaints, without touching this command. M5's theme
layer is built on exactly that.

| Exit | Meaning |
|---|---|
| 0 | Rendered |
| 1 | Unknown argument |

---

## `canopy adopt`

```
canopy adopt [--yes|--dry-run]
```

Restarts an agent pane in place as its own resume command, so the pane's own
command carries the session id rather than only a tmux pane option.

Dry run is the default; `--dry-run` says so explicitly and means the same. It
kills and restarts live processes, so every guard fails closed: a pane is
restarted only when the agent reported a session id, the adapter has a usable
resume command, the reported state is `idle` or `completed`, and the adapter
says the pane holds **no** unsent input. Anything else is skipped and named.

A pane already running its resume command counts as adopted, including one you
started that way yourself, so a second run never kills what the first fixed.

| Exit | Meaning |
|---|---|
| 0 | every agent pane now carries its own resume command, or there were none |
| 1 | at least one pane was left as it was, each named with the reason |
| 1 | Unknown argument |

Guards, limits and why a Claude Code pane is always skipped:
[07 Persistence](07-persistence.md#canopy-adopt).

## `canopy agent`

```
canopy agent report <state> [--source <id>] [--session-id <id>]
canopy agent install <adapter-id>
```

`report` writes an agent's state into the pane it is running in, as four tmux
pane options. It is called by an agent's own hooks, not by hand. The five
states are `idle`, `working`, `blocked`, `completed` and `exited`. With no
`$TMUX_PANE`, or a pane that has gone away, it exits 0 and writes nothing: a
hook that fails is a hook that interrupts your work to report something you
cannot act on. A state outside the five is a bug in the adapter and is
reported as one.

`install` puts an adapter's hooks into that agent's own configuration, inside
a transaction, so `canopy restore` can put the configuration back byte for
byte. It refuses an adapter with no installer rather than guessing where an
agent keeps its config.

| Exit | Meaning |
|---|---|
| 0 | Reported, or installed |
| 1 | A state outside the five, a malformed call, or an adapter that cannot be installed |
| 1 | Unknown argument |

See [08 Agents](08-agents.md).

## `canopy reboot-check`

```
canopy reboot-check
```

Says which agent panes will survive a reboot and why the rest will not, read
off what tmux-resurrect actually saved rather than off what canopy intended to
save.

| Exit | Meaning |
|---|---|
| 0 | every agent pane will resume, or no tmux server is running |
| 1 | at least one pane will not come back with its conversation |
| 2 | persistence is misconfigured, and no per-pane verdict is worth giving |
| 1 | Unknown argument |

Per-pane verdicts and what each one means:
[07 Persistence](07-persistence.md#canopy-reboot-check).

---

Next: [03 The restore guarantee](03-restore-guarantee.md) ·
[04 Configuration](04-configuration.md) ·
[05 Troubleshooting](05-troubleshooting.md) ·
[06 Contributing and testing](06-contributing-and-testing.md)

# 05. Troubleshooting

Back to the [README](../README.md). Previous: [04 Configuration](04-configuration.md).

Organised by what you see. Start with `canopy doctor`; it checks the artifact your
tmux actually loads, from the environment your tmux actually has.

---

## I want my old config back, right now

```sh
canopy restore --all
```

That is the whole answer when canopy works. Every file that existed before canopy
goes back to its exact original bytes.

If `canopy` itself will not run, every restore point carries a script that depends on
nothing:

```sh
ls ~/.local/state/canopy/backups/
sh ~/.local/state/canopy/backups/<id>-install/restore.sh
```

Pick the `-install` transaction with the earliest timestamp. It is the pre-install
point, the one `canopy restore --list` marks `PINNED`. That script needs no canopy, no
store, no `PATH` entry, and no `mise`. See
[03 The restore guarantee](03-restore-guarantee.md#the-escape-hatch-restoresh).

---

## Nothing loaded. tmux looks exactly as it did before

Check what tmux is loading, and whether it loads at all:

```sh
canopy doctor
```

Look at this line:

```
  installed entry point: /home/you/.config/tmux/tmux.conf
  entry point loads from a bare environment: ok
```

| What you see | What it means | Fix |
|---|---|---|
| `installed entry point: none, canopy is not installed` | No `~/.tmux.conf` and no `~/.config/tmux/tmux.conf` exists | `canopy install` |
| `entry point loads from a bare environment: FAILED` | tmux rejects something in the chain. The offending line is printed under it | See the next section |
| Both lines fine, but tmux still looks unchanged | You have a tmux server running from before the install | `tmux source-file ~/.config/tmux/tmux.conf`. A server started before the install has not read the new file, and `set-environment` only reaches servers started after it, so a fully fresh server (`tmux kill-server`, which ends every session) is the last resort |

Two other causes of "nothing loaded":

**You have a `~/.tmux.conf` that canopy did not take over.** tmux prefers
`~/.tmux.conf` over the XDG path. `canopy doctor` prints which file it validated; if
that is not the one tmux loads on your machine, they have diverged.

**You symlinked one of the `bin/canopy-*` files rather than `bin/canopy`.** The
dispatcher follows the symlink chain of its own path before deriving the store, so a
symlink to `bin/canopy` is fine. The subcommand files do not: each derives its store
from `$(dirname "$0")/..`, so a symlink to `bin/canopy-doctor` resolves the store to
the link's parent's parent and fails to find `lib/env.sh`. Symlink the dispatcher, or
put the clone's `bin/` on your `PATH`.

---

## `canopy doctor` exits 2

Exit 2 means a load-bearing check failed. One of four:

### `tmux version floor (>= 3.4): FAILED`

canopy needs tmux 3.4 or newer. Check with `tmux -V`. Nothing canopy can do about
this; upgrade tmux.

### `entry point loads from a bare environment: FAILED`

The failing tmux line is printed right underneath:

```
  entry point loads from a bare environment: FAILED
    /home/you/.config/canopy/user.conf:12: unknown command: totally-not-a-real-command
```

Almost always this is a line in your own `user.conf`, migrated from your previous
config, that depended on a plugin or a newer tmux. Edit `~/.config/canopy/user.conf`
and re-run `canopy doctor`.

Note what "bare environment" means. Doctor starts tmux with only `HOME`, `PATH` and
`TMUX_TMPDIR` set, on a throwaway socket, so it sees what a freshly started tmux
sees, not what your interactive shell has. A config that works in your shell but
fails here is relying on a variable nothing sets for the tmux server.

### `@continuum-restore is on: FAILED`

The config your machine actually loads leaves continuum's restore off, so a reboot
would replay nothing: every save canopy writes would be read by no one. canopy's own
layer sets it on, so something after that turned it off, and the only thing sourced
later is your `user.conf`. Put it back with:

```
set -g @continuum-restore on
```

in `~/.config/canopy/user.conf`, or remove whatever unset it there.

This is read off the entry point your tmux loads rather than off canopy's layer
files, precisely so that a `user.conf` override is caught here instead of after a
reboot. It is not checked at all when the entry point does not load, because a
config tmux refused has no loaded value to report.

### `user.conf sourced last: FAILED`

The store's `tmux/tmux.conf` has been edited so that something is sourced after
`user.conf`. Your overrides would silently stop winning. Restore the store with
`git -C ~/.local/share/canopy checkout tmux/tmux.conf`.

---

## `canopy doctor` exits 1

Exit 1 is warnings only. The machine works. Common causes:

| Line | Fix |
|---|---|
| `not yet generated (run: canopy caps)` | `canopy caps` |
| `not yet generated (run: canopy index)` | `canopy index` |
| `installed entry point: none, canopy is not installed` | `canopy install` |
| `INCOMPLETE transaction, interrupted before it committed` | See the next section |
| `missing summary header: canopy-<name>` | A command file in `bin/` lacks a `# canopy:summary=` line. Only relevant if you added one |

Exit 1 is also what canopy uses for a hard refusal: an unknown argument, a relative
`XDG_*` or `CANOPY_*` path, or a runtime directory it will not use.

---

## An install was interrupted

Killed partway through, canopy leaves a transaction with recorded rows and no
`.committed` marker. Your original bytes are in that transaction's `files/`. Doctor
finds it and names the command:

```
Restore points:
  count: 1
  pinned pre-install point: yes
  INCOMPLETE transaction, interrupted before it committed: 1789742047-install
    your original files are backed up under /home/you/.local/state/canopy/backups/1789742047-install/files
    recover with: canopy restore --to 1789742047-install
```

Run that. Doctor then stops warning, because it compares every recorded path against
the state it held before that transaction touched it, rather than looking for a
marker. Recovering by running the transaction's own `restore.sh`, or by putting the
file back by hand, clears it just the same.

One thing to know: rows of an uncommitted transaction have no recorded post-state, so
there is nothing to compare your current bytes against and they are reverted without
a hash guard. Restore says so, names every such path, and tells you the restore id
that brings the overwritten bytes back:

```
reverted without a hash guard, that transaction never committed so canopy never recorded what it left on disk: /home/you/.config/tmux/tmux.conf
the bytes overwritten above were backed up first; recover them with: canopy restore --to 1789742071-restore
```

---

## `canopy restore` says a file was kept

```
restore: 2 reverted, 1 kept
kept (changed since canopy wrote it): /home/you/.config/tmux/tmux.conf
```

Exit status 1. That file holds neither what canopy wrote nor your original bytes, so
you edited it after install and restore will not throw the edit away.

| You want | Do |
|---|---|
| To keep the edit | Copy it somewhere else, then re-run `canopy restore --all` |
| To discard the edit | `canopy restore --all --force`. The current bytes are backed up into a new restore point first, and the summary names its id |

---

## `canopy install` refuses

| Message | Meaning |
|---|---|
| `owning <path> is a migration, not a merge; re-run with --yes to proceed` | You already have a tmux config. Run `canopy install --dry-run` to see the plan, then `canopy install --yes` |
| `canopy is already installed: <path> already sources canopy's tmux.conf` | Nothing to do. To reinstall, `canopy restore --all` first |
| `the resulting tmux config failed validation; installation rolled back` | The config canopy assembled does not load. Your original files are already back; nothing was committed. Usually a line in the config it migrated |

---

## `canopy: runtime directory ... refusing to use it`

canopy's scratch directory falls back to `/tmp/canopy-<uid>` when `XDG_RUNTIME_DIR` is
unset, and `/tmp` is writable by every account on the machine. canopy creates that
directory mode 0700 and refuses to use one it does not exclusively own.

| Message | Cause |
|---|---|
| `is writable by group or other (mode 777)` | Something else created it first, or its mode was widened |
| `is owned by uid N, not by you` | Another account created it first |
| `is a symlink` / `exists and is not a directory` | Something was planted at that path |

If you are the only user of that machine and you recognise the directory as your own
leftover, remove it and let canopy recreate it:

```sh
rm -rf /tmp/canopy-$(id -u)
canopy doctor
```

If you did not create it, do not delete it blind. Find out who did. Or sidestep it
entirely:

```sh
CANOPY_RUNTIME="$HOME/.cache/canopy" canopy doctor
```

---

## `canopy: unknown command`

```
$ canopy instal
canopy: unknown command "instal" (did you mean "install"?)
```

Exit 2. `canopy help` lists everything that exists. M1 has six subcommands; anything
from the design document describing agents, themes, the palette or worktrees is not
implemented yet. See the milestone table in the [README](../README.md#status-milestone-1-of-six).

---

## My agent panes came back empty after a reboot

The panes are there, the agents are running, but each one started a fresh
conversation instead of continuing the one it had.

Run `canopy reboot-check` **before** the next reboot rather than guessing. It
reads what was actually saved and names, per pane, why a pane will not come
back. In order of how often each cause is the real one:

1. **No session id was reported for the pane.** The agent's hooks are not
   installed, or are not firing. Check with
   `tmux display-message -p '#{@canopy_agent_session}'` inside the pane: empty
   means nothing has reported. `canopy agent install claude-code` installs the
   hooks; they fire on the agent's next start, not retroactively.
2. **The pane was not in the last save.** `reboot-check` says `not saved yet`.
   continuum's default autosave interval is 15 minutes, and a save rides on a
   status-line redraw, so a server nothing is attached to may not save at all.
3. **The restore path is off.** `reboot-check` says
   `continuum restore at server start: off` and refuses to give a per-pane
   verdict. canopy sets `@continuum-restore on`; something in your
   `user.conf` turned it back off, because `user.conf` is sourced last and
   wins. `canopy doctor` exits 2 for this.
4. **Another tmux server was running at boot.** continuum refuses to restore
   while one is. `reboot-check` says so when it sees one.

## `canopy reboot-check` says there are no agent panes, but there are

Almost always this machine's `ps`. canopy recognises an agent pane by asking
`ps` what the pane's process is running; where `ps` cannot answer, no pane is
ever recognised as an agent, every save records a shell, and this command
reports a machine full of agents as empty.

```sh
canopy doctor | grep '^  ps'
```

`dormant` there means exactly this. A BusyBox `ps` cannot answer, and many
slim container images ship no `ps` at all. Install your distribution's
`procps`. canopy will not install it for you.

The other possibility is that the agent in the pane has no adapter, so canopy
has nothing to match its command against. Only Claude Code ships today.

## `canopy adopt` skips every pane

Read the reason it printed against each one; `adopt` never skips silently.

The most common reason is not a fault: **a Claude Code pane is always
skipped.** Claude Code exposes no way to ask whether a pane is holding a
message somebody typed and has not sent, so its adapter leaves `detect_draft`
empty, which means "undetermined", which `adopt` treats exactly like "yes,
there is unsent input". Restarting such a pane would destroy a draft that
exists in no file anywhere, so it fails closed instead.

`the agent is mid task` means the agent last reported `working` or `blocked`.
Wait for it to finish. `no session id has been reported` means there is
nothing to resume, and nothing `adopt` can do: minting a fresh id would pin
the pane by throwing away the conversation it currently holds.

## Persistence does nothing at all, and doctor mentions bash

Both vendored plugins are `#!/usr/bin/env bash` scripts. Without `bash` the
plugin layer loads nothing: no key binding, no autosave, no restore. This is
the normal state of an Alpine or other BusyBox userland, and `canopy doctor`
reports it under **Plugins** as dormant.

Install `bash`. canopy will not install it for you, and it deliberately does
not rewrite upstream's scripts.

## Something is wrong and I do not trust any of this

The state canopy keeps is three things, and you can inspect all of them with `cat`:

```sh
cat ~/.config/tmux/tmux.conf                      # the stub, absolute paths, no magic
cat ~/.config/canopy/user.conf                    # yours
cat ~/.local/state/canopy/05-caps.conf            # generated flags
cat ~/.local/state/canopy/backups/<id>/manifest.tsv   # exactly what was touched
```

The manifest names every path canopy changed, what it was before, and what it became.
Nothing canopy did is hidden from it.

---

Next: [06 Contributing and testing](06-contributing-and-testing.md) ·
[07 Persistence](07-persistence.md) ·
[08 Agents](08-agents.md)

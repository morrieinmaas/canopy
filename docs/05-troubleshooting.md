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

**You symlinked `bin/canopy` into `/usr/local/bin`.** canopy resolves its store from
the path of the running script, so a symlinked entry resolves the store to
`/usr/local` and sources nothing. Put the real clone directory on your `PATH` instead.

---

## `canopy doctor` exits 2

Exit 2 means a load-bearing check failed. One of three:

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

Next: [06 Contributing and testing](06-contributing-and-testing.md)

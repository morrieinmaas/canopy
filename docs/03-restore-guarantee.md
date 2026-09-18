# 03. The restore guarantee

Back to the [README](../README.md). Previous: [02 Commands](02-commands.md).

This is canopy's central idea. Everything else in the project is downstream of it.

> `canopy restore --all` returns every file that existed before canopy to its exact
> original bytes.

Not "your config is backed up somewhere". The exact bytes, at the exact path, with
the exact type: a regular file comes back a regular file, a symlink comes back the
same symlink pointing at the same target, a file that did not exist comes back to not
existing, and a directory canopy created comes back to not existing while one that
predates canopy is left alone with everything in it.

The promise holds no matter how many operations have run since. It is checked in CI,
on two operating systems and in two container userlands, on every push. See
[06 Contributing and testing](06-contributing-and-testing.md).

## Transactions

Every operation that writes to a file you own opens a transaction first. In M1 that
means `canopy install` and `canopy restore` itself.

A transaction is a directory:

```
~/.local/state/canopy/backups/1789742047-install/
  manifest.tsv         one row per recorded path
  files/               byte copies of everything that existed before
  restore.sh           self-contained POSIX sh, depends on nothing
  dirs-created.txt     directories this run created, shallowest first
  .committed           written when the operation finished
  .pinned              written on the pre-install point only
```

The id is `<epoch>-<label>`. Two transactions beginning in the same second get a
`.2`, `.3` suffix, allocated with `mkdir`, which succeeds exactly once for a given
path.

The order inside a transaction is always: **record the old bytes, then change the
file.** A copy of the original is on disk before anything touches the original.

## What a restore point contains

### `manifest.tsv`

Tab-separated, five columns, one row per recorded path.

| Column | Values |
|---|---|
| `action` | `own`, `splice`, `drop`, `generate`, `env`. M1 uses `own` (taking over an existing file) and `drop` (creating one that was not there) |
| `path` | The absolute path, verbatim |
| `pre` | `absent`, or `symlink:<target>`, or the sha256 of the file's bytes |
| `backup_rel` | `-` when `pre` is `absent`, else `files/<mangled>.<ordinal>` |
| `post` | The same vocabulary as `pre`, stamped at commit time. Empty when the transaction never committed |

A real row, from an install over an existing config:

```
own	/home/you/.config/tmux/tmux.conf	9f3a3d…	files/%2Fhome%2Fyou%2F.config%2Ftmux%2Ftmux.conf.2	caa49e…
```

A path containing a tab or a newline fails the record with an error, rather than
writing a row that cannot round-trip and would be silently misparsed months later
when someone actually needs it.

### `files/`

One byte copy per manifest **row**, not per path, copied with `cp -pP`. The filename
is the path with `%` encoded as `%25` and `/` as `%2F`, then `.` and the row's
ordinal. Fixed-width encoding, so `/%` and `%/` can never mangle to the same name.
The ordinal is what stops a second row for the same path from clobbering the first
row's backup.

`-P` matters: a symlink is copied as the link it is, never as a copy of whatever it
points at. The link is the artifact canopy took over. The file at the other end is
one canopy never recorded and must not touch.

### `dirs-created.txt`

Every directory level this run actually created, shallowest first. A level that
already existed is never recorded, which is what keeps restore from removing a
directory that predates canopy. Restore reads it back in reverse so the deepest goes
first and each removal can make its parent empty in turn, and uses `rmdir`, never
`rm -r`, so a directory still holding anything is kept.

### Markers

| Marker | Meaning | In automatic rollback? | In `--list`? | Reachable by `--to`? |
|---|---|---|---|---|
| `.committed` | The operation finished and stamped every `post` column | yes | yes | yes |
| `.pinned` | The pre-install point | yes | yes, as `PINNED` | yes |
| `.failed` | Install's own validation failed and install already reverted this itself | no | yes, as `FAILED` | yes |
| `.rollback` | This transaction is a restore's own record | no | yes | yes |
| none | Interrupted before it committed | yes | yes, as `INCOMPLETE` | yes |

Two exclusions, both deliberate. A `.failed` transaction was already reverted by
install, so replaying it would be noise. A `.rollback` transaction holds canopy's
bytes, so replaying it is the exact opposite of what `--all` promises, and it
compounds: each run would record over the last and the rows to replay would double.
Reverting a revert is a legitimate thing to want, which is why both stay visible and
`--to <id>` still reaches them. It is an explicit request, never part of "undo
everything canopy did".

An **interrupted** transaction is included, not skipped. No `.committed` marker means
canopy was killed partway through, so partial changes are sitting on disk and your
original bytes are sitting in its `files/`. That is precisely what rollback exists
for.

## The pinned pre-install point

`canopy install` writes `.pinned` on its transaction after a successful commit. It is
the point that returns the machine to the state it was in before canopy existed, and
it is never pruned.

M1 does not prune anything at all. There is no `@canopy_backup_keep` and no retention
policy yet; every restore point stays until you delete `~/.local/state/canopy`
yourself.

## Two rollback classes

| Class | What | Rule |
|---|---|---|
| **A: config mutations** | Anything canopy does to a file you own, or to a path in a config directory you own. In M1: the tmux entry point, `~/.config/canopy/user.conf`, `~/.config/mise/conf.d/canopy.toml`, and every directory created to hold them | Byte-captured before the change. Completely reversible, forever |
| **B: canopy-owned state** | `05-caps.conf`, `commands.tsv`, `backups/`. None of it existed before canopy | Not transacted, because there is nothing to put back. Changes here can only be forward-only, which is harmless |

The categories exist so that later milestones cannot quietly move something from B to
A. A migration that needs to write a user-owned file has to open a config transaction
and becomes Class A. M1 ships no migrations, so there is nothing enforcing that yet
beyond the design rule.

## How restore decides what to touch

Transactions are replayed **newest first**. That ordering is load-bearing and
invisible with a single transaction. If one operation took a file from original to
v1, and a later one from v1 to v2, replaying newest first puts v1 back and then the
original. Replaying oldest first would find v2 where the first transaction expected
v1, keep the row, and leave canopy's bytes on disk instead of yours.

For each row:

| Situation | What restore does |
|---|---|
| The file still holds what canopy left (`current == post`) | Revert it |
| The file already holds its original bytes (`current == pre`) | Revert it, which is a no-op. This is what makes `restore --all` idempotent |
| The file holds something else, and the transaction committed | **Keep it.** Name it in the summary, exit 1 |
| The file holds something else, and `--force` was given | Revert it, after copying the current bytes into this restore's own transaction |
| The transaction never committed, so `post` is empty | Revert it without a guard, and name the path in the summary along with the restore id that brings the overwritten bytes back |

The guard exists to protect bytes **you** wrote after canopy did. A file already
holding its own `pre` bytes is not that, it is a row that has already been reverted.
Without that clause a second `restore --all` read the first run's work as an edit it
must refuse to touch, and reported your original bytes as "changed since canopy wrote
it".

Restore is itself non-destructive. It opens its own transaction before touching
anything, so whatever it overwrites is recoverable:

```
$ canopy restore
restore: 2 reverted, 0 kept
reverted without a hash guard, that transaction never committed so canopy never recorded what it left on disk: /home/you/.config/tmux/tmux.conf
reverted without a hash guard, that transaction never committed so canopy never recorded what it left on disk: /home/you/.config/canopy/user.conf
the bytes overwritten above were backed up first; recover them with: canopy restore --to 1789742071-restore
```

## After a restore

canopy loads whatever tmux config it left behind, on a throwaway socket, from a bare
environment, and reports what tmux says about it.

This is a warning, never a failure. What restore promises is your original bytes
back, and once they are back, whether the config loads cleanly is your business.
Plugin-dependent and version-dependent configs routinely carry lines a bare tmux
rejects. Exiting non-zero here once told people a byte-perfect restore had failed,
directly under a summary reading `0 reverted, 0 kept`. Non-zero is reserved for a
restore that did not restore.

## The escape hatch: `restore.sh`

Every transaction directory contains a `restore.sh` that reverts that transaction and
depends on nothing outside its own directory. No store, no dispatcher, no `lib/`, no
`mise`, no `canopy` on your `PATH`. It reads `manifest.tsv` and `files/` relative to
its own location, resolved with `dirname "$0"`.

```sh
sh ~/.local/state/canopy/backups/1789742047-install/restore.sh
```

```
restore: 1 file(s) restored, 2 file(s) removed
```

This is the tool for when canopy itself is what broke. A rollback tool that needs the
thing it is rolling back is not a rollback tool. You can copy a transaction directory
to a USB stick, delete the entire canopy clone, and run its `restore.sh` from
anywhere; it puts your files back.

What it does not do, which `canopy restore` does:

- no hash guard, so it reverts a file you edited after canopy wrote it, without asking
- no restore point of its own, so those bytes are not recoverable afterwards
- no tmux validation of the result
- no summary beyond two counts

Use `canopy restore` when canopy works. Use `restore.sh` when it does not.

## What restore does not do

- It never touches `~/.config/canopy` beyond the files it recorded. Your own overrides
  in there survive, and keep the directory alive with them.
- It never removes `~/.local/state/canopy`. That is where the restore points live.
- It never touches a running tmux server. The verification runs on a throwaway socket.
- It never follows a symlink to write through it. Whatever is at a path is removed
  first, then the recorded artifact is copied back with `cp -pP`.

---

Next: [04 Configuration](04-configuration.md) ·
[05 Troubleshooting](05-troubleshooting.md) ·
[06 Contributing and testing](06-contributing-and-testing.md)

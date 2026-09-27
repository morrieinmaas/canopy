# 06. Contributing and testing

Back to the [README](../README.md). Previous: [05 Troubleshooting](05-troubleshooting.md).

## The rule that matters most

> **Every verification runs the shipped artifact through the same entry path a user
> does, from a bare environment.**

Read that once more before you write a test, because it is the most expensive lesson
this project has learned.

Milestone 1 reached 93 green tests, a passing restore proof and a clean lint while the
configuration it installed **loaded nothing at all on a real machine.**

The entry point canopy wrote expanded `$CANOPY_STORE` inside a `source-file` path.
tmux expands such a variable from the tmux **server's** environment. Nothing outside
tmux ever puts `CANOPY_*` there, so on a real machine that line resolved to nothing
and the whole config tree was silently skipped. Every test passed because every test
exported `CANOPY_STORE` before invoking anything. The verification ran in a richer
environment than any user will ever have.

The fix is not "more tests". It is that at least one layer of verification must hold
nothing the user does not hold:

- no `CANOPY_*` in the environment
- no test helper sourced
- no store path assumed
- the shipped `canopy` found on `PATH`, invoked by name
- tmux started with `env -i`, carrying only `HOME`, `PATH` and `TMUX_TMPDIR`

Unit tests may use conveniences for speed. The acceptance scenarios may not.
`test/smoke/scenarios.sh` enforces this on itself: it unsets every `CANOPY_*`, then
greps its own environment and refuses to start if one survived.

A milestone is not complete when its code exists and its unit tests pass. It is
complete when its container scenario passes.

## Toolchain

The repo declares its tools in `mise.toml`:

```toml
[tools]
bats = "latest"
jq = "latest"
shellcheck = "0.11.0"
shfmt = "latest"
tmux = "latest"
```

`shellcheck` is pinned rather than `"latest"`: an unpinned version resolved to a stale
install locally while CI resolved a fresh one on every run, and the fresh one
implemented a check the stale one did not, so the same lint passed locally and failed
in CI. Bump the pin deliberately, run `test/lint.sh`, and commit the result.

```sh
mise install
```

Nothing in there is needed to *use* canopy, which runs on `sh` and `tmux` alone. It is
for working on it.

`mise.toml` also declares the tasks, which is how the same string a contributor types
is the string CI runs:

```sh
mise run lint     # shellcheck and shfmt over every shipped script
mise run test     # the bats suite
mise run proof    # install, mutate, restore, compare hashes
mise run smoke    # container acceptance scenarios (needs docker or podman)
mise run check    # lint, test and proof together
mise run vendor tmux-resurrect   # re-vendor a pinned plugin
```

`mise run test test/doctor.bats` runs one file and `mise run smoke arch` one image:
both tasks template their argument rather than appending it, so naming a target
replaces the default instead of running the default and then the target.

## The three suites

| Suite | Command | Runs where | Covers |
|---|---|---|---|
| Unit | `mise run test` | macOS and Ubuntu in CI | Libraries and every command, with conveniences |
| Restore proof | `mise run proof` | macOS and Ubuntu in CI | The headline guarantee, three scenarios |
| Container acceptance | `mise run smoke` | Linux in CI, one job per image | Eight scenarios, in four userlands, from a bare environment |

### Unit suite

```sh
mise run test
```

Over 330 tests. Each one gets its own `$HOME`, `$XDG_CONFIG_HOME` and `CANOPY_*` under
`$BATS_TEST_TMPDIR`, via `setup_canopy_env` and `setup_canopy_home` in
`test/helper.bash`. Never the real `$HOME`, and never the default tmux socket: every
tmux invocation in the suite carries `-L <scratch-socket>` and cleans up after itself.

To run one file:

```sh
mise run test test/restore.bats
```

### Restore proof

```sh
mise run proof
```

Three scenarios, each covering a leak class the others structurally cannot see:

| # | Scenario | What only it can catch |
|---|---|---|
| 1 | A `$HOME` with real tmux, ghostty and starship configs, canopy's own state outside it | A canopy artifact surviving under `$HOME` |
| 2 | An empty `$HOME` with canopy's config and state inside it, the real default layout | A directory install created from nothing (`~/.config`, `~/.config/canopy`) that restore fails to remove |
| 3 | A `tmux.conf` that is a symlink to a target outside `$HOME` | Install writing through the link into a dotfiles repo, which lives in no listing the other two take |

Each records `find` output **including directories** plus a sha256 per file, installs,
restores, and diffs both. A file-only listing would miss a surviving directory, which
is why the listing is not filtered.

It runs entirely inside a `mktemp -d` scratch tree and never touches your real `$HOME`.

### Container acceptance

```sh
mise run smoke                      # all four images
mise run smoke debian               # one image
DOCKER=podman sh test/smoke/run.sh  # another container CLI
```

Needs a container daemon. Builds four images and runs every scenario in each, then
prints one matrix:

```
image     id    result  scenario
debian    1     PASS    virgin machine
debian    2     PASS    machine with existing configs
debian    3     PASS    symlinked tmux config
debian    4     PASS    idempotence and recovery
debian    5     PASS    dangling symlink at the entry point
debian    6     PASS    two user accounts on one machine
alpine    1     PASS    virgin machine
...

12 scenario result(s), 0 failed
```

Each image is here for something specific it catches:

| Image | `/bin/sh` | Userland | Here for |
|---|---|---|---|
| `debian:stable-slim` | dash | GNU | A bashism that bash on macOS and bats accept |
| `alpine:latest` | BusyBox ash | BusyBox | A GNU-only flag in `find`, `grep`, `sed`, `cp`, `date` or `stat` |
| `fedora:latest` | bash | GNU | The RPM half of the world, and one of the two Linux platforms canopy is installed on |
| `archlinux:base` | bash | GNU | Rolling, so the newest tmux, coreutils and git: where a changed default shows up first |

The first two are the portability net. The last two are the "does it work where it is
actually used" check, and they are the reason the matrix is not a claim about Linux in
general made from two Debian-family images.

canopy is developed on macOS with GNU coreutils on the `PATH`, so neither of the first
two risks was tested anywhere before this harness existed.

### Emulation can fail these scenarios, and it looks like a canopy bug

An image of the wrong architecture for the host runs under emulation, and some
emulated setups have `ps` report the emulator rather than the process:

```
$ ps -o args= -p $!
/usr/bin/qemu-x86_64-static /bin/sleep sleep 30
```

canopy recognises an agent pane by the command name `ps` reports, so where that
happens **no pane is ever recognised as an agent**. `canopy reboot-check` says "no
agent panes are open" on a machine full of them, and the reboot scenarios fail with
nothing wrong in canopy at all. `canopy doctor` still says `ps: yes`, because `ps`
reports a parent perfectly well; it is the command name that is rewritten.

It is not universal. An amd64 `alpine` image on an arm64 host showed the prefix and
failed scenarios 7 and 8; an amd64 `archlinux` image on the same host reported the
command cleanly and passed everything. Treat a mismatch as the first thing to rule
out, not as a guaranteed failure.

`run.sh` compares each built image's architecture against the host's and warns loudly
when they differ, because this is easy to hit by accident: a container CLI reuses an
image already in local storage rather than re-resolving it, so one stale
`alpine:latest` of the wrong architecture is enough.

```sh
podman pull --platform linux/arm64 alpine:latest   # or docker
```

The official Arch image is a case where it cannot be avoided: it is amd64 only. On an
arm64 host, build an arm64 Arch instead:

```sh
CANOPY_SMOKE_BASE_ARCH=lopsided/archlinux:devel mise run smoke arch
```

`CANOPY_SMOKE_BASE_<IMAGE>` works for any of the four, and each Dockerfile takes its
base as a build arg. CI runs on amd64 runners, where all four resolve natively and
none of this applies. Scenario 6 is the one a single-user
laptop cannot express at all, and it found a real bug: the runtime directory fell back
to a plain `/tmp/canopy`, which belonged to whichever account created it first, so the
next user's `canopy doctor` reported a healthy install as a load-bearing failure.

Nothing in this harness runs canopy on the host. Installing canopy writes to
`~/.config/tmux` and `~/.tmux.conf`, and checking what loaded means starting tmux, so
both belong in a container and only in a container.

The container's own exit status is deliberately not trusted: it reaches `run.sh`
through a pipe, and POSIX sh has no `pipefail`. `scenarios.sh` prints a `RESULT` row
per scenario and a `SCENARIOS-COMPLETE` sentinel only when it reaches the end, so a
crash partway through is caught by the missing sentinel.

## Lint

```sh
mise run lint
```

`test/lint.sh` is the one definition of what gets linted and how: it runs shellcheck
over `bin/* lib/*.sh test/smoke/*.sh` and `shfmt -d -i 2 -ci` over `bin lib
test/smoke`. CI calls this same script, so a contributor running it locally lints
exactly what the runner lints. `.shellcheckrc` sets `shell=sh` and `enable=all`, with
`SC2250` and `SC2312` disabled. Both tools must be clean; `mise exec -- shfmt -w bin
lib test/smoke` applies the formatting.

`mise run check` runs lint, the unit suite and the restore proof in that order, which
is everything CI runs bar the containers.

Files that are not POSIX sh carry a directive. `lib/*.sh` start with
`# shellcheck shell=sh` because they are sourced, not executed.

## CI

| Workflow | Jobs |
|---|---|
| `.github/workflows/ci.yml` | `mise run lint`, `mise run test`, on ubuntu-latest and macos-latest |
| `.github/workflows/restore-proof.yml` | `sh test/restore-proof.sh`, on ubuntu-latest and macos-latest |
| `.github/workflows/smoke.yml` | `sh test/smoke/run.sh <image>`, one job per image, ubuntu-latest only, 20-minute timeout each |

CI runs the task names rather than the commands behind them, so `mise run lint` locally
and the `lint` step in CI cannot drift apart. The restore proof is the deliberate
exception: it installs a system tmux from the OS package manager instead of the version
mise pins, because that job's question is whether the guarantee holds against the tmux
a user actually has.

Smoke is its own workflow rather than a step in CI on purpose. A smoke failure means
the shipped artifact does not work on a real machine, which is a different thing from
a lint or unit failure and should be readable as such from the checks list without
opening a log.

## Writing a command

One command per file, `bin/canopy-<name>`, executable, starting with:

```sh
#!/bin/sh
# canopy:summary=One line, imperative, no trailing period
# canopy:group=core
# canopy:args=[--flag] [--other <value>]
# canopy:examples=canopy <name> --flag
set -eu

: "${CANOPY_STORE:=$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=../lib/env.sh
# shellcheck disable=SC1091
. "$CANOPY_STORE/lib/env.sh"
canopy_paths
```

| Header | Required | Default |
|---|---|---|
| `canopy:summary=` | yes. `canopy doctor` reports a command without one | empty |
| `canopy:group=` | no | `misc` |
| `canopy:args=` | no | empty |
| `canopy:examples=` | no | empty |

Headers must appear in the first 40 lines and must not contain a tab or carriage
return. The dispatcher and `canopy index` both read them; nothing registers a command
anywhere else.

A command that takes no options still parses its arguments, so a typo is refused rather
than swallowed:

```sh
if [ $# -gt 0 ]; then
  canopy_die "canopy-<name>: unknown argument: $1"
fi
```

One that takes options loops over `"$@"` and ends its `case` with the same
`canopy_die`. The message shape and the exit code are the same across every command;
`test/version.bats` pins that.

`bin/canopy` is the exception to the store-resolution snippet above: it follows the
symlink chain of its own path before taking the dirname, because it is the file a user
symlinks onto a `PATH`. It exports `CANOPY_STORE` through `canopy_paths` before
`exec`ing a subcommand, so nothing else needs to.

Constraints that apply to everything in `bin/` and `lib/`:

- POSIX sh. `local` is the one permitted extension, since dash, ash and bash all
  support it.
- No hardcoded paths. Everything resolves through `canopy_paths`, because the tests
  depend on redirecting them.
- No identity, hostname, client name or machine specific in any shipped file.
- Any tmux invocation carries `-L <socket>`. Never the default socket.

## Adding a test

Ask which suite it belongs in.

| If the test is about | Put it in |
|---|---|
| A function's behaviour, an error message, an exit code | `test/<area>.bats` |
| Byte-for-byte restoration of a new file shape | `test/restore-proof.sh` |
| Whether the shipped artifact works for a person on a real machine | `test/smoke/scenarios.sh` |

A scenario in `scenarios.sh` must not source a helper or export `CANOPY_*`. When it
has to fabricate damage (an interrupted install, say), it does so inside a subshell so
the variables that fabrication needs cannot leak into the scenario. Fabricating damage
is setup; every canopy command the scenario then runs still runs from the bare
environment.

## Commits

Conventional commits: `type(scope): description`. The body should say why, not what;
the diff already says what.

---

Back to the [README](../README.md) ·
[01 Installation and removal](01-installation-and-removal.md) ·
[02 Commands](02-commands.md) ·
[03 The restore guarantee](03-restore-guarantee.md) ·
[04 Configuration](04-configuration.md) ·
[05 Troubleshooting](05-troubleshooting.md) ·
[07 Persistence](07-persistence.md) ·
[08 Agents](08-agents.md)

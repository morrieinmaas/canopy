# Contributing to canopy

canopy is a tmux configuration distribution written in POSIX shell. Patches,
bug reports and adapters for other agents are all welcome.

The substance of how to work on it lives in
[docs/06-contributing-and-testing.md](docs/06-contributing-and-testing.md): the
three test suites, what each one is for, and the rule every change follows.
This file is the short version, and the map.

## The rule that matters most

**A claim about behaviour is verified before it is made.** Not "this should
work": run it, and say what happened. canopy's whole promise is that it can be
installed and then removed without a trace, on somebody else's machine, and
that promise is only as good as the last thing that was actually checked. If
something cannot be verified, the honest move is to say so in the change
itself.

## Setup

The toolchain is pinned in [mise.toml](mise.toml). One command installs all of
it:

```sh
mise install
```

Nothing there is needed to *use* canopy, which runs on `sh` and `tmux` alone.
It is for working on it.

## The commands

```sh
mise run lint     # shellcheck and shfmt over every shipped script
mise run test     # the bats suite
mise run proof    # install, mutate, restore, compare hashes
mise run smoke    # container acceptance scenarios (needs docker or podman)
mise run check    # lint, test and proof together, which is what CI runs
```

`mise run test test/doctor.bats` runs one file. `mise run smoke arch` runs one
image. CI runs the same task names, so a green run locally means the same thing
it means there.

## Before opening a pull request

- `mise run check` passes.
- New behaviour has a test, and that test fails without the change. A test that
  cannot fail is worse than no test, because it reads like cover.
- A new command has a section in
  [docs/02-commands.md](docs/02-commands.md). A test enforces this.
- A new tmux option canopy sets is a row in [tmux/options.tsv](tmux/options.tsv).
  A test enforces this too.
- A new key binding is a row in [tmux/keys.tsv](tmux/keys.tsv), not a `bind`
  line. Keys are data: a binding written anywhere else has no name, no group
  and no description, and can never appear in a cheatsheet or a menu.
- Commits are conventional (`fix(doctor): …`), and the message says *why*, not
  what the diff already shows.

## Shell constraints

Everything in `bin/` and `lib/` is POSIX `sh`, not bash. `local` is the one
permitted extension, because dash, ash and bash all support it. `.shellcheckrc`
pins `shell=sh` with `enable=all`, and the Debian and Alpine smoke images exist
to catch what a macOS bash would quietly accept.

The vendored plugins under `plugins/` are upstream code and are not ours to
restyle. They are copied verbatim at the commits in
[plugins/VERSIONS](plugins/VERSIONS); to move a pin, edit that file and run
`mise run vendor <name>`.

## Reporting a bug

Open an issue. The template asks for `canopy doctor` output, your tmux version
and your OS, and those three answer most questions before anyone has to guess.

## Code of conduct

By taking part you agree to abide by the
[Code of Conduct](CODE_OF_CONDUCT.md).

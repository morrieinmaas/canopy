# Remote awareness: design

**Date:** 2026-11-16
**Status:** Draft, awaiting review
**Repo:** canopy
**Build order:** 4 of 4, after athome's binary, keys and remote-machines specs
(`docs/superpowers/specs/2026-11-16-*.md` in athome). Section 2 also needs canopy's themes
(§9 of `2026-09-17-canopy-design.md`, planned for M5).

## Problem

With athome, a dev box gets the same shell, tools, grofe and canopy config as the laptop.
That sameness has a cost: a client box and the laptop look identical, so it is easy to lose
track of where a command is about to run. And the theme you pick on the laptop should be
the theme you see on the box.

## Goals

1. The status line and the terminal title say which machine and scope you are on.
2. The active theme follows you to the box.

## Non-goals

- Transport, reconnects and forwarding: grofe's ssh-remote spec.
- Inventory, provisioning, keys, the shell prompt, the ssh nudge and restore after a box
  reboot: athome's remote-machines spec. canopy does not wrap the shell or start servers.
- Any per-client customisation beyond the context colour.

## Backends

Both sections apply on real tmux and on grofe. canopy has a status layer for each
(`tmux/conf.d/20-status.conf` and `grofe/templates/20-canopy-status.toml`), and both get the
same changes.

## 1. Machine and scope indicator

athome writes `ATHOME_MACHINE`, `ATHOME_SCOPE` and `ATHOME_CONTEXT_COLOR` on each box (for
example `acme-dev`, `work/acme`, `yellow`). canopy reads them **when it generates its
config**, not at runtime: the server's environment depends on how it was started, and
neither backend expands environment variables in status formats. When `ATHOME_MACHINE` is
set at generation time, canopy writes three user options into the generated layer:
`@canopy_machine`, `@canopy_scope`, `@canopy_context_color`. On the laptop they are unset
and nothing below appears.

- **Status line:** a separate segment before the session pill, `machine · scope`, drawn as
  bold text in `@canopy_context_color` on the default background, with no pill fill. Text on
  the default background stays readable with any theme; a hex `@theme_bg` on an ANSI fill
  would not. The segment is added only when `@canopy_machine` is set, and
  `status-left-length` is raised from 40 to 80 on remote machines so the session pill still
  fits.
- **Terminal title:** canopy turns on `set-titles` with `set-titles-string`
  `#{@canopy_machine} · #S` on remote machines, so the laptop's terminal tab says where you
  are. `allow-rename` stays off as today; titles are set by the server, not by programs.

The ANSI colour comes from the terminal's palette, which is the laptop's terminal even on a
box. That is what makes it match athome's prompt, which uses the same colour name.

This is a safety feature as much as a nicety, so it is on by default on remote machines and
no theme can hide it.

## 2. Theme following

**Needs canopy's themes (M5).** Today the status line reads `@theme_*` options, but there is
no `canopy theme` command, no `themes/` directory and no `current/theme` yet.

Once themes exist, the active theme is the symlink `$CANOPY_STATE/current/theme`. Following
it to a box works like this:

- **On the laptop,** athome's zsh config exports `CANOPY_THEME` from that symlink, so every
  grofe client started from a shell carries it.
- **On attach,** grofe copies the variables listed in `update-environment` from the client
  into the session. canopy adds `CANOPY_THEME` to that list on every machine. Over
  `grofe -r`, the box's `grofe proxy` only bridges bytes and the attach hello, environment
  included, comes from the laptop's client (grofe `docs/protocol-proxy.md`, the `attach`
  channel), so the box's server sees the laptop's value.
- **Applying it:** a hook runs `canopy theme apply "$CANOPY_THEME"` when the value differs
  from the box's current theme and the box has that theme. Unknown names are ignored. The
  hook is on `client-session-changed`, which grofe and tmux fire on every attach, including
  the one that creates the session. `client-attached` alone would miss that first attach:
  grofe, like tmux, fires it only for `attach-session`.

A theme change reaches a box on the next attach from a shell that has the new value. grofe
copies the environment only when a client attaches, so an attached client does not
repaint the box when you switch theme on the laptop.

## Testing

Each test runs on both backends.

- Indicator: generate with the three `ATHOME_*` variables set; the status line has the
  segment in the right colour, `status-left-length` is 80, and the title shows machine and
  session. Generate without them: no segment, no title change, length 40.
- The segment's text has no `@theme_bg` fill (a format check on the generated layer).
- Theme following, once M5 lands: attach with a known theme name applies it; an unknown name
  leaves the current theme; the first attach that creates a session applies it too.
- Theme following over `grofe -r`, against athome's test container: the laptop's
  `CANOPY_THEME` reaches the box's session. grofe's ssh-remote work should carry its own
  test that a remote attach's environment reaches `update-environment`.

## Docs

- `docs/04-configuration.md`: the remote indicator, its three options, and the title.
- `docs/02-commands.md`: `canopy theme apply` when M5 lands, and theme following.
- `README.md`: one line that canopy marks remote athome machines.

## Open questions

None at this stage.

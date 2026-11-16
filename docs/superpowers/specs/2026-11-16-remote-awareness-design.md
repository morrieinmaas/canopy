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

A new command, `canopy remote`, records where this machine lives:

```
canopy remote set --machine acme-dev --scope work/acme --color yellow
canopy remote clear
```

athome runs `set` on the box during bootstrap and every `machine sync`, after canopy is
installed, passing the values as flags (the remote-machines spec names the step). Taking
flags rather than reading `ATHOME_*` means it never depends on which shell or service
environment it runs in. It writes two per-machine files, the same way `canopy-caps` writes
`$CANOPY_STATE/05-caps.conf`:

- **tmux:** `$CANOPY_STATE/25-remote.conf`, sourced by `tmux/tmux.conf` with
  `source-file -q` after the status layer, so a machine without it loads nothing.
- **grofe:** `~/.config/grofe/conf.d/25-remote.toml`. grofe loads `conf.d/*.toml` in
  lexical order, so it lands after `20-canopy-status.toml`, and its name is outside the
  `NN-canopy-*.toml` pattern that `canopy grofe generate` cleans up.

Each file sets `@canopy_machine`, `@canopy_scope` and `@canopy_context_color`, plus the
numeric and on/off settings below, which cannot be formats. The shipped layers stay
machine-independent, so the checked-in `grofe/conf.d` and its generate test are unchanged.
On the laptop nothing is written and nothing below appears.

- **Status line:** the shipped `status-left` gains a conditional segment before the session
  pill, `#{?@canopy_machine,...,}`, showing `machine · scope` as bold text in
  `@canopy_context_color` on the default background, with no pill fill. Text on the default
  background stays readable with any theme; a hex `@theme_bg` on an ANSI fill would not. The
  per-machine file raises `status-left-length` from 40 to 80 so the session pill still fits.
- **Terminal title:** the per-machine file turns on `set-titles` with `set-titles-string`
  `#{@canopy_machine} · #S`, so the laptop's terminal tab says where you
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

- **On the laptop,** athome's zsh config exports `CANOPY_THEME` as the theme's name, the
  basename of the symlink's target, not a path (athome's remote-machines spec). Every
  grofe client started from that shell carries it.
- **On attach,** grofe copies the variables listed in `update-environment` from the client
  into the session. canopy adds `CANOPY_THEME` to that list on every machine. Over
  `grofe -r`, the box's `grofe proxy` only bridges bytes and the attach hello, environment
  included, comes from the laptop's client (grofe `docs/protocol-proxy.md`, the `attach`
  channel), so the box's server sees the laptop's value.
- **Applying it:** a hook runs `canopy theme set --mux-only "$CANOPY_THEME"` when the value differs
  from the box's current theme and the box has that theme. Unknown names are ignored. The
  hook is on `client-session-changed`, which grofe and tmux fire on every attach, including
  the one that creates the session. `client-attached` alone would miss that first attach:
  grofe, like tmux, fires it only for `attach-session`.

**Starship on a box.** When M5 adds the starship overlay (§9), canopy's merged config takes
athome's rendered `~/.config/starship.toml` as its base and changes only colours, so
athome's remote host segment survives (athome's remote-machines spec states the same rule).

`--mux-only` is a flag this spec adds to §9's `canopy theme set <name>`: it regenerates and
reloads only the multiplexer layer, and leaves the ghostty and starship artifacts alone,
which on a box belong to the laptop's terminal and to athome's prompt.

A theme change reaches a box on the next attach or `switch-client` from a client whose
start-up environment has the new value. grofe copies the environment only then, from the
client's start-up environment, so an attached client does not repaint the box when you
switch theme on the laptop.

## Testing

Each test runs on both backends.

- Indicator: after `canopy remote set`, the status line has the segment in the right colour,
  `status-left-length` is 80, and the title shows machine and session. After
  `canopy remote clear`, or on a machine where it never ran: no segment, no title change,
  length 40.
- `canopy grofe generate` leaves `25-remote.toml` in place, and the checked-in
  `grofe/conf.d` is identical with and without `canopy remote set`.
- The segment's text has no `@theme_bg` fill (a format check on the shipped status layers).
- Theme following, once M5 lands: attach with a known theme name applies it; an unknown name
  leaves the current theme; the first attach that creates a session applies it too.
- Theme following over `grofe -r`, against athome's test container: the laptop's
  `CANOPY_THEME` reaches the box's session. grofe's ssh-remote work should carry its own
  test that a remote attach's environment reaches `update-environment`.

## Docs

- `docs/04-configuration.md`: the remote indicator, its three options, and the title.
- `docs/02-commands.md`: `canopy remote set|clear`, and `canopy theme set --mux-only` with
  theme following when M5 lands.
- `README.md`: one line that canopy marks remote athome machines.

## Open questions

None at this stage.

# Remote awareness: design

**Date:** 2026-11-16
**Status:** Draft, awaiting review
**Repo:** canopy
**Depends on:** grofe ssh-remote (`docs/specs/2026-11-15-ssh-remote.md` in grofe) and
athome's remote machines spec (`docs/superpowers/specs/2026-11-16-remote-machines-design.md`
in athome), which installs canopy's generated config on each box.

## Problem

With athome, a dev box gets the same shell, tools, grofe and canopy config as the laptop.
That sameness has a cost: a client box and the laptop look identical, so it is easy to
lose track of where a command is about to run. A few canopy behaviours also assume a
desktop machine with one multiplexer per terminal.

## Goals

1. You always know which machine and context a pane is on.
2. The active theme follows you to the box.
3. No nested multiplexers when you ssh by hand from inside grofe.
4. Sessions on a box survive a reboot of the box, without a desktop session.

## Non-goals

- Transport, reconnects and forwarding: grofe's ssh-remote spec.
- Inventory, provisioning and keys: athome's specs.
- Any per-client customisation beyond the context colour.

## 1. Machine and context indicator

canopy reads three values from the environment athome writes on each box:
`ATHOME_MACHINE`, `ATHOME_SCOPE` and `ATHOME_CONTEXT_COLOR` (for example `acme-dev`,
`work/acme` and `yellow`). When `ATHOME_MACHINE` is set:

- the status line shows `machine · scope` at its left edge, in the context's colour;
- the window title carries the machine name, so the laptop's terminal tab says where you
  are.

The colour is an ANSI colour name, mapped per context in athome's chezmoi data. ANSI names
follow the active theme, so no theme defines context colours, and the status line matches
the shell prompt, which athome renders with the same name (athome's remote-machines spec,
"Where you are"). On the laptop nothing changes:
with `ATHOME_MACHINE` unset there is no indicator. This is a safety feature as much as a
nicety, so it is on by default and cannot be hidden by a theme.

## 2. Theme following

When grofe attaches to a box, it passes the laptop's active theme name to the remote
session. canopy on the box applies that theme if it has it, and keeps its current one
otherwise. The box never stores a theme choice of its own, so switching theme on the
laptop is reflected on the next attach, or at once on every attached box.

The name travels as an environment variable, `CANOPY_THEME`, set in the laptop's
environment by canopy. grofe already supports tmux's `update-environment`: on attach it
copies the listed variables from the client into the session. canopy adds `CANOPY_THEME` to
`update-environment` on every machine, and a `client-attached` hook applies the theme
when the value differs from the current one. No new grofe feature is needed: over `grofe -r`, the box's `grofe proxy` only bridges
bytes, and the attach hello, environment included, is written by the laptop's client
(grofe `docs/protocol-proxy.md`, the `attach` channel). The box's server therefore sees the
laptop's `CANOPY_THEME`, as it would for a local attach.

## 3. The nested-grofe nudge

Running plain `ssh <machine>` from a grofe pane and then grofe on the box gives two
multiplexers, two prefix keys and no forwarding. canopy prevents that:

- When `ssh` is run from inside grofe and the target is a machine in grofe's machine list,
  the shell wrapper prints one line suggesting `grofe -r <machine>` (or `M-m`) and runs
  the ssh as asked. It never blocks.
- On the box, when a login shell starts inside an ssh session that did not come from
  `grofe -r`, canopy does not auto-start grofe. Starting it by hand still works.

## 4. Restore on a headless box

On the laptop, session restore runs when the desktop session starts. A box has no desktop
session. On a box (`ATHOME_MACHINE` set, no display):

- canopy installs its restore as a systemd user service, enabled at boot, which relies
  on the user lingering athome turns on;
- after a reboot, the service starts grofe's server and restores the saved sessions, so
  `grofe -r` reattaches to the same panes, with agents resumed as on the laptop;
- `reboot-check` reports whether lingering is on and the service is enabled.

## Testing

- Indicator: with the three `ATHOME_*` variables set, the status line and title show the
  machine and scope in `ATHOME_CONTEXT_COLOR`. Unset, nothing is
  shown.
- Theme following: attaching with a theme name the box has applies it; an unknown name
  leaves the current theme. Covered once over a local attach and once over `grofe -r` to the
  test container.
- Nudge: `ssh` to a listed machine from inside grofe prints the hint once and still
  connects; to an unlisted host it prints nothing.
- Restore: in the athome test sshd container, save a session, restart the container, and
  confirm the session and a resumed agent pane are back.

## Open questions

None at this stage.

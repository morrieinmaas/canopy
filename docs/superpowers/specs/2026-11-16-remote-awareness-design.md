# Remote awareness: design

**Date:** 2026-11-16
**Status:** Approved 2026-11-16. Section 2 revised by owner ruling 2026-11-18 (below); built 2026-11-18
**Repo:** canopy
**Build order:** 4 of 4, after athome's binary, keys and remote-machines specs
(`docs/superpowers/specs/2026-11-16-*.md` in athome). Section 2 uses athome's existing `theme`
command, not canopy's planned themes (owner ruling 2026-11-18).

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

**Owner ruling 2026-11-18.** This section does not depend on canopy's planned themes (M5,
§9 of `2026-09-17-canopy-design.md`), which are not built and will not be built for it. It
uses athome's existing `theme` command instead. That command already applies one theme
across ghostty, the multiplexer and nvim, keeps the active theme's name in
`~/.config/themes/active`, and paints the status line by setting the `@theme_*` options
canopy's status layers read (athome's `apply-tmux.sh`). The box adopts the laptop's active
theme name and applies it with `theme <name>` on the box.

The earlier draft of this section (a `CANOPY_THEME` naming a canopy theme, `canopy theme set
--mux-only`, and a starship overlay) is withdrawn. What it got right is kept: the name
travels in the client's environment, `update-environment` carries it into the session, and
a hook applies it.

The responsibilities split the same way as section 1: athome owns the laptop's shell and
the box's provisioning, canopy owns the multiplexer layers. canopy wraps no shell and
starts no server.

- **On the laptop,** athome's zsh config exports `CANOPY_THEME`, the contents of
  `~/.config/themes/active`, from a `precmd` hook, so a client started after a `theme`
  switch carries the new name. That is an athome change (follow-up A below). The variable
  keeps canopy's name because canopy defines what reads it, and because athome's rule that
  no `ATHOME_*` variable is ever in `update-environment` stays true.
- **Carrying it.** The per-machine file adds `CANOPY_THEME` to `update-environment` at a
  fixed index, 90. A fixed index rather than `set -ga`, because a reload re-sources the
  file and an append would list the name again on every reload; and not a plain `set`,
  which would replace the defaults (`DISPLAY`, `SSH_AUTH_SOCK` and the rest). Over
  `grofe -r`, the box's `grofe proxy` only bridges bytes, and the attach hello, its
  environment included, comes from the laptop's client (grofe `docs/protocol-proxy.md`, the
  `attach` channel), so the box's server sees the laptop's value. On real tmux over plain
  `ssh`, the value reaches the box only when ssh passes it (follow-up C).
- **Applying it.** A hook runs `canopy remote follow-theme <session>` in the background.
  It reads the name from the session's environment with
  `tmux show-environment -t <session> CANOPY_THEME`, because `update-environment` sets it
  there and a hook's shell runs with the server's environment, where a bare `$CANOPY_THEME`
  would be empty or stale. It runs `theme <name>` only when all of these hold: the value is
  set and is a plain name (letters, digits, `.`, `_`, `-`); athome's `theme` is found (on
  `PATH`, else `~/.local/bin/theme`); `theme --list` lists the name; and `theme --current`
  says something else. In every other case it does nothing and exits 0. A hook has nobody
  to report to.
- **The hooks.** On grofe, `client-session-changed` in the file's `[hooks]` table: grofe
  fires it on every attach, including the one that creates the session, and on
  `switch-client`. On real tmux, `client-attached[90]` and `after-new-session[90]`, not
  `client-session-changed`: opensessions, which canopy loads on tmux, sets that hook with a
  plain `set-hook -g`, and on an array option a plain set clears every index, ours with it.
  tmux 3.4 to 3.8 has no `after-switch-client`; a switch keeps the same client and so the
  same environment, whose theme was already applied when it attached.
- **On the laptop** nothing is written, so there is no hook there and an attach on the
  laptop never changes the theme.

A theme change reaches a box on the next attach from a client started after the change.
An attached client does not repaint the box when you switch theme on the laptop.

What `theme` paints on the box is athome's business. Its ghostty step only writes an
override file when `~/.config/ghostty` exists and signals running ghostty processes, of
which a headless box has none.

### athome follow-ups

canopy needs these athome changes for the whole feature to work. None of them are made
from canopy.

- **A. Laptop: export the theme name.** In athome's zsh config:

  ```zsh
  _athome_canopy_theme() {
    [[ -r ~/.config/themes/active ]] && export CANOPY_THEME="$(<~/.config/themes/active)"
  }
  precmd_functions+=(_athome_canopy_theme)
  ```

  `$(<file)` is a zsh builtin read, so nothing forks per prompt. This replaces the
  remote-machines spec's line that exports the basename of `$CANOPY_STATE/current/theme`
  "when canopy's themes (M5) land".
- **B. Box: run `canopy remote set`.** Bootstrap and every `machine sync` run
  `canopy remote set --machine <name> --scope <scope> --color <colour>` after canopy is
  installed, as the remote-machines spec already says (athome main does not do it yet).
  The files take effect on the next config load, so a sync that finds a server already
  running follows it with `grofe reload`.
- **C. Real tmux only: pass the variable over ssh.** `SendEnv CANOPY_THEME` in the
  generated `Host` blocks and `AcceptEnv CANOPY_THEME` in the box's sshd hardening. Not
  needed for `grofe -r`.
- **D. The box has `theme`.** `~/.local/bin/theme` and `~/.config/themes/` must not be in
  the remote machine type's chezmoi ignore list.

## Testing

Each test runs on both backends unless it says otherwise.

- Indicator: after `canopy remote set`, the status line has the segment in the right colour,
  `status-left-length` is 80, and the title shows machine and session. After
  `canopy remote clear`, or on a machine where it never ran: no segment, no title change,
  length 40.
- `canopy grofe generate` leaves `25-remote.toml` in place, and the checked-in
  `grofe/conf.d` is identical with and without `canopy remote set`.
- The segment's text has no `@theme_bg` fill (a format check on the shipped status layers).
- Theme following: an attach with a known theme name applies it; the name is read from the
  session's environment, not the server's; an unknown name, the current name, an unsafe
  value or a missing `theme` leaves the theme alone; the first attach that creates a session
  applies it too.
- Theme following over `grofe -r`, against athome's test container: the laptop's
  `CANOPY_THEME` reaches the box's session. That needs athome's container and follow-ups A
  and B, so it is athome's test; canopy's own tests attach a local grofe client, which goes
  through the same hello and `update-environment`.

## Docs

- `docs/04-configuration.md`: the remote indicator, its three options, the title and theme
  following.
- `docs/02-commands.md`: `canopy remote set|clear|follow-theme`.
- `docs/01-installation-and-removal.md`: the two files `canopy remote` writes.
- `README.md`: one line that canopy marks remote athome machines.

## Open questions

None at this stage.

## Build

### Goal

`canopy remote set` on a box makes both backends show `machine · scope` in the context
colour and put the machine in the terminal title, and makes every attach adopt the
laptop's athome theme by name. `canopy remote clear`, or never running it, leaves canopy
exactly as it is today.

### Decisions

1. One new command file, `bin/canopy-remote`, with `set`, `clear` and `follow-theme`.
   `follow-theme` is the hooks' entry point, documented but not meant to be typed.
2. Values are checked, not escaped. They are written into a tmux config and a TOML file, so
   `--machine` is letters, digits, `.`, `_` and `-` (starting with a letter or digit),
   `--scope` the same plus `/`, and `--color` one of tmux's 16 ANSI names (`black`, `red`,
   `green`, `yellow`, `blue`, `magenta`, `cyan`, `white` and each with `bright` in front).
   Anything else is refused and nothing is written.
3. `set` writes both files every time, each to a temporary name and moved into place as
   `canopy caps` does. `clear` removes both and is not an error when they are absent.
   Neither touches a running server: the files apply on the next config load.
4. tmux: `tmux/tmux.conf` sources `$CANOPY_STATE/25-remote.conf` with `source-file -q`
   after the numbered layers and before `user.conf`, so `user.conf` still wins. The file's
   hooks sit inside `%if "#{==:#{grofe_version},}"`, as `tmux.conf`'s own tmux-only lines do.
5. grofe: `${XDG_CONFIG_HOME:-$HOME/.config}/grofe/conf.d/25-remote.toml`. Its
   `update-environment` entry is a `load-commands` line, because a TOML array would replace
   the whole list.
6. The status segment is shipped in both status layers, empty unless `@canopy_machine` is
   set: `#{?@canopy_machine,#[fg=#{@canopy_context_color}]#[bg=default]#[bold]#{@canopy_machine} · #{@canopy_scope} #[nobold],}`,
   in front of the session pill. One attribute per `#[...]`, so no comma sits inside the
   conditional: grofe reads a format set from its own CLI in its own dialect, which has no
   `#,` escape, and there a style's comma ends the branch.
7. The three options are rows in `tmux/options.tsv` with source `generated`, group
   `remote`, so `canopy config` lists them.
8. Theme following as section 2: `update-environment[90]`, grofe's `client-session-changed`
   hook, tmux's `client-attached[90]` and `after-new-session[90]`, `run-shell -b`.

### Acceptance criteria

1. `canopy remote set --machine acme-dev --scope work/acme --color yellow` exits 0, prints
   nothing, and writes `$CANOPY_STATE/25-remote.conf` and
   `$XDG_CONFIG_HOME/grofe/conf.d/25-remote.toml`.
2. On tmux, a server that loads `tmux/tmux.conf` afterwards has `@canopy_machine`
   `acme-dev`, `@canopy_scope` `work/acme`, `@canopy_context_color` `yellow`,
   `status-left-length` 80, `set-titles` on, `set-titles-string`
   `#{@canopy_machine} · #S`, and a status-left that expands to the segment
   `#[fg=yellow]#[bg=default]#[bold]acme-dev · work/acme #[nobold]` before the session pill.
3. On grofe, the checked-in fragments plus `25-remote.toml` load with no error, and give
   `status.left-length` 80, `set-titles` true and the same title and segment.
4. With no file, or after `canopy remote clear`: no `@canopy_machine`, `status-left-length`
   40, `set-titles` off, no segment, no `CANOPY_THEME` in `update-environment`, no hook.
5. Running `set` twice writes byte-identical files; sourcing `tmux.conf` twice lists
   `CANOPY_THEME` once in `update-environment`.
6. A bad or missing flag, an unknown argument or a missing subcommand exits 1 with a
   `canopy: ...` message and writes nothing.
7. `canopy grofe generate` leaves `25-remote.toml` alone, and what it generates is the same
   with and without `canopy remote set`.
8. An attach from a client whose environment has `CANOPY_THEME=everforest`, on a box whose
   `theme --current` is `gruvbox`, runs `theme everforest` once, on tmux and on grofe, both
   when the attach creates the session and when it joins an existing one.
9. `follow-theme` runs no `theme <name>` when the session's value is unset, unsafe, not in
   `theme --list` or already current, or when no `theme` exists, and exits 0 in each case.
   It reads the session's environment, not the server's.
10. Docs: `docs/02` has a `canopy remote` section, `docs/04` describes the indicator, the
    options and theme following, `docs/01` lists the files, the README has the line.

### Edge cases

- `--color` given as a hex value or a 256-colour number: refused; the colour must come from
  the terminal's palette to match athome's prompt.
- The same flag twice: the last one wins, as with most commands.
- `XDG_CONFIG_HOME` unset: the grofe file goes under `$HOME/.config`.
- A session name with spaces or quotes: the hook passes `#{q:session_name}`, so the shell
  gets one argument.
- `theme <name>` fails: ignored, exit 0.
- A box whose `theme` is not on the server's `PATH` (a server started by systemd):
  `~/.local/bin/theme` is tried.
- opensessions resets `client-session-changed` on tmux: canopy does not use that hook on
  tmux.
- `canopy remote clear` while a server runs: the options, title, `update-environment`
  entry stay until the server restarts (a reload sets but never unsets them), and so do
  the hooks on tmux; grofe's reload drops a hook its config no longer names. Documented.

### Test list

All in `test/remote.bats`; scratch `CANOPY_STATE`, `HOME` and `XDG_CONFIG_HOME`, private
sockets only. A fake `theme` on `PATH` answers `--list` with `gruvbox` and `everforest`,
`--current` with its state file (default `gruvbox`), and logs `applied <name>` for any
other call.

1. `set --machine acme-dev --scope work/acme --color yellow`: exit 0, empty output; the tmux
   file has the lines `set -g @canopy_machine "acme-dev"`, `set -g @canopy_scope "work/acme"`,
   `set -g @canopy_context_color "yellow"`, `set -g status-left-length 80`,
   `set -g set-titles on`; the grofe file has `canopy_machine = "acme-dev"`,
   `canopy_scope = "work/acme"`, `canopy_context_color = "yellow"`, `left-length = 80`,
   `set-titles = true`.
2. `set` twice with the same flags: both files byte-identical.
3. `set` again with `--machine beta-dev`: the files say `beta-dev`, not `acme-dev`.
4. `set --machine acme-dev --scope work/acme` (no colour): exit 1, output
   `canopy: usage: canopy remote set --machine <name> --scope <scope> --color <colour> | clear`,
   no files.
5. `--machine 'a"b'`: exit 1, output names `--machine`; `--scope 'work/$x'`: exit 1, names
   `--scope`; `--color purple` and `--color '#ff0000'`: exit 1, names `--color`; no files.
6. `set --bogus x`: exit 1, `canopy: canopy-remote: unknown argument: --bogus`.
7. `canopy remote` and `canopy remote frob`: exit 1 with the usage line.
8. `clear` after `set`: both files gone, exit 0; `clear` again: exit 0. Another file in
   grofe's `conf.d` survives.
9. tmux, after `set`: the options of criterion 2, and `display -p '#{T:status-left}'` starts
   with `#[fg=yellow]#[bg=default]#[bold]acme-dev · work/acme #[nobold]`.
10. tmux, never set: `@canopy_machine` empty, `status-left-length` 40, `set-titles` off,
    status-left starts with the session pill (`#[fg=#458588`).
11. tmux, `set` then `clear`: as test 10.
12. tmux, after `set`: `update-environment[90]` is `CANOPY_THEME`, and after a second source
    of `tmux.conf` it appears once; `client-attached[90]` and `after-new-session[90]` run
    `canopy-remote" follow-theme`. Without `set`: neither.
13. Format check: in both shipped status layers, the text of the `#{?@canopy_machine,...}`
    segment has no `theme_bg` and no `bg=#{`.
14. tmux end to end: a client with `CANOPY_THEME=everforest` runs `new-session -s main` (in
    an outer scratch server's pane, for a terminal): the fake `theme` logs
    `applied everforest`.
15. tmux end to end: the session exists already and the client runs `attach -t main`: logs
    `applied everforest`.
16. `follow-theme main` with the session's `CANOPY_THEME` `everforest` and the server's
    global one `nosuch`: logs `applied everforest`.
17. `follow-theme main` with the session value `nosuch`, `gruvbox` (current), `a;b`, or
    unset: no `applied` line, exit 0.
18. `follow-theme main` with no `theme` on `PATH` and none in `~/.local/bin`: exit 0; with
    the fake only at `$HOME/.local/bin/theme`: logs `applied everforest`.
19. `follow-theme` with no session: exit 1, usage.
20. grofe: `canopy_grofe_validate grofe/conf.d <25-remote.toml>` succeeds; `show-config`
    gives `status.left-length = 80` and still lists 30-canopy-plugins' load commands.
21. grofe: `canopy grofe generate` into a `conf.d` holding `25-remote.toml` leaves it
    byte-identical; generating after `set` matches the checked-in `grofe/conf.d`.
22. grofe end to end: a grofe server with the fragments and `25-remote.toml`, a client with
    `CANOPY_THEME=everforest` creating session `main`: logs `applied everforest`, and the
    expanded status-left has `acme-dev · work/acme`.
23. grofe, never set and after `clear`: `status.left-length = 40`, `set-titles = false`, no
    `CANOPY_THEME` and no hook in `show-config`.
24. grofe end to end, `main` already exists and the client runs `attach-session -t main`:
    logs `applied everforest` once.
25. tmux end to end, the client creates session `a b'c`: logs `applied everforest`.
26. `follow-theme` when `theme <name>` exits 3: exit 0.
27. `set --machine one --machine acme-dev ...`: the file says `acme-dev`.
28. `XDG_CONFIG_HOME` unset: the grofe file is `~/.config/grofe/conf.d/25-remote.toml`, and
    `clear` removes it.
29. grofe's `conf.d` cannot be created: `set` fails and the tmux file is not written either.
30. `follow-theme` with a `theme --list` that lists `a;b`, `../x`, `-eeverforest` and
    `.hidden`, each set in turn: nothing applied, exit 0.
. `--machine café` and `--machine straße` under `LC_ALL=en_US.UTF-8`: exit 1 naming
    `--machine`. The allowed characters are spelled out, not a locale range.
33. The grofe rename fails after the tmux one (a stub `mv`): exit 1, `could not write
    <file>; removed both remote files`, and neither file exists.

### Out of scope

- canopy themes (M5), `canopy theme`, and any starship or ghostty change.
- Repainting attached clients when the laptop's theme changes.
- Reloading a running server from `set` or `clear`.
- The athome follow-ups A to D, and the `grofe -r` container test.

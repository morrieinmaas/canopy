# canopy design

**Date:** 2026-09-17, rewritten 2026-09-27 to describe what was built
**Status:** M1 and M2 built and accepted. The key table (M4 scope) and the status line
(M3 scope) were built early, alongside M2. Everything else in M3 to M6 is planned.
**Scope:** the whole product. v1 target is the full experience, built in ordered milestones (§11).

## How to read this document

This design was written before any code existed. It has since been rewritten so that
it describes what canopy is, because the implementation went further than the design
in several places and somewhere else entirely in a few. Where a decision came out of a
fix, usually one that verification forced, the commit is named in brackets, so the
reasoning can be read in full in its message.

**A sentence with no marker describes what the code does today.** The markers are:

| Marker | Where | Means |
|---|---|---|
| **Status: planned, M`<n>`.** | first line of a section | nothing in that section is implemented; the sentence after it says what exists instead, when anything does |
| **Status: partly built.** | first line of a section | some of the section is built; the markers inside it say which parts are not |
| **[planned, M`<n>`]** | end of a table row, bullet or sentence | that one item is not implemented. `unscheduled` in place of a milestone number means it is wanted but not assigned to one |

The milestone number in a marker is the milestone that item belongs to, taken from §11.

Where this document and the code disagree, the code is what a machine runs. The
user-facing manual is the [README](../../../README.md), `docs/01` to `docs/08`, and
`docs/adapters/contract.md`, which is the authority on the adapter format.

---

## 1. What this is

canopy is an opinionated, agent-aware tmux distribution written in POSIX shell: a
preconfigured tmux setup (core options, a key table, a status line), a command
namespace, vendored session persistence, and an agent adapter layer. It is distributed
as a git clone and updated by pulling it. Themes **[planned, M5]** and self-update
**[planned, unscheduled]** do not exist; there is no `canopy update`.

**The wedge: sessions survive reboot with agent conversations intact.** This is built.
A pane running a coding agent comes back after a reboot running that same
conversation, resumed by its own session id, rather than a fresh one. tmux-resurrect
has always restored layout; what canopy adds is that the pane's saved command is
rewritten at save time into the command that resumes that pane's conversation. fut,
the closest comparable project, states outright that runtime state is not restored
after its daemon exits or the machine restarts.

What proves it: container scenarios 7 and 8 (§11) drive a fake agent through a
simulated reboot and check each pane's transcript for a resume of its own id. Claude
Code's own `--resume` was verified by hand during design, and on a real machine
canopy reads the session id off every live Claude pane and matches it to the
Claude Code adapter (5aaac53).

**Second pillar: agent state as first-class tmux state.** **Partly built.** Agents
report one of five normalized states into their own pane through `canopy agent
report`, which writes four pane options and costs nothing when nothing changed. What
is not built is everything that makes the state visible: window and session rollups,
pane-border and status formats, the attention model **[planned, M3]**.

**What canopy is not:**

- Not a multiplexer. tmux is the runtime; canopy ships configuration, commands and
  glue. See §14 for the Rust multiplexer that canopy is the requirements source for.
- Not a desktop config manager. canopy writes outside tmux's tree in exactly two
  places: a mise `conf.d` fragment when mise is present, and an agent's own
  configuration when the user runs `canopy agent install <agent>`. Both are recorded
  in a transaction and reversible. ghostty and starship integration **[planned, M5]**.
- Not a plugin manager. resurrect and continuum are vendored at pinned commits and
  loaded by absolute path; there is no TPM. A user who keeps TPM for their own plugins
  has to declare them with `@tpm_plugins`, because TPM cannot see `@plugin` lines at
  the depth canopy sources `user.conf` from (9a243c6).
- Not dependent on any single tool beyond tmux itself. Everything else degrades, and
  persistence is the case worth naming: it needs `bash` and a `ps` that can report a
  process's parent, and without either it does nothing while `canopy doctor` says so.

**Prior art, deliberately not rebuilt:** agent status-bar plugins already exist
(tmux-agent-indicator, agent-status-tmux, tmux-agent-status, tmux-agent-usage).
canopy's agent layer exists because it feeds persistence and navigation, not because
the world needs another status indicator.

---

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Core + optional layers.** Core needs tmux ≥ 3.4 and POSIX sh. Optional layers activate when their tool is present and go dormant, never broken, when it is not. Built: the capability probe (§4.3) and one degrading layer, the plugin layer, which goes dormant without `bash`. The fzf, gum, worktree and theme layers **[planned, M4 to M6]**. | Broad audience without weak defaults. A missing tool changes fidelity, never availability. |
| D2 | **Clean-room core, port selectively.** The owner's existing tmux config kept running until canopy reached parity. The port then took that config's structural settings and the reasoning behind them (0dbf66b, 8070a22, 2e87036, 1aa91b4) and left everything personal with its owner: launcher keys naming absolute paths to one machine's tools, a VPN readout naming one provider, a pet emoji. The source config has since handed over to canopy. | Avoids holding a daily driver with many live agent panes hostage to a half-finished refactor, and keeps the distribution free of one person's machine. |
| D3 | **v1 target is the full experience**, decomposed into individually dogfoodable milestones (§11). | Owner's call, made with the scope risk stated. Decomposition is sequencing, not scope-cutting. |
| D4 | **Distribution: git clone.** Clone anywhere, put `bin/` on `PATH` (a symlink to `bin/canopy` works), run `canopy install`, update by pulling. A `curl \| bash` installer, `canopy update` and timestamped migrations **[planned, unscheduled]**. | No release pipeline, no packaging lag, hacking is editing the clone. Migrations become necessary once other people run old versions. |
| D5 | **Pure shell + tmux.** No daemon, no compiled binary, no build step. A sidecar process is permitted only behind a measured trigger. The two recurring costs are measured and small: a state report is one `tmux display-message` and, only on a real transition, one `tmux set` chain; the status line is one process every five seconds, about 67 ms per render after removing twenty forks from it (6ef854a). | The hot paths are O(1) tmux calls. |
| D6 | **Name: canopy**, CLI `canopy`. The `cnp` alias **[planned, unscheduled]**. | Sits beside worktrunk and leaf; the layer above the trunks is where you see every agent at once. |
| D7 | **Verify the shipped artifact through the user's entry path, from a bare environment.** | Learned when M1's installed config loaded nothing on a real machine past 93 green tests (§11). |
| D8 | **Report what is on disk, not what was intended.** `reboot-check` judges a pane by the line resurrect actually saved; `doctor` reads settings off the config the machine actually loads, `user.conf` included; doctor's incomplete-transaction check asks the files, not the ledger (ba3d2c6). | Every check that reported canopy's intention instead of the machine's state said yes at least once when the answer was no. |

**Publishability rule:** no identity, hostnames, client names, or machine specifics in
shipped files. Anything personal lives in the user config directory, never in the
store. The repository is Apache-2.0; the vendored plugins keep their MIT licences,
named in `NOTICE`.

---

## 3. Verified facts

Everything the design leans on, with how it was checked. Most of the rows below were
not known when the design was written; they are what building and verifying it found.
Unverified items are marked and carry a fallback.

### tmux

| Fact | Result | How |
|---|---|---|
| `source-file` accepts globs | **yes** (tmux 3.7b) | two fragments loaded from `conf.d/*.conf` on a scratch socket |
| a glob `source-file` returns success whenever anything matched, whatever the matched files held | yes | a layer with a syntax error still loaded "successfully" (1aa91b4) |
| a `run-shell` or `if-shell` anywhere in a sourced file resets the status of the `source-file` running it, so errors in every later file go uncounted | yes | one decorative `run-shell` made `canopy install` accept a config holding a syntax error (1aa91b4). `%if` is evaluated by the parser and does not do this (b303aae) |
| a `run-shell` whose command fails fails the `source-file`, and so the whole config load | yes | an unguarded plugin load would stop tmux loading anything on a machine without bash (c5eb8e2) |
| a detached `tmux -f <conf> new-session -d` exits 0 and prints nothing even when `<conf>` has errors; `source-file <conf>` run as a command reports synchronously | yes | M1, recorded in `lib/tmux.sh` |
| tmux prints configuration errors on stdout, mixed with ordinary command output, in three shapes: `file:line: …`, `invalid option: …`, `unknown value: …` | yes | each produced by hand (94435f6). Matching only `file:line:` would miss the 3.4 failure below |
| a command chain ending in `show` never exits when an earlier `source-file` in it fails, and a scratch session holding the reader's pipe turns that into a deadlock | yes | macOS CI sat for nine minutes after every test passed (2907e89) |
| variables in a `source-file` path are expanded from the tmux **server's** environment, which nothing outside tmux populates | yes | M1's installed config loaded nothing on a real machine (510f803) |
| tmux 3.4 has no `extended-keys-format`, and rejects the whole config over it | yes | ubuntu:24.04 container running 3.4 (b303aae). The suite's mise-installed tmux was newer and never saw it |
| programs that request the kitty keyboard protocol (nvim, helix, coding agents) get no extended keys under `extended-keys on`, because tmux forwards them only for its own request method; `always` with `csi-u` is what works | yes | from the config canopy replaced (8070a22). Tradeoff: macOS option-as-alt misbehaves under `always` in some ghostty builds |
| appending options (`set -as`, `set -ga`) append again on every reload | yes | three reloads listed TERM six times (6ef854a) |
| a shell prompt that sets the terminal title counts as a manual rename and stops `automatic-rename` for that window for good | yes | 8070a22; `allow-rename off` is what makes the format hold |
| `pane_current_command` is not the agent's name: tmux reports the interpreter for a script agent, and a real resurrect save recorded it for Claude Code panes as the agent's version string | yes | a resurrect save file on a real machine (c15f63e) |
| tmux runs a pane's shell as a login shell, and `/etc/profile` resets `PATH` | yes | container scenario 7: an agent reachable only through the harness's `PATH` could not be started or resumed (ef20852) |
| a bare `new-session -d` starts the passwd shell, which writes history into `$HOME` when killed | yes | validation left a `.zsh_history` in an otherwise untouched home (c5eb8e2) |
| `kill-server` leaves the socket file behind | yes | about 900 had piled up under `/tmp/tmux-<uid>/` (510f803) |

### resurrect, continuum and TPM

| Fact | Result | How |
|---|---|---|
| continuum autosave rides on `status-right` interpolation | yes | continuum README, and it warns that themes overwriting `status-right` stop autosave |
| continuum **prepends** its hook to whatever `status-right` holds at load, and skips installing it at all while another tmux server is running | yes | read from `continuum.tmux` (`another_tmux_server_running`) (1bc0255, 1aa91b4) |
| continuum's `@continuum-restore` defaults to **off** | yes | a stock install restored nothing after a reboot (ab37bf0) |
| continuum restores only when the server started within `@continuum-restore-max-delay`, when no other server runs, and when `~/tmux_no_auto_restore` is absent | yes | read from continuum at the pinned commit; `reboot-check` reports all three |
| continuum's default save interval is 15 minutes | yes | read from continuum at the pinned commit |
| resurrect inline strategy (`->`, `*` arg token) rewrites restore commands | yes | full round trip: launch → save → kill server → restore → process running with rewritten `--resume <id>` |
| resurrect restore replays the saved command via `send-keys` into a fresh shell, and **only** when that command matches `@resurrect-processes`, whose default names editors and pagers | yes | read from `process_restore_helpers.sh`; without the generated list a perfect resume command was never typed (d0c7bea) |
| resurrect splits `@resurrect-processes` with `eval set` | yes | read from the pinned commit (d0c7bea) |
| resurrect saves no user pane options | yes | a restored pane came back with `@canopy_agent_session` empty (621e10e) |
| resurrect leaves the save file untouched when a new save is byte-identical to the last | yes | `files_differ` in the pinned commit (1bc0255), so file age alone cannot judge autosave |
| resurrect builds the save-command strategy path by interpolating the option into its own tree unsanitised, and falls back to `ps` when the file is missing | yes | measured on the pinned commit and pinned by a test that runs a real save (495df6b) |
| resurrect binds `prefix C-s` and `prefix C-r` when it loads | yes | it took canopy's send-prefix key (94435f6) |
| TPM finds plugins by grepping `/etc/tmux.conf`, the user's `tmux.conf` and the files that file sources directly; it reads `@tpm_plugins` from a real option | yes | on a real machine TPM loaded nothing from `user.conf` and exited 0 (9a243c6) |

### Agents

| Fact | Result | How |
|---|---|---|
| Claude Code `--session-id` cannot be reused | yes | second launch with same id → `Session ID … is already in use` |
| Claude Code's `/clear` starts a new conversation in the same pane, delivered as a new id on `SessionStart`, whose state is `idle` | yes | c15f63e; this is why the report debounce compares the id as well as the state |
| a live Claude Code pane started as `claude --session-id <uuid>` carries its id on its own command line | yes | canopy read the uuid off sixteen live panes on a real machine (5aaac53) |
| Claude Code exposes no way to ask whether a pane holds unsent input | yes | 0554a17; the adapter's `detect_draft` is empty |
| `TMUX_PANE` is inherited by agent hook subprocesses | **to verify** | standard tmux environment inheritance, and `report` depends on it. Not yet observed with a real Claude Code hook firing; step 2 of the manual procedure in `docs/07` is the check. Fallback: an explicit variable injected by a launch wrapper |

### Userland and toolchain

| Fact | Result | How |
|---|---|---|
| `ps -ao ppid,args` exits non-zero on machines where it works (1 with procps, 2 on macOS), exits 0 under BusyBox where it cannot report a parent, and `-a` lists only processes with a terminal | yes | by hand on macOS, procps on Debian and Alpine, and a real BusyBox `ps` (a54eb1c). doctor asks `ps -o ppid= -p $$` instead |
| a BusyBox userland has no `bash`, and many slim images have no `ps` | yes | container scenarios; both images install procps, Alpine installs bash (ef20852) |
| `env -i` breaks a tmux reached through a version-manager shim | yes | milestone 1's macOS CI (c15f63e). Validation unsets exactly the four `CANOPY_*` roots instead |
| shell arithmetic reads a leading zero as octal, so `0900` is an error rather than a number | yes | a flaky test (11a3adf) and a stagger option that silently dropped the wrapper (6ef854a) |
| a CI matrix that installs its own toolchain hides a version-floor bug | yes | bats on mise tmux passed while the restore proof on system tmux 3.4 failed (b303aae) |
| starship multi-config via colon-separated `STARSHIP_CONFIG` | **NO** (1.26.0) | `base.toml:user.toml` silently fell back to the default prompt; single path works. Upstream PR still open |
| ghostty `config-file` include exists | yes (docs) | docs reference; `?` prefix makes a missing file non-fatal |
| ghostty include *precedence* | **unverified** | CLI probe inconclusive. Design routes around it via the themes dir instead |
| ghostty user themes directory | yes | `+list-themes` labels sources |
| mise auto-loads `~/.config/mise/conf.d/*.toml` | yes | mise docs/source; `[env]` merges additively |

---

## 4. Architecture

### 4.1 Store layout

The store is wherever the repository was cloned. `bin/canopy` derives it from the real
path of the running script, walking a symlink chain one hop at a time because
`readlink -f` is not portable (76e9fc0), so the clone can live anywhere and
`bin/canopy` may be symlinked onto `PATH`. `~/.local/share/canopy` is a suggestion,
not a requirement.

```
<clone>/                          # git clone; read-only by convention
  bin/canopy                      # dispatcher: scans siblings' metadata headers
  bin/canopy-*                    # one command per file, eleven of them
  lib/env.sh                      # the four paths, hashing, stat, the runtime dir
  lib/tmux.sh                     # version floor, bare-environment validation, option probe
  lib/manifest.sh                 # transactions and the self-contained restore.sh
  lib/adapter.sh                  # reads and validates adapter manifests
  lib/pane.sh                     # which pane is running which agent
  lib/resume.sh                   # the stagger wrapper and @resurrect-processes
  lib/plugins.sh                  # vendored plugin pins and digests
  tmux/tmux.conf                  # entry point the installed stub sources
  tmux/conf.d/{00-core,20-status,30-plugins}.conf
  tmux/keys.tsv                   # the key table, §4.4
  adapters/claude-code/           # manifest, hooks.json, report.sh, install.sh
  plugins/VERSIONS, CHECKSUMS, vendor.sh, README.md
  plugins/tmux-resurrect/, plugins/tmux-continuum/   # upstream bytes, unmodified
  plugins/strategies/             # canopy's save strategy and process-list generator
  test/                           # bats, restore-proof.sh, smoke/
  docs/                           # the user manual
  adapters/{opencode,pi,codex}/   # planned, M3
  themes/<theme>/                 # planned, M5
  migrations/<epoch>.sh           # planned, unscheduled
```

**User-owned directories:**

- `$CANOPY_CONFIG`, default `~/.config/canopy/`: `user.conf`, and `adapters/<id>/` to
  override a shipped adapter. `starship.user.toml` and user themes **[planned, M5]**.
  Survives uninstall.
- `$CANOPY_STATE`, default `~/.local/state/canopy/`: `05-caps.conf`, `10-keys.conf`,
  `commands.tsv`, `backups/`, and `resurrect/`, where resurrect keeps its saves. The
  saves are the data persistence depends on, so they live in a tree canopy reasons
  about rather than at upstream's default (c15f63e); saves at the old path are not
  migrated. The `current/theme` pointer **[planned, M5]**.
- `$CANOPY_RUNTIME`: `$XDG_RUNTIME_DIR/canopy`, falling back to `/tmp/canopy-<uid>`,
  scoped by uid because `/tmp` is shared (347c500), created mode 0700 and refused if it
  is a symlink, not a directory, another user's, or group- or world-writable
  (46d1bdc). Scratch files only; nothing takes a lock **[planned]**.

Agent state lives in tmux pane options, not on disk. It dies with the server, and
resurrect does not save it, which is why a restored pane's session id is recovered
from the command it is running (§7.1).

### 4.2 Layers and load order

`canopy install` writes a stub at the entry point tmux loads. The stub carries the
store, state and config paths as absolute literals, runs `set-environment -g` for each
so that everything the server starts later inherits them, and sources the store's
`tmux/tmux.conf` (510f803). That file sources, in order:

| # | File | Owns | State |
|---|---|---|---|
| 1 | `00-core` | prefix, indexes, mouse, escape-time, history, terminal features, window naming | ships. Prefix `C-s` (the recipe for keeping `C-b` sits beside it); base and pane index 1; escape-time 0; focus-events; history 100000; mouse; renumber-windows; set-clipboard; vi mode keys; a terminal block (tmux-256color, RGB per terminal, allow-passthrough for inline images, `extended-keys always`, `extended-keys-format csi-u` only on tmux ≥ 3.5, extkeys, TERM passthrough) run once per server under a `%if` guard so reloads do not grow the appending lists (6ef854a); windows named for their directory with `allow-rename off` (8070a22) |
| 2 | `05-caps` | **generated**: capability flags as tmux options | ships. Written by `canopy caps` into `$CANOPY_STATE`, sourced with `-q` |
| 3 | `10-keys` | **generated** from the key table (§4.4) | ships (2e87036). Written by `canopy keys` into `$CANOPY_STATE`, sourced with `-q` |
| 4 | `20-status` | status line: pure `#{…}` tokens and one aggregator `#()` | ships (1aa91b4). Numbered 20 so it loads **before** the plugins, because continuum prepends its autosave hook to whatever `status-right` holds at load. It renders no agent state yet **[planned, M3]** |
| 4 | `30-plugins` | vendored resurrect and continuum, and every option they read | ships, §7.5 |
| 4 | `40-agents` | optional: hooks, pane-border and status formats | **[planned, M3]** |
| 4 | `50-worktree` | optional: wt-aware session naming, picker binds | **[planned, M6]** |
| 4 | `60-theme` | generated: sources the active theme's tmux fragment | **[planned, M5]** |
| 5 | `$CANOPY_CONFIG/user.conf` | the user's own settings, migrated tmux config included | ships. Sourced last, directly, with `-q`; there is no `90-user` file or symlink |

Step 4 is the glob `conf.d/[1-9]*.conf`. It starts at `[1-9]` so that `00-core` is never
sourced twice. Generated layers live in state, not in the store's `conf.d/`, because the
store is read-only by convention and a generated file in a checkout is a local
modification on every machine.

Two rules keep a load honest. A layer decides what it can with `%if`, which the parser
evaluates without forking and without resetting the load's status, rather than
`if-shell` (b303aae); the status layer is asserted to run no shell command at all. The
plugin layer is the one exception, because loading a bash plugin needs a shell, and
every load in it is guarded so that a missing `bash` or `plugins/` tree makes the layer
dormant instead of failing the whole configuration (c5eb8e2).

### 4.3 Capability model

`canopy caps` probes six tools (`wt`, `fzf`, `gum`, `ghostty`, `starship`, `mise`) and
the tmux version, and writes plain options (`set -g @canopy_has_wt 1`) to
`$CANOPY_STATE/05-caps.conf`, atomically. `canopy install` runs it; re-running it after
installing or removing a tool is the user's job. `canopy doctor` never re-probes: it
reads the file, so doctor's report and tmux's options cannot disagree. Layer files are
meant to guard on these options, never on a subprocess, so sourcing the tree forks
nothing.

No shipped layer guards on a caps option yet, because the layers that would are
M3 to M6. Doctor's Layers section therefore reports what each capability *will*
enable, and says so. Per-layer switches (`@canopy_layer_agents off`) with zero
bindings and zero formats left behind by a disabled layer **[planned, M3 to M6]**;
`@canopy_layer_*` is read nowhere today.

The one layer that degrades today degrades on a different signal: the plugin layer
guards on `command -v bash` at load, and doctor reports `bash` and a capable `ps` as
dormant rather than as warnings, because an absent optional tool describes the
machine rather than a fault in the install.

### 4.4 Keys are data

`tmux/keys.tsv` declares every binding canopy ships, and `canopy keys` generates
`$CANOPY_STATE/10-keys.conf` from it. Nothing else in canopy binds a key. The table has
six tab-separated columns: `name`, `key`, `flags` (`-` or tmux bind flags such as
`-r`), `command`, `group`, `description`. The generator refuses a table with a missing
or empty column, a duplicate key or a duplicate name rather than emitting a partial
layer, and writes its temp file beside the target so the move is atomic (94435f6).

The point is that there are no orphan keys: a row cannot exist without a name, a group
and a description, so every binding can appear in a cheatsheet, a palette or a
which-key menu. `canopy keys --print` already renders the table as a grouped
cheatsheet.

It ships twenty bindings: send-prefix, splits and a new window in the current
directory, a "cockpit" window and layout (one full-height pane, two stacked), hjkl
focus and repeatable HJKL resize, last/previous/next session, reload, and resurrect's
save and restore. resurrect's own `prefix C-s` and `prefix C-r` are moved to `M-s` and
`M-r` before it loads, because with canopy's prefix on `C-s` resurrect's binding took
the send-prefix key and the table declared a row that existed nowhere in tmux (94435f6).

**Deviation from the original design:** it said every binding invokes a dispatcher
command. It does not. Splitting a pane through `canopy` would fork a process per
keypress to do what tmux does natively, and the name, group and description live in
the table either way. Bindings that need canopy call it; the rest are tmux commands.
The prefix is an option, not a binding, and lives in `00-core`.

`canopy doctor` counts table rows against `bind` lines in the generated layer, so a
table that grew without regeneration reports as stale; a stored count could not catch
that. The live `list-keys` cross-check **[planned, M4]** arrives with the palette.

### 4.5 Environment resolution

`display-popup`, `run-shell` and `#()` execute in the **tmux server's** environment,
which never sourced the user's shell rc. canopy meets this in three places and solves
it the same way each time: never trust the caller's environment for canopy's own paths.

- `lib/env.sh` resolves canopy's four roots (`CANOPY_STORE`, `CANOPY_CONFIG`,
  `CANOPY_STATE`, `CANOPY_RUNTIME`), each required to be absolute, and every `bin/`
  script sources it. It resolves no tool paths; `canopy_have` is a `command -v` test.
- The installed stub writes the paths as literals and puts them into the server's
  environment with `set-environment -g`, so `#($CANOPY_STORE/bin/canopy-status)` and
  key bindings naming `$CANOPY_STORE` resolve (510f803).
- Code that tmux or an agent runs derives the store from its own file location:
  the save strategy, because the server's environment may be stale or missing, and the
  Claude Code `report.sh`, because the agent's environment is not canopy's.

Validation removes exactly the four `CANOPY_*` roots from the environment rather than
using `env -i`, because a tmux reached through a shim needs the rest of its environment
to find the binary it forwards to (c15f63e). The fzf-backed popups that would meet the
toolchain half of this hazard **[planned, M4]**.

---

## 5. Install, ownership, and restore

### 5.1 The invariant

**We never write a file we don't own, and ownership is provable.** A file is ours only
if it carries our marker or its recorded hash still matches. Everything else is the
user's.

**Preference order:** drop new files into an app's extension point → own a whole file
with a backup → splice into someone else's file. Splicing is the last resort,
marker-delimited, and rewritten only between markers.

What is built: every entry point canopy writes carries `# canopy:entry-point`, which is
how a re-run recognises its own file; `manifest.tsv` records a pre-state and a
post-state per path, and restore refuses to revert a path holding neither. Taking over
a path that is itself a symlink owns the **link**, never the bytes at the other end:
the state is recorded as `symlink:<target>`, backed up with `cp -pP`, and recreated
exactly, because chezmoi, stow and bare dotfiles repos all produce such links and
writing through one damaged a file the manifest never recorded (2c770b3). A dangling
link at the entry point counts as an existing config (5e244b9). The manifest reserves
the actions `splice`, `generate` and `env`; canopy writes only `own` and `drop`.
Splicing **[planned, M5]**.

### 5.2 Per-app integration

| App | What canopy does | Their file | State |
|---|---|---|---|
| tmux | owns the entry point and writes the stub; the existing config's contents are appended to `$CANOPY_CONFIG/user.conf`, which loads last | backed up, replayed last | ships. This is a **migration, not a merge**, and install refuses without `--yes` when a config exists |
| mise | writes `~/.config/mise/conf.d/canopy.toml` declaring `fzf`, `gum` and `starship` under `[tools]`, when mise is installed or that directory exists | never touched | ships. It sets no `[env]` |
| Claude Code | `canopy agent install claude-code` merges canopy's hooks into `settings.json` under `$CLAUDE_CONFIG_DIR` or `~/.claude`, with `jq` | merged, never replaced | ships. Refuses when the directory does not exist, rather than inventing a config for an agent that is not installed. Runs inside a transaction, so `canopy restore` puts the file back byte for byte |
| ghostty | drops a **new** theme file into `~/.config/ghostty/themes/`; optionally one marker-wrapped `theme =` line | untouched, or one line | **[planned, M5]** |
| starship | sets `STARSHIP_CONFIG` via the mise fragment to a generated file merged from canopy's base and `starship.user.toml` | never touched | **[planned, M5]** |

Third-party integration is opt-in per app and never performed by `canopy install`. The
agent adapter is the first instance of that rule; `canopy theme install ghostty`
**[planned, M5]** would be the second.

### 5.3 Load-bearing settings

A small set of settings cannot be left to chance without silently breaking the
product. The design gave all of them to `doctor`. Building them split them across two
commands, by who can answer: `doctor` checks the configuration, `reboot-check` checks
the running persistence path.

**doctor, exit 2 on failure:**

- tmux is at least 3.4.
- The entry point this machine actually loads loads cleanly on a throwaway socket from
  a bare environment. "Cleanly" is judged by tmux's exit status **and** by its output,
  matched against tmux's three error shapes, because the status lies twice over (§3,
  1aa91b4, 94435f6). The scratch session runs `sleep` rather than a shell, so
  validation writes nothing into `$HOME` (c5eb8e2), and zeroes
  `@continuum-restore-max-delay` first, so a validation run never restores the user's
  saved session onto a scratch socket.
- `@continuum-restore` is `on` in that same loaded config, `user.conf` included. Read
  by `canopy_tmux_loaded_option`, which sources and asks in two separate invocations
  writing to files, because one chain ending in `show` deadlocks on a config that
  fails to load (2907e89). Not asked at all when the entry point did not load.
- `user.conf` is the last `source-file` line in the store's `tmux.conf`, checked
  textually.

**doctor, warning:**

- continuum's hook is missing from the **live** server's `status-right`. A scratch
  server cannot answer this, because continuum skips the hook whenever another server
  is running, which is every machine currently using tmux (1aa91b4).
- A vendored plugin tree no longer matches its recorded digest, or is missing.
- `user.conf` holds TPM `@plugin` lines, which TPM cannot see (9a243c6).

**reboot-check, exit 2:** continuum restore off or halted by its halt file; autosave
interval set to zero or to something that is not a number; `status-interval` 0, so the status line never
redraws and autosave never fires; no save ever; or the newest of the save file and
continuum's own last-save timestamp older than twice the interval.

**Not asserted, and not needed:** `@resurrect-processes` covering every installed
adapter. It is generated from the installed adapters at load (§7.1), so it cannot
drift from them.

### 5.4 Two rollback classes, one guarantee

**Class A: config mutations.** Everything an install or an adapter install does to
files that may predate canopy. Byte-captured before the change, **completely
reversible, forever**.

**Class B: canopy-owned state.** The caps cache, the key layer, the command index,
resurrect's saves, `backups/` itself, and the theme pointer **[planned, M5]**. Did not
exist before canopy. Migrations here may be forward-only, because they cannot touch
anything that predates canopy.

**Enforcement:** a migration may not write to a user-owned file; if it must, it opens a
config transaction and becomes Class A. **[planned, unscheduled]** No migration exists,
so this is a rule nothing enforces yet.

> **Invariant (in the README):** the pre-install restore point is complete and
> reachable forever. `canopy restore --all` returns every file that existed before
> canopy to its exact original bytes.

### 5.5 Transactions and restore

Every mutating operation opens a transaction first: `canopy install`, `canopy agent
install <id>`, and `canopy restore` itself. `update` and `theme install`
**[planned]**.

```
$CANOPY_STATE/backups/<epoch>-<label>/    # label: install, restore, agent-install-<id>
  manifest.tsv      # per row: action (own|drop), path, pre-state (absent | sha256 | symlink:<target>), backup file, post-state
  files/...         # one byte copy per manifest row, cp -pP
  restore.sh        # self-contained POSIX sh
  dirs-created.txt  # directories this run created, shallowest first
  .committed        # the operation finished
  .pinned           # the pre-install point only
  .failed           # install validated, failed and reverted itself
  .rollback         # a restore's own transaction
```

Details verification forced: the directory is allocated atomically so two operations in
the same second cannot collide (88e8b30); backup filenames are percent-encoded paths
plus the row's ordinal, because escape-based schemes collided and two rows for one path
clobbered each other (05850d5, 227afd2).

Rules:

- **Restore is itself non-destructive.** A current-hash mismatch means the user edited
  the file after canopy wrote it; restore keeps it and names it. `--force` proceeds.
  Either way restore records its own transaction first.
- **Restore is a fixed point, not a toggle.** A restore's own transaction is marked
  `.rollback` and skipped by automatic rollback, so `--all` run three times leaves the
  original bytes and exits 0 each time; reverting a revert stays available through
  `--to <restore-id>` (c345b0e). `.failed` transactions are skipped the same way.
- **An interrupted install is still recoverable.** Rollback acts on recorded rows
  whether or not `.committed` exists, `--to` accepts every id `--list` shows, and
  doctor names an incomplete transaction and the command that undoes it until the
  files say it is undone (28a8e85, ba3d2c6).
- **The rollback tool does not depend on the thing it rolls back.** `restore.sh` needs
  no store, no dispatcher and no mise.
- **The pre-install restore point is pinned and never pruned.** `canopy install`
  writes `.pinned` after a successful commit, and `restore --list` marks it `PINNED`.
- **Retention: others roll off after the most recent 10, configurable via
  `@canopy_backup_keep`. [planned, unscheduled]** Nothing prunes anything today;
  restore points accumulate, one per install, adapter install and restore.

  **Warning for whoever implements this.** Pruning is not "delete the oldest
  directories". Restore is replayed newest first, and each row is guarded by comparing
  the file's current state against that transaction's recorded `post`. Deleting a
  transaction in the middle of the chain can leave a file whose current bytes match
  only the deleted transaction's `post`, and no surviving transaction then recognises
  that state: the older rows see neither their `pre` nor their `post`, treat the file
  as user-edited, and keep it. The pinned pre-install point is still on disk and still
  says it is reachable, while `restore --all` can no longer reach it, which is exactly
  the guarantee in §5.4 failing quietly. Retention has to reason about the chain
  rather than about ages, and the restore proof has to cover a pruned middle.
- **Restore reports on the result, and a config tmux dislikes is a warning, not a
  failure.** What restore promises is the user's original bytes, and plugin-dependent
  or version-dependent configs routinely carry lines a bare tmux rejects. The restored
  config is still loaded on a throwaway socket and tmux's verdict printed, so "your
  config is back" is never confused with "your config parses". Non-zero is reserved
  for a restore that did not restore (2d9a01e).
- **Directories come back too.** Every directory a transaction created is removed,
  deepest first, with `rmdir`, so a virgin home returns to virgin while a directory
  holding the user's own files survives on its own merits (2d9a01e).
- **`~/.config/canopy/` is never touched** beyond what a transaction recorded.
  `--purge` **[planned, unscheduled]**: there is no `uninstall` for it to modify.

| Command | Does | State |
|---|---|---|
| `canopy restore` | roll back the most recent eligible transaction | ships |
| `canopy restore --list` | show restore points, newest first | ships. Marks `PINNED`, `FAILED` and `INCOMPLETE` |
| `canopy restore --to <id>` | roll back that transaction and every eligible one newer | ships |
| `canopy restore --all` | back to pre-install state | ships |
| `canopy uninstall` | `restore --all` plus removing store and state | **[planned, unscheduled]** Removal is `canopy restore --all` then removing the directories by hand, in the order `docs/01` gives |

### 5.6 CI proves it

Three workflows, split by cost (94435f6):

- **CI**, on every push: `test/lint.sh` (shellcheck at a pinned version, since an
  unpinned one drifted between machines (a18f8a4), and shfmt) and the bats suite,
  319 tests, on Ubuntu and macOS with tmux from mise.
- **Restore proof**, on main, pull requests and on demand: `test/restore-proof.sh`
  records a full `find` listing plus a sha256 per file, installs, runs `restore --all`,
  and requires both to be identical, across three scenarios (a home with real tmux,
  ghostty and starship configs; an empty home; a `tmux.conf` symlinked outside
  `$HOME`), on Ubuntu and macOS with the **system** tmux. That choice is load-bearing:
  it is the job that caught the 3.4 failure (b303aae).
- **Smoke**, on the same triggers: `test/smoke/run.sh` builds Debian (dash) and Alpine
  (BusyBox) images and runs eight scenarios in each from a bare environment, §11.

All three cancel superseded runs. The e2e job that also runs `update` and migrations
between install and `restore --all` **[planned, unscheduled]**, since neither exists.
A restore promise that is not in CI stops being true around version three.

---

## 6. Agent layer

**Status: partly built.** M2 needed agents to identify themselves and to report their
session ids, so the report path, the adapter contract, pane identity and one adapter
exist. Everything this section says about *visibility* is M3.

### 6.1 Model

Five states, normalized across agents: `idle · working · blocked · completed · exited`.

```
canopy agent report <state> [--source <adapter-id>] [--session-id <id>]
canopy agent install <adapter-id>
```

**Pane targeting needs no plumbing:** tmux exports `TMUX_PANE` into the pane
environment, the agent inherits it, and the agent's hooks inherit it from the agent
(see the one unverified row in §3). With no `TMUX_PANE` (IDE, desktop, web) or a pane
that has gone away, `report` exits 0 and writes nothing: a failing hook interrupts the
user's work to report something they cannot act on. A state outside the five is a bug
in the adapter and is reported as one.

### 6.2 Write path

```
tmux display-message -p -t $TMUX_PANE '#{@canopy_agent_state}|#{@canopy_agent_source}|#{@canopy_agent_session}'
# only if any of the three changed:
tmux set -p @canopy_agent_state … \; set -p @canopy_agent_source … \; set -p @canopy_agent_session … \; set -p @canopy_agent_ts …
```

- **Debounce on all three values, not just the state.** Chatty hooks (`PostToolUse`)
  cost one read and no write. The session id is part of the comparison because
  `/clear` delivers a new id with an `idle` state into a pane that is usually already
  `idle`; debouncing on state alone would resume that pane into the wrong
  conversation after a reboot (c15f63e). The timestamp moves only on a write.
- **An option the caller does not name keeps its value**, so a hook that knows only a
  state cannot blank the id an earlier hook recorded.
- **The session id is constrained where it enters**, to letters, digits, `.`, `_`,
  `:` and `-`, and `|` is refused in both values. The id goes on to `respawn-pane`,
  which hands it to `/bin/sh`, and into resurrect's save file, which is replayed at
  boot; only control characters were rejected before (94435f6).
- Window and session rollups (`tmux set -w @canopy_rollup`) and the `refresh-client
  -S` push **[planned, M3]**.

### 6.3 Render path

**Status: planned, M3.** Pane borders from `#{@canopy_agent_state}`, window status
from the rollup, status-right from the session rollup, all pure format expansion with
zero forks per redraw. The status line that ships renders no agent state.

The single aggregator `#()` budget the design reserved for sampled segments is spent:
`canopy status` renders network, battery, date and clock in one process, reading every
option it needs in one tmux call (1aa91b4, 6ef854a). Agent state must therefore arrive
as `#{…}` tokens, never as a second `#()`.

### 6.4 Attention

**Status: planned, M3.** `blocked` and `completed` set `@canopy_agent_unseen`; `set-hook
-g pane-focus-in` clears it (`focus-events on` is already in `00-core`). `canopy agent
next` jumps to the oldest unseen pane.

### 6.5 Adapters

The design listed five things an adapter manifest would declare. The contract that was
built is six `key=value` keys, all required, validated in full on every read
(56c5d6d); `docs/adapters/contract.md` is the authority:

| Key | Is |
|---|---|
| `id` | the adapter's name, which must equal its directory name |
| `command` | the program name that marks a pane as running this agent |
| `resume_template` | the command that resumes a conversation; must contain `{id}` |
| `can_pin_at_launch` | `yes` or `no`: whether the agent accepts a caller-chosen id at launch |
| `launch_template` | the command that starts a conversation at a chosen id; `{id}` required when pinnable, empty otherwise |
| `detect_draft` | a command with `{pane}` reporting unsent input: exit 0 yes, 1 no, anything else undetermined; empty means it cannot answer |

What moved out of the manifest: the events → states map lives in the adapter's own
hook configuration (`hooks.json`, with `{report}` standing for the reporter's path),
because that is the agent's format, not canopy's. `report.sh` turns one event into one
`canopy agent report`, pulling the session id from the hook payload with `sed` so the
per-tool-use path needs no `jq`. `install.sh` is sourced by `canopy agent install`
inside a transaction and must call `canopy_agent_own` on every path before writing it.

`$CANOPY_CONFIG/adapters/` is searched before `$CANOPY_STORE/adapters/`. Placeholder
substitution is literal and never passes through a shell, so a manifest cannot run
anything by being read.

| Agent | Transport | Notable mapping | State |
|---|---|---|---|
| Claude Code | `hooks.json` + sh reporter | `SessionStart`→idle; `UserPromptSubmit`, `PreToolUse`, `PostToolUse`→working; `Notification` split by matcher, `permission_prompt`→blocked, `idle_prompt`→completed; `Stop`→completed; `SessionEnd`→exited | ships, tier 1 |
| opencode | TS plugin | `session.idle`→completed, `tool.execute.before`→working | **[planned, M3]** |
| pi | TS extension | `agent_settled`→completed, `ask_user` tool→blocked | **[planned, M3]** |
| codex | `notify` + hooks → sh bridge | `PermissionRequest`→blocked | **[planned, M3]** |

### 6.6 Pane identity

Not in the original design; `reboot-check`, `adopt` and the save strategy all need to
answer "which agent is in this pane", and two answers would be two chances to disagree,
so `lib/pane.sh` is the one lookup (c15f63e).

- It **never** reads `pane_current_command` (§3).
- It reads the pane's start command first, and falls back to the command line of the
  process in front of the pane's shell, read the way resurrect's `ps` strategy reads it
  but with an exact parent-pid match rather than a prefix. Both are needed: a pane
  started *as* the agent has no such child, and a pane resurrect restored has no start
  command, because resurrect types the command into a shell.
- The program name is taken from that command line skipping interpreters (`sh`, `bash`,
  `env`, …), options and `VAR=value` assignments, so a script agent and
  `env FOO=1 claude` are both recognised. It is matched against each adapter's
  `command`.
- It ignores `@canopy_agent_source`, which outlives the process that reported it.

This is why persistence needs a `ps` that can report a parent: without one no restored
pane is ever recognised, and every save records a shell.

### 6.7 Capability tiers

| Tier | Agent can | Where canopy gets the id | Result |
|---|---|---|---|
| 1 | choose an id at launch **and** resume by id | the pane's own launch command, read back through `launch_template`, or the agent's report | same conversation, from the moment the pane starts |
| 2 | resume by id only | the agent's report | same conversation, once the agent has reported |
| 3 | neither | nowhere | the pane comes back as a shell in the right directory; conversation lost |

The design had tier 2 meaning "canopy rewrites the saved command at save time". That
turned out to be the mechanism for every tier: the save strategy rewrites the command
for any pane whose id it can find (§7.1). The tier only decides when the id becomes
findable. Reading it from the launch command came from a real machine, where sixteen
hand-started Claude panes had never reported and still carried their uuids in plain
sight (5aaac53).

Tier 3 has no representation in the contract, since `resume_template` must contain
`{id}`; such an agent gets no adapter. Claude Code is tier 1. `canopy agent install`
prints the tier, read off the manifest; a tier matrix in doctor **[planned, M3]**.

---

## 7. Persistence

Built in M2. `docs/07` is the user's view of the same chain.

### 7.1 Flow

1. **Launch.** The agent starts in a pane. Its hooks report `idle` and a session id
   into the pane's options. A tier 1 agent started as `claude --session-id <uuid>` is
   identifiable even if its hooks never fire.
2. **Save.** continuum fires resurrect's save every five minutes (0dbf66b; upstream's
   fifteen made `reboot-check` truthfully report a twelve-minute-old pane as not saved,
   which is correct and useless). resurrect asks canopy's save-command strategy,
   `plugins/strategies/canopy_save_command.sh`, what to record for each pane. The
   strategy maps the pid to a pane in one `list-panes` call, takes the adapter from
   the pane's report or from pane identity (§6.6), takes the id from the report or,
   failing that, from the command the pane is running (resume template first, then
   launch template), and prints the adapter's resume command behind a stagger wrapper
   (§7.4). A command carrying a control character is not written, because the save
   file is tab-delimited (495df6b).

   **Everything else comes out as resurrect would have written it.** Every path that
   is not a recognised agent pane, every error path included, execs resurrect's own
   `ps` strategy on the same pid. The lookup runs inside a command substitution, so a
   `canopy_die` in any library ends the lookup and not the save. nvim panes use
   resurrect's `session` strategy, so they return holding their buffers.
3. **Replay list.** At load, `canopy_restore_processes.sh` sets `@resurrect-processes`
   from the installed adapters, two entries per command: the plain name, and
   `"~^sleep [0-9.]* && <command>"` for the same command behind the wrapper. Without
   it resurrect never typed a resume command back (d0c7bea). A command that is not a
   plain word is dropped rather than quoted harder, because resurrect `eval`s the
   value. No adapters means an empty value and resurrect's defaults untouched.
4. **Reboot.** tmux dies; agent state dies with it.
5. **Boot.** `@continuum-restore on` is set by canopy (ab37bf0). continuum replays the
   save when the server starts, provided it started within the restore delay, no
   other tmux server is running and continuum's halt file is absent. Each pane comes
   back as a shell into which resurrect types `sleep <n> && <agent> --resume <id>`.
6. **After restore.** The pane carries no canopy options, because resurrect saves
   none. Every reader recovers the id from the command the pane is running, so
   `reboot-check` reports the pane correctly and the next save keeps the stagger
   wrapper instead of falling back to a verbatim save (621e10e).

### 7.2 `canopy reboot-check`

Pre-flight: every agent pane, whether it will survive, and why not if not. Every
verdict is read off resurrect's save file, never off what canopy meant to save
(1bc0255). A pane counts as resuming only when the saved line, with the wrapper
stripped, equals its adapter's resume command for the id the pane carries now.

| Verdict | Means |
|---|---|
| `will resume` | the save holds this pane's resume command for its current id, and says whether the id came from the report or the pane's command |
| `will restart without its conversation` | no id anywhere, no usable resume command, or the save records something else |
| `not saved yet` | the save exists but does not have this pane |
| `will not be restored` | the restore path itself is off, so no pane comes back however well it was saved |

Exit 0 when every agent pane resumes or no server is running, 1 when any will not,
2 when persistence is misconfigured (§5.3). It also says when another tmux server is
running, using continuum's own arithmetic rather than a better one, because continuum
refuses to restore while one is and that is where a developer's machine stops
behaving like CI.

Two choices differ from the plan. A missing autosave hook in `status-right` is not an
exit-2 condition, since continuum skips the hook whenever a second server runs and a
pre-flight that cries wolf is worse than none; doctor checks the live hook instead.
Recency uses the newer of the save file's mtime and continuum's timestamp, because
resurrect leaves the file untouched when nothing changed. With `@resurrect-dir` unset,
it falls back to resurrect's own default location rather than canopy's state
directory, so it gives a true answer on a machine that has not switched yet (5aaac53).

### 7.3 `canopy adopt`

Restarts a hand-started agent pane in place, with `respawn-pane -k`, as its own resume
command, so the id sits in the pane's command where it survives anything that forgets
the option (bccb88f). Guards, derived from a real incident during design:

- dry run by default; `--yes` acts
- restart only when the agent reported `idle` or `completed`
- restart only when `detect_draft` says **no** unsent input; undetermined counts as yes
- never invent an id: a pane with no id is named and left alone, because minting one
  would pin the pane by throwing its conversation away
- a pane already running its resume command counts as adopted, so a second run never
  kills what the first fixed

`detect_draft` runs with `</dev/null` so a probe cannot swallow the pane list, and must
contain `{pane}` or it answers once for every pane (94435f6).

The motivating case: a pane held an unsent draft containing two pasted images, which
existed only in that process. Naive adoption destroys them.

**Consequence worth stating:** `adopt` skips every Claude Code pane, because Claude
Code cannot answer the draft question. Since 5aaac53 it is also rarely needed for
Claude Code: a pane started with `--session-id` is resumable without adoption.

### 7.4 Restore ergonomics

- **Stagger.** Ten agents spawning at once on boot is a thundering herd, so each saved
  resume command carries `sleep <n> && ` in front of it (19fab4e). The delay is
  derived from the pane pid multiplied by a prime, modulo the bound, so it is stable
  across saves and panes opened together (consecutive pids) are spread out.
  `@canopy_resume_stagger_ms` sets the bound, default 1000; `0` emits no wrapper; a
  value with a leading zero falls back to the default rather than being read as octal
  (6ef854a). The wrapper is a plain `sleep` and `&&` because a human may read or retype
  it from the save file, and its three shapes (emit, strip, match) live together in
  `lib/resume.sh`.
- **Autostart layer (opt-in, off by default). [planned, M6]** A launchd agent or
  systemd user unit starts the tmux server at login, so restore happens before a
  terminal is opened. Until then, restore happens when tmux is next started.

### 7.5 Vendoring

resurrect and continuum are copied into `plugins/` at the commits in `plugins/VERSIONS`
by `plugins/vendor.sh`: no submodule, no plugin manager, no fetch at runtime (c5eb8e2).
`vendor.sh` strips what git cannot reproduce (a nested `.gitignore`, `.gitmodules`,
resurrect's dangling symlinks into a submodule), so what it writes is what a checkout
reproduces, and `plugins/CHECKSUMS` records a digest per tree that doctor compares
against the bytes on disk.

The design allowed for a recorded patch against resurrect's tree. None was needed:
`@resurrect-save-command-strategy` is set to `../../strategies/canopy_save_command`,
which climbs out of resurrect's tree to `plugins/strategies/`, so upstream's bytes stay
exactly as vendored and CHECKSUMS keeps meaning "unmodified". A value that ever stops
resolving costs the agent rewrite, not the save, since resurrect falls back to `ps`. A
test builds the same path by hand and runs a real save through resurrect, so a pin that
breaks either half fails in CI (495df6b). `plugins/patches/` stays unwritten until a pin
needs it.

`30-plugins.conf` sets every option the plugins read (`@resurrect-dir`,
`@continuum-restore`, `@continuum-save-interval 5`, `@resurrect-strategy-nvim session`,
the strategy, the process list, the moved keys) **before** loading them, then loads
each through `if-shell` on `bash` and the script being present.

---

## 8. UI surfaces

**Status: planned, M4.** The palette, which-key menu and key search do not exist, and
`prefix :` and `prefix ?` are tmux's own. What ships is what they will read: the key
table (§4.4), its cheatsheet (`canopy keys --print`), and the command index.

| Surface | Trigger | Renderer | Backed by |
|---|---|---|---|
| Command palette | `prefix :` | `display-popup -E` + fzf, preview shows usage/args/examples | `commands.tsv` |
| Which-key menu | `prefix ?` | native `display-menu`, grouped | `keys.tsv` and `commands.tsv` |
| Key search | `prefix ?` → `/` | fzf over live `list-keys` ⨝ table descriptions | live tmux + table |

- **The index is generated**, at install, to `$CANOPY_STATE/commands.tsv`, by scanning
  the first 40 lines of each `bin/canopy-*` for `canopy:summary=`, `group`, `args` and
  `examples` headers. It ships; nothing reads it yet. doctor reports a command missing
  its summary header, and a test requires every `bin/canopy-*` to have a section in
  `docs/02` (d28d587).
- **Key search merges live `list-keys` with the table** so user-added bindings appear
  too. **[planned, M4]**
- **doctor cross-references** `list-keys` against the table. **[planned, M4]** It
  already compares table rows with the generated layer.
- **Extensions on `PATH`.** Any `canopy-*` executable on `PATH` with the metadata
  header being dispatched, indexed and bindable **[planned, M4, and deliberately
  so]**. The dispatcher scans and dispatches only `$CANOPY_STORE/bin/canopy-*`.
  Dispatching anything on `PATH` turns every writable `PATH` entry into a way to put
  code behind a canopy subcommand name, with no precedence rule for a name in both
  places, and makes `commands.tsv` machine-specific and doctor's summary check
  complain about a third party's script. Both questions belong with the surfaces that
  consume the index.
- **Fallbacks follow the layer rule:** without fzf, palette and search degrade to
  `display-menu`. **[planned, M4]**
- **Not copied from fut:** the 700 ms prefix-pause auto-hint. tmux has no prefix-timeout
  hook; emulating it needs a custom key-table with a timer, whose failure mode is a
  wedged key-table. `prefix ?` is one keystroke and always correct.

---

## 9. Themes

**Status: planned, M5.** No theme ships, and there is no `themes/`, `canopy theme`,
`60-theme.conf` or `current/theme`.

What is built is the seam a theme needs in tmux (1aa91b4). Every colour in the status
line is read from an `@theme_*` option (`bg`, `fg`, `blue`, `yellow`, `green`, `grey`,
`muted`, `red`) and the pill end-caps from `@pill_l` and `@pill_r`, so a theme repaints
the bar by setting options, with nothing to re-source. A test caps the number of hex
literals the status layer may hold, because a literal is a colour no theme can reach.
`@theme_red` is deliberately not meant to be repainted: a warning colour that changes
with the theme has to be learned twice.

A theme is **data**, not code:

```
themes/<name>/
  colors.toml      # canonical palette
  tmux.conf        # the @theme_* options, generated from the palette
  ghostty          # a ghostty theme file, dropped into the user's themes dir
  starship.toml    # overlay merged into the generated starship config
```

- `$CANOPY_STATE/current/theme` is a symlink to the active theme.
- `canopy theme set <name>` regenerates `60-theme.conf`, rewrites generated artifacts,
  and reloads tmux.
- Per-app theming is opt-in (§5.2) and additive.
- **Scope limit:** tmux, ghostty, starship. Nothing that requires writing executable
  config for another program (e.g. neovim lua) in v1. That is where config distros
  historically sink.

---

## 10. Worktree / project layer

**Status: planned, M6.** No `50-worktree.conf`, no session naming, no picker binds.
`canopy caps` records whether `wt` is present, and `canopy doctor` reports the worktree
layer as dormant when it is not. Windows are already named for their directory
(`00-core`), which is the window-level half of this.

- **No fourth level.** tmux has session/window/pane; the worktree directory on disk is
  the fourth level already, and `wt` (worktrunk) owns it. fut needs a workspace tier
  because nothing else tells it what a checkout is; canopy does not.
- **Context is a name prefix, not a container.** Sessions named
  `work/acme-api@feat-login` let the picker group by context and by project without
  inventing a hierarchy.
- The layer activates only when `wt` is present; otherwise dormant, reported by doctor.

---

## 11. Milestones and how they are verified

Each milestone ends in a capability a person can exercise on a machine that has never
seen canopy. The acceptance gate is a container run from a bare environment, not a
passing unit suite.

This rule was learned the hard way. Milestone 1 reached 93 green tests, a passing
restore proof and a clean lint while its installed configuration loaded nothing at all
on a real machine: the entry point expanded `$CANOPY_STORE` from the tmux server's
environment, which nothing set, and every test exported that variable first
(510f803). The verification ran in a richer environment than any user will ever have.

**The rule: every verification runs the shipped artifact through the same entry path a
user does, from a bare environment.** Unit tests may use conveniences for speed. The
acceptance scenario may not: no `CANOPY_*` exported, no helper sourced, no store path
assumed.

Two corollaries came later. A container is not a real machine either: the fixes in
621e10e, 5aaac53 and 9a243c6 came from pointing canopy at a working machine with live
agent panes, hundreds of resurrect saves and a TPM config, none of which a container has.
And a check has to be proven able to fail: scenario 7 was run with every saved resume
repointed at a conversation that did not exist, and caught it (ef20852).

| M | Capability delivered | Acceptance scenario, in a container, bare environment | State |
|---|---|---|---|
| **M1** | A machine can adopt canopy and shed it again without a trace | Scenarios 1 to 6 in `test/smoke/scenarios.sh`, on Debian and Alpine: a virgin machine; existing tmux, ghostty and starship configs; a symlinked `tmux.conf`; idempotence and recovery; a dangling symlink at the entry point; two user accounts on one machine. Each installs, starts tmux with no `CANOPY_*`, checks the config loaded and `doctor`, and requires `restore --all` to return the home byte-identical | **done.** Harness ed31528; last fixes 76e9fc0, d128d66; manual b06eedd |
| **M2** | A reboot returns every agent pane to its own conversation | Scenarios 7 and 8: three panes, `reboot-check` says all three will resume **before** anything is killed, the save holds each resume command, and after kill and restart each transcript reads `launch <id>` then `resume <id>`; and a pane that never reports an id is named by `reboot-check` (exit 1) without costing the other pane its conversation | **done.** ef20852, with the manual in 0554a17. Fixes found afterwards on a real machine: 621e10e, 5aaac53, 9a243c6 |
| **M3** | Agent state is visible across four agents without polling | Drive the report CLI as each adapter does, pane and window state reflect it, and the status line performs no subprocess per redraw beyond the one aggregator | **partly built.** The report CLI, pane options and the Claude Code adapter shipped with M2 (c15f63e), and the status line with its single aggregator (1aa91b4). Planned: rollups, formats, attention, three more adapters, `40-agents` |
| **M4** | Every command is reachable by key, CLI and palette from one definition | Open the palette and the which-key menu inside a container tmux; the key table matches `list-keys` exactly | **partly built.** The key table and generator (2e87036) and the command index. Planned: palette, which-key, key search, the `list-keys` cross-check |
| **M5** | A theme repaints tmux and, where opted in, ghostty and starship | `theme set` changes all opted-in surfaces, and the M1 scenarios still pass afterwards | **planned.** The `@theme_*` seam exists (1aa91b4) |
| **M6** | Worktrees are navigable as peers, and agents can return before first attach | Worktree sessions group by project; optional autostart brings panes back with no terminal opened | **planned** |

Ordering rationale: M1 makes everything else safe to install; M2 is the wedge and the
only urgent part; M3 makes `adopt` largely unnecessary by supplying session ids as a
byproduct; M4 to M6 are experience layers that assume the skeleton.

A milestone is not complete when its code exists and its unit tests pass. It is
complete when its container scenario passes.

---

## 12. Risks and open questions

| Risk | Mitigation |
|---|---|
| opencode, pi and codex capability tiers unknown | Recorded per adapter in M3; an agent that cannot resume by id gets no adapter and says so. |
| The save strategy depends on resurrect interpolating a relative path unsanitised (§7.5) | Pinned by a test that runs a real save through resurrect; a pin that changes it fails in CI, and the failure mode is losing the rewrite, not the save. |
| `TMUX_PANE` inheritance not yet observed with a real Claude Code hook | The manual check in `docs/07`. Tier 1 panes stay resumable without any report (5aaac53). Fallback is an explicit variable injected by a launch wrapper. |
| Persistence silently needs `bash` and a parent-reporting `ps` | doctor reports both, probing `ps` by running it (a54eb1c). canopy installs neither. |
| continuum refuses to restore while another tmux server runs | `reboot-check` says so; it is a property of the next boot, not a misconfiguration. |
| `adopt` can never act on a Claude Code pane | Documented; launch-time ids make it largely unnecessary. |
| Restore points accumulate without bound | Retention is designed but unbuilt, and carries the chain hazard in §5.5. |
| `extended-keys always` breaks option-as-alt in some macOS ghostty builds | Written beside the setting; `user.conf` can revert it. |
| The `%if` version guard compares numerically and will read tmux 3.10 as below 3.5 | Written beside it; revisit when tmux 3.10 exists. |
| Shell at scale (eleven commands, seven libraries, about 4,000 lines) | One command per file, metadata headers, bats per script, pinned shellcheck and shfmt in CI. Sidecar only behind a measured trigger (D5). |
| Third-party config integration ages badly across app versions | Opt-in per app, additive-only, capability-gated, and covered by the restore proof. The starship 1.26 finding is the archetype. |
| Theme scope creep into other apps' executable config | Hard scope limit in §9. |

---

## 13. Non-goals

- Rewriting or replacing tmux. (Replacing it is grofe's job, §14.)
- A plugin manager, plugin registry, or extension store.
- Managing system packages. canopy **declares and diagnoses** dependencies; it never
  installs them. It ships a `~/.config/mise/conf.d/canopy.toml` fragment; the user's
  own mise config is never edited.
- Theming programs whose configuration is executable code (v1).
- Supporting agents that expose no lifecycle events (they simply get no agent layer).

---

## 14. Relationship to grofe

canopy is the tmux-based path to this experience and the requirements source for
[grofe](https://github.com/morrieinmaas/grofe), a multiplexer written in Rust: what
canopy had to build around tmux, and what verifying it taught, is what grofe has to do
natively. canopy remains the path until grofe reaches parity with it, and then gains a
grofe backend.

# canopy design

**Date:** 2026-09-17
**Status:** approved in outline; M1 built, M2 to M6 not started
**Scope:** the whole product. v1 target is the full experience, built in ordered milestones (§11).

## How to read this document

This is a design for the whole product, written before any of it existed. Only
milestone 1, the skeleton, is built. Most of what follows therefore describes work
that has not been done, and the design itself has deliberately been left as it was
written.

So that a reader can tell the two apart, everything not yet implemented now carries an
explicit marker. **A sentence with no marker describes what the code does today.** The
markers are:

| Marker | Where | Means |
|---|---|---|
| **Status: planned, M`<n>`.** | first line of a section | nothing in that section is implemented; the sentence after it says what exists instead, when anything does |
| **Status: partly planned.** | first line of a section | some of the section is built; the markers inside it say which parts are not |
| **[planned, M`<n>`]** | end of a table row, bullet or sentence | that one item is not implemented. `unscheduled` in place of a milestone number means it is wanted but not assigned to one |
| **Correction:** | inline | the code deliberately went somewhere else, and this text was wrong rather than merely early |

The milestone number in a marker is the milestone that item belongs to, taken from §11.

Two claims were corrected rather than marked because they are decisions, not pending
work, and both are in §5.5: restore-point retention, which nothing implements and which
carries a hazard for whoever does, and post-restore verification, which the code
deliberately made a warning.

Where this document and the code disagree and the disagreement is not marked, the code
is what a machine runs. The user-facing documentation of what M1 actually does lives in
the [README](../../../README.md) and `docs/01` through `docs/06`.

---

## 1. What this is

canopy is an opinionated, agent-aware tmux experience: a preconfigured tmux setup,
a command namespace, themes, and an agent integration layer, distributed as a git
clone that updates itself.

**Status of that sentence: M1 ships the preconfigured tmux setup and the command
namespace.** Themes **[planned, M5]**, the agent integration layer **[planned, M2 and
M3]** and self-update **[planned, unscheduled]** do not exist. There is no `canopy
update` command; canopy is obtained by cloning the repository and is updated by pulling
it.

**The wedge: sessions survive reboot with agent conversations intact.** **[planned,
M2]** Nobody ships this. fut, the closest comparable project, states outright that
runtime state is not restored after its daemon exits or the machine restarts. tmux plus
resurrect/continuum can do it, and this project makes it work for agent panes, not
just shells.

**Second pillar: agent state as first-class tmux state.** **[planned, M3]** Five
normalized states pushed from agent hooks into tmux options, rendered with zero I/O in
the status line.

**What canopy is not:**

- Not a multiplexer. tmux is the runtime; we ship configuration, commands, and glue.
- Not a desktop config manager. Integration with non-tmux apps (ghostty, starship)
  is opt-in per app and strictly additive. **[planned, M5]** M1 integrates with no
  non-tmux app at all.
- Not a plugin manager. Plugins are vendored and pinned. **[planned, M2]** M1 vendors
  no plugin.
- Not dependent on any single tool beyond tmux itself: everything else degrades.

**Prior art, deliberately not rebuilt:** agent status-bar plugins already exist
(tmux-agent-indicator, agent-status-tmux, tmux-agent-status, tmux-agent-usage).
canopy's agent layer exists because it feeds persistence and navigation, not because
the world needs another status indicator.

---

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Core + optional layers.** Core needs tmux ≥ 3.4 and POSIX sh. fzf is strongly recommended (UI surfaces degrade to native `display-menu` without it). Agent, worktree, theme, picker layers activate when their tool is present. **[the optional layers are planned, M3 to M6]** M1 ships the core and the capability probe those layers will guard on; no optional layer file exists yet. | Broad audience without weak defaults. A missing tool changes fidelity, never availability. |
| D2 | **Clean-room core, port selectively.** athome keeps running its current config untouched until canopy reaches parity. | Avoids holding a daily driver with ~10 live agent panes hostage to a half-finished refactor. |
| D3 | **v1 target is the full experience**, decomposed into individually dogfoodable milestones (§11). | Owner's call, made with the scope risk stated. Decomposition is sequencing, not scope-cutting. |
| D4 | **Distribution: git clone + self-update.** `curl \| bash` clones to `~/.local/share/canopy`; `canopy update` = `git pull` + new timestamped migrations. **[planned, unscheduled]** There is no installer script, no `canopy update` and no migrations; see §4.1 for what distribution looks like today. | No release pipeline, no packaging lag, hacking is editing the clone. Migrations are what make maintenance real once other people run old versions. |
| D5 | **Pure shell + tmux.** No daemon, no compiled binary, no build step at install. A sidecar process is permitted only behind a measured trigger (rollup cost or hook chatter observed in practice). | The hot path is `tmux set` + `refresh-client -S`, both O(1). Rollups happen per state transition, not per frame. |
| D6 | **Name: canopy**, CLI `canopy`, alias `cnp`. **[the `cnp` alias is planned, unscheduled]** M1 ships `canopy` only. | Sits beside worktrunk and leaf; the layer above the trunks is where you see every agent at once. |

**Publishability rule (inherited from athome):** no identity, hostnames, client
names, or machine specifics in shipped files. Anything personal lives in the user
config directory, never in the store.

---

## 3. Verified facts

Everything the design leans on, with how it was checked. Unverified items are marked
and carry a fallback.

| Fact | Result | How |
|---|---|---|
| tmux `source-file` accepts globs | **yes** (tmux 3.7b) | two fragments loaded from `conf.d/*.conf` on a scratch socket |
| starship multi-config via colon-separated `STARSHIP_CONFIG` | **NO** (1.26.0) | `base.toml:user.toml` silently fell back to the default prompt; single path works. Upstream PR still open |
| ghostty `config-file` include exists | yes (docs) | docs reference; `?` prefix makes a missing file non-fatal |
| ghostty include *precedence* | **unverified** | CLI probe inconclusive. Design routes around it via the themes dir instead |
| ghostty user themes directory | yes | `+list-themes` labels sources; user already has `~/.config/ghostty/themes/` |
| mise auto-loads `~/.config/mise/conf.d/*.toml` | yes | mise docs/source; `[env]` merges additively |
| continuum autosave rides on `status-right` interpolation | yes | continuum README states it, and warns themes that overwrite `status-right` stop autosave |
| Claude Code `--session-id` cannot be reused | yes | second launch with same id → `Session ID … is already in use` |
| resurrect inline strategy (`->`, `*` arg token) rewrites restore commands | yes | full round trip: launch → save → kill server → restore → process running with rewritten `--resume <id>` |
| resurrect restore replays the saved command via `send-keys` into a fresh shell | yes | read from `process_restore_helpers.sh` |
| `TMUX_PANE` is inherited by agent hook subprocesses | **to verify** | mechanism is standard tmux env inheritance; confirm per agent during adapter work |

---

## 4. Architecture

### 4.1 Store layout

**Status: partly planned.** The path `~/.local/share/canopy` is a suggestion, not
something canopy establishes: no installer exists, so the store is wherever the
repository was cloned. `bin/canopy` derives it from the real path of the running
script, following symlinks, so the clone can live anywhere and `bin/canopy` may be
symlinked onto a `PATH`. Entries below marked planned are absent from the tree.

```
<clone>/                        # git clone; read-only by convention
                                # ~/.local/share/canopy is the suggested path,
                                # not one canopy creates or requires
  bin/canopy                    # dispatcher: scans siblings' metadata headers
  bin/canopy-*                  # one command per file
  lib/                          # env.sh, tmux.sh, manifest.sh
                                # (caps.sh: planned. The probe is bin/canopy-caps)
  tmux/tmux.conf                # entry point
  tmux/conf.d/*.conf            # layers, see 4.2 (only 00-core.conf exists)
  adapters/{claude-code,opencode,pi,codex}/   # planned, M3
  plugins/                      # vendored, pinned by commit -- planned, M2
  themes/<theme>/{tmux.conf,ghostty,starship.toml,colors.toml}   # planned, M5
  migrations/<epoch>.sh         # planned, unscheduled
  manual/NN-*.md                # planned. M1's prose lives in docs/ instead
```

**Distribution today:** clone the repository anywhere, put its `bin/` on `PATH` (or
symlink `bin/canopy` into a directory already on it), and run `canopy install`. There
is no `curl | bash` installer **[planned, unscheduled]** and no `canopy update`
**[planned, unscheduled]**; updating means pulling the clone.

**User-owned directories:**

- `~/.config/canopy/`: `user.conf`, `starship.user.toml` **[planned, M5]**, user themes
  **[planned, M5]**. Survives uninstall.
- `~/.local/state/canopy/`: caps cache, command index, backups. The `current/theme`
  symlink is **[planned, M5]**.
- `$XDG_RUNTIME_DIR/canopy/`: transient scratch files. Locks are **[planned]**; nothing
  in M1 takes one. Falls back to `/tmp/canopy-<uid>`, which canopy creates mode 0700
  and refuses to use if it is not exclusively the caller's.

Agent state lives in tmux options, not on disk: no cleanup, no reboot story of its own.
**[planned, M3]**

### 4.2 Layers and load order

Two of these nine exist. The `[1-9]*.conf` glob in the entry point matches nothing
today, and the entry point sources `$CANOPY_CONFIG/user.conf` directly rather than
through a `90-user` link.

| File | Owns | State |
|---|---|---|
| `00-core` | prefix, indexes, mouse, escape-time, history, terminal-features | ships. Deliberately small: base and pane indexes, escape-time, focus-events, history-limit, mouse, renumber-windows |
| `05-caps` | **generated**: capability flags as tmux options | ships, generated by `canopy caps` into `$CANOPY_STATE`, not into the store's `conf.d/` |
| `10-keys` | **generated** from the key table (4.4) | **[planned, M4]** |
| `20-status` | status line: pure `#{@…}` tokens, at most one aggregator `#()` | **[planned, M3]** |
| `30-plugins` | vendored plugin loads, incl. resurrect/continuum | **[planned, M2]** |
| `40-agents` | optional: hooks, pane-border and status formats | **[planned, M3]** |
| `50-worktree` | optional: wt-aware session naming, picker binds | **[planned, M6]** |
| `60-theme` | generated: sources the active theme's tmux fragment | **[planned, M5]** |
| `90-user` | symlink → `~/.config/canopy/user.conf`; loaded last | **Correction:** loaded last, but not as a file in `conf.d/` and not through a symlink. `tmux/tmux.conf` ends with `source-file -q "$CANOPY_CONFIG/user.conf"`, and `canopy doctor` asserts textually that this is the last `source-file` line in the entry point |

### 4.3 Capability model

Detection runs **once**, at install/update/doctor, and is written to `05-caps.conf` as
plain options (`set -g @canopy_has_wt 1`). Layer files guard on the option, never on a
subprocess, so sourcing the config tree forks nothing.

**Correction on where detection runs:** it runs in `canopy caps`, which `canopy
install` invokes. `canopy doctor` never re-probes; it reads `05-caps.conf` and reports
what the probe last found, so that doctor's report and tmux's options cannot disagree.
Re-running `canopy caps` after installing or removing a tool is the user's job.

Each layer is independently switchable (`@canopy_layer_agents off`) and
independently dead-able (missing capability). A disabled layer leaves zero bindings
and zero formats behind: no half-states. **[planned, M3 to M6]** No layer is switchable
today because no gated layer exists; `@canopy_layer_*` is not read anywhere.

`doctor` reports which layers are dormant **and why** ("worktree: wt not found"). That
section exists and prints exactly that, with the caveat stated in its own output and in
`docs/04`: with no gated layer shipped, it reports what each capability *will* enable.

### 4.4 Keys are data

**Status: planned, M4.** No key table exists, `10-keys.conf` is not generated, and M1
adds no binding to tmux's own. `canopy doctor` prints a line saying its `list-keys`
cross-check is stubbed until the table exists, rather than leaving the section out.

A single table declares every binding: `name, key, command, group, description`. It
generates `10-keys.conf` *and* feeds the palette, which-key menu, and cheatsheet
(§8). Every binding invokes a dispatcher command, so every binding has a description
and a group by construction; there are no orphan keys.

### 4.5 Environment resolution

`display-popup` and `run-shell` execute in the **tmux server's** environment, which
never sourced the user's shell rc. `lib/env.sh` resolves the toolchain once and every
`bin/` script sources it. Scripts must not hardcode tool paths individually.

**Correction on scope:** `lib/env.sh` exists and every `bin/` script sources it, but
what it resolves is canopy's own four paths (`CANOPY_STORE`, `CANOPY_CONFIG`,
`CANOPY_STATE`, `CANOPY_RUNTIME`), each of which must be absolute. It resolves no tool
paths; `canopy_have` is a `command -v` test and nothing more. M1 uses neither
`display-popup` nor `run-shell`, so the hazard the section is about is still ahead of
the code. What M1 did meet is the same hazard one level down: the installed entry point
expanded `$CANOPY_STORE` from the tmux server's environment, which nothing populates,
so `canopy install` now writes a stub carrying absolute literals and a
`set-environment -g` line for each of the three variables the store's `tmux.conf`
needs.

---

## 5. Install, ownership, and restore

### 5.1 The invariant

**We never write a file we don't own, and ownership is provable.** A file is ours only
if it is a symlink into our store, carries our marker block, or is a generated file
whose recorded hash still matches. Everything else is the user's.

**Preference order:** drop new files into an app's extension point → own a whole file
with a backup → splice into someone else's file. Splicing looks polite and behaves
badly; it is the last resort, marker-delimited, and rewritten only between markers.

**What M1 implements of that:** the marker block (`# canopy:entry-point`, written into
every entry point canopy creates, and how a re-run recognises its own file) and the
recorded hash (`manifest.tsv` records a pre-state and a post-state per path, and
restore refuses a path holding neither). canopy owns no file by symlinking it into the
store, and **splicing is not implemented [planned, M5]**: the manifest's `action`
vocabulary reserves `splice`, `generate` and `env`, and M1 writes only `own` and
`drop`. Taking over a path that is itself a symlink owns the **link**, never the bytes
at the other end.

### 5.2 Per-app integration

| App | What canopy does | Their file | State |
|---|---|---|---|
| tmux | owns the entry point; the user's existing config is backed up and re-sourced **last** as `90-user.conf` | backed up, replayed last | ships. **Correction:** the migrated content is appended to `~/.config/canopy/user.conf`, which the store's `tmux.conf` sources last. There is no `90-user.conf` |
| ghostty | drops a **new** theme file into `~/.config/ghostty/themes/` (collision-checked); optionally one marker-wrapped `theme =` line | untouched, or one line | **[planned, M5]** canopy never reads or writes anything under `~/.config/ghostty` today |
| starship | sets `STARSHIP_CONFIG` (via the mise `conf.d` fragment) to a **generated** file in canopy state, merged from our base + `~/.config/canopy/starship.user.toml` | **never touched** | **[planned, M5]** the mise fragment canopy writes carries a `[tools]` table only, declaring `fzf`, `gum` and `starship` as tools to install. It sets no `[env]`, so `STARSHIP_CONFIG` is never set |

Third-party (non-tmux) integration is **opt-in per app** (`canopy theme install ghostty`),
never performed by `install`. Blast radius stays where we can test it. **[planned, M5]**
There is no `canopy theme` command; M1 performs no third-party integration at all, opt-in
or otherwise. The one file it writes outside tmux's own tree is the mise fragment above,
and only when `mise` is installed or `~/.config/mise/conf.d` already exists.

For tmux specifically this is a **migration, not a merge**, and first run says so
explicitly rather than pretending to be additive.

### 5.3 Load-bearing settings

**Status: partly planned.** The four settings listed below are **[planned, M2 and
M3]**: each depends on a vendored plugin or an adapter that does not exist yet, so
there is nothing for doctor to assert about them. Doctor does assert a load-bearing set
today, and it is a different one, named at the end of this subsection.

A small set of settings cannot be left to user override without silently breaking the
product. `doctor` asserts them and names the escape hatch:

- `status-right` retains continuum's hook (verified failure mode: a theme overwriting
  `status-right` stops autosave silently; you find out after a reboot)
- `status-interval` stays above zero (same reason)
- `@resurrect-processes` covers every installed adapter's command
- `@continuum-restore` is on

**What doctor asserts today** is the M1 set, and a failure of any of them is what earns
exit 2 rather than a warning:

- tmux is at least 3.4
- the entry point tmux would actually load on this machine loads cleanly from a bare
  environment, on a throwaway socket
- `user.conf` is the last `source-file` line in the store's `tmux.conf`, so no later
  layer can be sourced after the user's own file and win instead

### 5.4 Two rollback classes, one guarantee

**Class A: config mutations.** Everything a fresh install does on a machine that
already has configs. Byte-captured before the change, **completely reversible,
forever**.

**Class B: canopy-owned state.** Caps cache, theme pointer **[planned, M5]**, adopt
records **[planned, M2]**. Did not exist before canopy. Migrations here are
forward-only, which is harmless because they cannot touch anything that predates
canopy. In M1 the class holds the caps cache, the command index and `backups/` itself.

**Enforcement:** a migration may not write to a user-owned file. If it must, it opens
a config transaction and becomes Class A. The categories are enforced by the code
path, not by the author remembering. **[planned, unscheduled]** M1 ships no migration,
so this is still a design rule and nothing in the code enforces it yet.

> **Invariant (goes in the README):** the pre-install restore point is complete and
> reachable forever, no matter how many updates and migrations have run since.
> `canopy restore --all` returns every file that existed before canopy to its exact
> original bytes.

### 5.5 Transactions and restore

Every mutating operation (`install`, `update` when it touches user-owned files
**[planned, unscheduled]**, `theme install <app>` **[planned, M5]**) opens a
transaction first. In M1 that means `canopy install` and `canopy restore` itself.

```
~/.local/state/canopy/backups/<ts>/
  manifest.tsv      # one row per recorded path: action (own|splice|drop|generate|env), pre-state (absent | sha256+copy), post-state sha256
  files/...         # byte copies of everything that existed before
  restore.sh        # self-contained POSIX sh
  dirs-created.txt  # directories this run created, shallowest first
  .committed        # marker, written when the operation finished
  .pinned           # marker, written on the pre-install point only
```

The id is `<epoch>-<label>`, and the manifest's `action` column uses `own` and `drop`
in M1; `splice`, `generate` and `env` are reserved for later milestones. `files/` holds
one copy per manifest **row**, copied with `cp -pP` so a symlink is copied as the link
it is.

Rules:

- **Restore is itself non-destructive.** A current-hash mismatch means the user edited
  the file after install; restore stops and names it rather than reverting newer work.
  `--force` proceeds. Either way restore opens its own restore point first.
- **The rollback tool does not depend on the thing it rolls back.** `restore.sh` is
  self-contained: no store, no dispatcher, no mise. It works when canopy itself is what
  broke.
- **The pre-install restore point is pinned and never pruned.** The pinning ships:
  `canopy install` writes `.pinned` on its own transaction after a successful commit,
  and `restore --list` marks it `PINNED`.
- **Retention: others roll off after the most recent 10, configurable via
  `@canopy_backup_keep`. [planned, unscheduled]** Nothing prunes anything today.
  `@canopy_backup_keep` does not exist, and restore points accumulate without bound:
  one per `canopy install`, and one per `canopy restore` as well, because restore
  records its own bytes before overwriting them.

  **Warning for whoever implements this.** Pruning is not "delete the oldest
  directories". Restore is replayed newest first, and each row is guarded by comparing
  the file's current state against that transaction's recorded `post`. Deleting a
  transaction in the middle of the chain can leave a file whose current bytes match
  only the deleted transaction's `post`, and no surviving transaction then recognises
  that state: the older rows see neither their `pre` nor their `post`, treat the file
  as user-edited, and keep it. The pinned pre-install point is still on disk and still
  says it is reachable, while `restore --all` can no longer reach it, which is exactly
  the guarantee in §5.4 failing quietly. Whatever retention ends up being, it has to
  reason about the chain rather than about ages, and the restore proof has to cover a
  pruned middle.
- **Restore reports on the result, and a config tmux dislikes is a warning, not a
  failure.** (**Correction.** This bullet used to read "restore verifies before
  declaring success", with a non-zero exit when the restored config failed to parse.
  The code deliberately went the other way and the code is right: what restore promises
  is the user's original bytes, and plugin-dependent or version-dependent configs
  routinely carry lines a bare tmux rejects. Exiting non-zero there reported a
  byte-perfect restore as a failure, directly beneath a summary reading `0 reverted, 0
  kept`. Non-zero is reserved for a restore that did not restore.) The restored config
  is still loaded on a throwaway socket from a bare environment and tmux's verdict is
  printed, so "your config is back" is never confused with "your config parses".
- **`~/.config/canopy/` is never touched** beyond the files a transaction recorded, so
  a user's own overrides in there survive a `restore --all` and keep the directory
  alive with them. `--purge` is a separate, explicit act **[planned, unscheduled]**:
  there is no `--purge` flag, because there is no `uninstall` for it to modify.
- Restore ends by printing what was reverted, what was kept, and where the kept things are.

| Command | Does | State |
|---|---|---|
| `canopy restore` | roll back the last transaction | ships |
| `canopy restore --list` | show restore points; marks the pinned pre-install point | ships. Also marks `FAILED` and `INCOMPLETE` points |
| `canopy restore --to <id>` | roll back to a specific point | ships. Rolls back that transaction and every eligible one newer than it |
| `canopy restore --all` | back to pre-install state | ships |
| `canopy uninstall` | `restore --all` + remove store and state (`--purge` also removes user overrides) | **[planned, unscheduled]** Removal is `canopy restore --all` followed by removing the three directories by hand; `docs/01` spells out the order and why it matters |

### 5.6 CI proves it

**Status: partly planned.** The update and migration steps below are **[planned,
unscheduled]**, because neither exists. What runs on every push is install →
`restore --all`, in two harnesses: `test/restore-proof.sh` records a full `find`
listing including directories plus a sha256 per file across three scenarios (a home
with real tmux, ghostty and starship configs; an empty home; a `tmux.conf` that is a
symlink to a target outside `$HOME`), on Ubuntu and macOS, and `test/smoke/run.sh` runs
six container scenarios in each of Debian and Alpine from a bare environment.
`docs/06` describes both.

An e2e job builds an image with a pre-existing `tmux.conf`, `ghostty/config` +
`themes/`, and `starship.toml`, records their hashes, then: install → update → run
migrations → `restore --all` → asserts every original file is byte-identical and no
canopy artifact remains. A restore promise that is not in CI stops being true around
version three.

---

## 6. Agent layer

**Status: planned, M2 and M3.** Nothing in this section is implemented. There is no
`canopy agent` command, no adapter, no `@canopy_agent_*` option and no `40-agents`
layer. M1's only connection to it is the capability probe, which records whether the
tools those layers will want are present.

### 6.1 Model

Five states, normalized across agents: `idle · working · blocked · completed · exited`.

```
canopy agent report <state> [--source <agent>] [--session-id <id>]
```

**Pane targeting needs no plumbing:** tmux exports `TMUX_PANE` into the pane
environment; the agent inherits it; the agent's hooks inherit it from the agent. When
the agent runs outside tmux (IDE, desktop, web), `TMUX_PANE` is absent and the adapter
exits 0 silently.

### 6.2 Write path

```
tmux set -p @canopy_agent_{state,source,session,ts}    # pane
tmux set -w @canopy_rollup "…"                          # precomputed rollup
tmux refresh-client -S                                  # push
```

**Debounce:** `report` reads the current value first and returns without writing when
unchanged, so chatty hooks (`PostToolUse`) cost one `tmux show` and nothing else. Only
real transitions touch rollups or refresh.

### 6.3 Render path

Pane borders use `#{@canopy_agent_state}`; window status uses `#{@canopy_rollup}`;
status-right uses the session rollup. **Pure format expansion, zero forks per redraw.**
The single aggregator `#()` budget is reserved for things that genuinely need sampling
(battery, pet).

### 6.4 Attention

`blocked` and `completed` set `@canopy_agent_unseen`; `set-hook -g pane-focus-in`
clears it (requires `focus-events on`). `canopy agent next` jumps to the oldest unseen
pane.

### 6.5 Adapters

Each adapter manifest declares five things; everything above that line is
agent-agnostic:

1. events → states map
2. how to read the agent's session id
3. resume command template
4. whether it can pre-pin an id at launch
5. how to detect unsent input in a pane (for `adopt`; UI-shaped, so it belongs here)

| Agent | Transport | Notable mapping |
|---|---|---|
| Claude Code | `hooks.json` + sh reporter | `Notification` matcher splits `permission_prompt`→blocked, `idle_prompt`→completed |
| opencode | TS plugin | `session.idle`→completed, `tool.execute.before`→working |
| pi | TS extension | `agent_settled`→completed, `ask_user` tool→blocked |
| codex | `notify` + hooks → sh bridge | `PermissionRequest`→blocked |

### 6.6 Capability tiers

| Tier | Agent can | Mechanism | Result |
|---|---|---|---|
| 1 | choose an id at launch **and** resume by id | pre-pin `--session-id` in argv | same conversation |
| 2 | resume by id only | canopy rewrites the saved command at save time | same conversation |
| 3 | neither | nothing to rewrite | agent restarts in the right cwd; conversation lost |

Claude Code is tier 1 (verified). Other tiers are recorded in each adapter's manifest
when that adapter is built. `canopy agent install <agent>` prints the tier at install
time; `doctor` shows the matrix for installed agents. **Users only meet the tiers of
agents they opted into.**

---

## 7. Persistence

**Status: planned, M2.** Nothing in this section is implemented. resurrect and
continuum are not vendored, there is no save-command strategy, and neither
`canopy reboot-check` nor `canopy adopt` exists. Installing canopy today does not make
a single pane survive a reboot.

### 7.1 Flow

1. **Launch:** adapter reports `idle` + session id → `@canopy_agent_session`.
2. **Save:** continuum triggers resurrect's save; canopy's vendored **save-command
   strategy** maps `PANE_PID → pane_id`, reads the pane's session option and the
   adapter's resume template, and writes the pane's saved command as
   `<resume template>`. Uniform for tiers 1 and 2. Launch-time pinning remains as a
   second channel, not the only one.
3. **Reboot:** tmux dies; agent state dies with it (derived, repopulated on restart).
4. **Boot:** continuum restores; panes come back running their resume commands;
   adapters repopulate state.

### 7.2 `canopy reboot-check`

Pre-flight: every agent pane, whether it will survive, and why not if not. Answering
"is it safe to reboot?" *before* the reboot is the product promise in one command.

### 7.3 `canopy adopt`

Brings panes lacking a pinned id under management. Guards, derived from a real
incident during design:

- dry-run by default
- skip panes whose agent is mid-task
- skip panes holding **unsent input** (adapter-provided detection)
- **fail closed** when it cannot tell

The motivating case: a pane held an unsent draft containing two pasted images, which
exist only in that process. Naive adoption destroys them.

### 7.4 Restore ergonomics

- **Stagger.** Ten agents spawning at once on boot is a thundering herd. The resume
  wrapper takes a small jitter; configurable; default on.
- **Autostart layer (opt-in, off by default).** A launchd agent / systemd user unit
  starts the tmux server at login so restore happens before a terminal is opened.

### 7.5 Vendoring

resurrect and continuum are pinned by commit under `plugins/` and loaded directly; no
TPM. The save-command strategy ships alongside. If resurrect insists on resolving
strategy files from inside its own tree, the vendor step applies a **recorded** patch
so updates re-apply it deterministically.

---

## 8. UI surfaces

**Status: planned, M4.** No surface in the table below exists. M1 binds no key at all,
so there is no `prefix :` and no `prefix ?`. The one part that ships is the index the
surfaces will read.

| Surface | Trigger | Renderer | Backed by |
|---|---|---|---|
| Command palette | `prefix :` | `display-popup -E` + fzf, preview shows usage/args/examples | generated command index |
| Which-key menu | `prefix ?` | native `display-menu`, grouped | same index |
| Key search | `prefix ?` → `/` | fzf over live `list-keys` ⨝ index descriptions | live tmux + index |

- **The index is generated once**, at install/update, to
  `~/.local/state/canopy/commands.tsv`, by scanning `bin/canopy-*` metadata headers.
  The palette reads one file rather than stat-ing thirty. This ships: `canopy index`
  writes it, `canopy install` runs it, and nothing reads it yet.
- **Key search merges live `list-keys` with the index** so user-added bindings appear
  too, with their command as the description. A cheatsheet that omits the user's own
  keys is worse than none. **[planned, M4]**
- **`doctor` cross-references** `list-keys` against the index: bindings without
  metadata are an error for ours, an FYI for the user's. **[planned, M4]** Doctor
  prints a line saying this check is stubbed until the key table exists. What it does
  check today is the other direction: every `bin/canopy-*` carrying a
  `canopy:summary=` header.
- **Extensions come free:** any executable named `canopy-*` on `PATH` with the metadata
  header is picked up by the dispatcher, appears in the palette, and can be bound. No
  manifest, no registry, no install step. **[planned, M4, and deliberately so]** The
  dispatcher scans and dispatches only `$CANOPY_STORE/bin/canopy-*`.

  **Decision: this stays planned rather than being implemented now.** It is not the
  small change it looks like. Dispatching whatever is named `canopy-*` anywhere on
  `PATH` turns every writable `PATH` entry into a way to put code behind a canopy
  subcommand name, with no precedence rule written down for a name that exists in both
  places. It also changes what the index is: `commands.tsv` is generated from the
  store, is identical on every machine with the same clone, and `doctor` reports a
  command in it that lacks a summary header as a defect. Scanning `PATH` makes the
  file machine-specific and makes doctor complain about a third party's script. Both
  questions belong with the surfaces that consume the index, which is M4, and none of
  it is needed before then. `docs/02` states the M1 behaviour plainly.
- **Fallbacks follow the layer rule:** without fzf, palette and search degrade to
  `display-menu`, which is built into tmux. **[planned, M4]**
- **Not copied from fut:** the 700 ms prefix-pause auto-hint. tmux has no prefix-timeout
  hook; emulating it needs a custom key-table with a timer, whose failure mode is a
  wedged key-table. `prefix ?` is one keystroke and always correct.

---

## 9. Themes

**Status: planned, M5.** No theme ships, `themes/` does not exist, there is no
`canopy theme` command, no `60-theme.conf` and no `current/theme` pointer.

A theme is **data**, not code:

```
themes/<name>/
  colors.toml      # canonical palette
  tmux.conf        # generated-from-palette tmux fragment
  ghostty          # a ghostty theme file, dropped into the user's themes dir
  starship.toml    # overlay merged into the generated starship config
```

- `~/.local/state/canopy/current/theme` is a symlink to the active theme.
- `canopy theme set <name>` regenerates `60-theme.conf`, rewrites generated artifacts,
  and reloads tmux.
- Per-app theming is opt-in (§5.2) and additive.
- **Scope limit:** tmux, ghostty, starship. Nothing that requires writing executable
  config for another program (e.g. neovim lua) in v1. That is where config distros
  historically sink.

---

## 10. Worktree / project layer

**Status: planned, M6.** The layer does not exist: no `50-worktree.conf`, no session
naming, no picker binds. What ships is the half of the last bullet that M1 can honour:
`canopy caps` records whether `wt` is present, and `canopy doctor` reports the worktree
layer as dormant when it is not.

- **No fourth level.** tmux has session/window/pane; the worktree directory on disk is
  the fourth level already, and `wt` (worktrunk) owns it. fut needs a workspace tier
  because nothing else tells it what a checkout is; canopy does not.
- **Context is a name prefix, not a container.** Sessions named
  `work/erasmusai@feat-netbird` let the picker group by context and by project without
  inventing a hierarchy. This preserves cockpit-style life-area contexts without
  conflicting with project/worktree identity.
- The layer activates only when `wt` is present; otherwise dormant, reported by doctor.

---

## 11. Milestones and how they are verified

Each milestone ends in a capability a person can exercise on a machine that has
never seen canopy. The acceptance gate is a container run from a bare
environment, not a passing unit suite.

This rule exists because it was learned the hard way. Milestone 1 reached 93
green tests, a passing restore proof and a clean lint while its installed
configuration loaded nothing at all on a real machine: the entry point expanded
`$CANOPY_STORE` from the tmux server's environment, which nothing set, and every
test exported that variable before invoking anything. The verification ran in a
richer environment than any user will ever have.

**The rule: every verification runs the shipped artifact through the same entry
path a user does, from a bare environment.** Unit tests may use conveniences for
speed. The acceptance scenario may not: no `CANOPY_*` exported, no helper
sourced, no store path assumed.

**Status: M1 is built and its container scenario passes. M2 to M6 are not started.**
The table is a plan for everything below the first row.

| M | Capability delivered | Acceptance scenario, in a container, bare environment |
|---|---|---|
| **M1** | A machine can adopt canopy and shed it again without a trace **[shipped]** | Virgin box: install, start tmux with no `CANOPY_*` set, canopy's config is loaded, `doctor` exits 0, `restore --all` returns `find $HOME` to its original listing. Box with pre-existing tmux, ghostty and a **symlinked** `tmux.conf`: same, and afterwards the symlink and its target are byte-identical |
| **M2** | A reboot returns every agent pane to its own conversation | Container with agent panes, kill the server to simulate the reboot, restart, each pane resumes its own session id, and `reboot-check` said so beforehand |
| **M3** | Agent state is visible across four agents without polling | Drive the report CLI as each adapter does, pane and window state reflect it, and the status line performs no subprocess per redraw |
| **M4** | Every command is reachable by key, CLI and palette from one definition | Open the palette and the which-key menu inside a container tmux, the generated index matches `list-keys` exactly |
| **M5** | A theme repaints tmux and, where opted in, ghostty and starship | `theme set` changes all opted-in surfaces, and the M1 scenario still passes afterwards |
| **M6** | Worktrees are navigable as peers, and agents can return before first attach | Worktree sessions group by project, optional autostart brings panes back with no terminal opened |

Ordering rationale: M1 makes everything else safe to install; M2 is the wedge and
the only urgent part; M3 makes M2's `adopt` trivial by supplying session ids as a
byproduct; M4 to M6 are experience layers that assume the skeleton.

A milestone is not complete when its code exists and its unit tests pass. It is
complete when its container scenario passes.

---

## 12. Risks and open questions

| Risk | Mitigation |
|---|---|
| opencode/pi capability tiers unknown | Recorded per adapter in M3; degrade to tier 3 with an explicit install-time message. Does not block M1–M2. |
| resurrect resolves strategy files only inside its own tree | Vendored tree + recorded patch re-applied on update (§7.5). |
| Shell at scale (~30 scripts) | One command per file, metadata headers, bats tests per script, shellcheck in CI. Sidecar only behind a measured trigger (D5). |
| Third-party config integration ages badly across app versions | Opt-in per app, additive-only, capability-gated, and covered by the restore CI proof. The starship 1.26 finding is the archetype. |
| `TMUX_PANE` inheritance not yet confirmed per agent | Verify during each adapter's work; fallback is an explicit env var injected by a launch wrapper. |
| Theme scope creep into other apps' executable config | Hard scope limit in §9. |

---

## 13. Non-goals

- Rewriting or replacing tmux.
- A plugin manager, plugin registry, or extension store.
- Managing system packages. canopy **declares and diagnoses** dependencies; it never
  installs them. It ships a `~/.config/mise/conf.d/canopy.toml` fragment; the user's
  own mise config is never edited.
- Theming programs whose configuration is executable code (v1).
- Supporting agents that expose no lifecycle events (they simply get no agent layer).

# canopy — design

**Date:** 2026-09-17
**Status:** approved in outline; implementation plan not yet written
**Scope:** the whole product. v1 target is the full experience, built in ordered milestones (§11).

---

## 1. What this is

canopy is an opinionated, agent-aware tmux experience: a preconfigured tmux setup,
a command namespace, themes, and an agent integration layer, distributed as a git
clone that updates itself.

**The wedge — sessions survive reboot with agent conversations intact.** Nobody
ships this. fut, the closest comparable project, states outright that runtime state
is not restored after its daemon exits or the machine restarts. tmux plus
resurrect/continuum can do it, and this project makes it work for agent panes, not
just shells.

**Second pillar — agent state as first-class tmux state.** Five normalized states
pushed from agent hooks into tmux options, rendered with zero I/O in the status line.

**What canopy is not:**

- Not a multiplexer. tmux is the runtime; we ship configuration, commands, and glue.
- Not a desktop config manager. Integration with non-tmux apps (ghostty, starship)
  is opt-in per app and strictly additive.
- Not a plugin manager. Plugins are vendored and pinned.
- Not dependent on any single tool beyond tmux itself: everything else degrades.

**Prior art, deliberately not rebuilt:** agent status-bar plugins already exist
(tmux-agent-indicator, agent-status-tmux, tmux-agent-status, tmux-agent-usage).
canopy's agent layer exists because it feeds persistence and navigation, not because
the world needs another status indicator.

---

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Core + optional layers.** Core needs tmux ≥ 3.4 and POSIX sh. fzf is strongly recommended (UI surfaces degrade to native `display-menu` without it). Agent, worktree, theme, picker layers activate when their tool is present. | Broad audience without weak defaults. A missing tool changes fidelity, never availability. |
| D2 | **Clean-room core, port selectively.** athome keeps running its current config untouched until canopy reaches parity. | Avoids holding a daily driver with ~10 live agent panes hostage to a half-finished refactor. |
| D3 | **v1 target is the full experience**, decomposed into individually dogfoodable milestones (§11). | Owner's call, made with the scope risk stated. Decomposition is sequencing, not scope-cutting. |
| D4 | **Distribution: git clone + self-update.** `curl \| bash` clones to `~/.local/share/canopy`; `canopy update` = `git pull` + new timestamped migrations. | No release pipeline, no packaging lag, hacking is editing the clone. Migrations are what make maintenance real once other people run old versions. |
| D5 | **Pure shell + tmux.** No daemon, no compiled binary, no build step at install. A sidecar process is permitted only behind a measured trigger (rollup cost or hook chatter observed in practice). | The hot path is `tmux set` + `refresh-client -S`, both O(1). Rollups happen per state transition, not per frame. |
| D6 | **Name: canopy**, CLI `canopy`, alias `cnp`. | Sits beside worktrunk and leaf; the layer above the trunks is where you see every agent at once. |

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

```
~/.local/share/canopy/          # git clone; read-only by convention
  bin/canopy                    # dispatcher: scans siblings' metadata headers
  bin/canopy-*                  # one command per file
  lib/                          # env.sh, tmux.sh, manifest.sh, caps.sh
  tmux/tmux.conf                # entry point (~12 lines)
  tmux/conf.d/*.conf            # layers, see 4.2
  adapters/{claude-code,opencode,pi,codex}/
  plugins/                      # vendored, pinned by commit
  themes/<theme>/{tmux.conf,ghostty,starship.toml,colors.toml}
  migrations/<epoch>.sh
  manual/NN-*.md
```

**User-owned directories:**

- `~/.config/canopy/` — `user.conf`, `starship.user.toml`, user themes. Survives uninstall.
- `~/.local/state/canopy/` — caps cache, command index, backups, `current/theme` symlink.
- `$XDG_RUNTIME_DIR/canopy/` — locks, transient.

Agent state lives in tmux options, not on disk: no cleanup, no reboot story of its own.

### 4.2 Layers and load order

| File | Owns |
|---|---|
| `00-core` | prefix, indexes, mouse, escape-time, history, terminal-features |
| `05-caps` | **generated** — capability flags as tmux options |
| `10-keys` | **generated** from the key table (4.4) |
| `20-status` | status line: pure `#{@…}` tokens, at most one aggregator `#()` |
| `30-plugins` | vendored plugin loads, incl. resurrect/continuum |
| `40-agents` | optional — hooks, pane-border and status formats |
| `50-worktree` | optional — wt-aware session naming, picker binds |
| `60-theme` | generated — sources the active theme's tmux fragment |
| `90-user` | symlink → `~/.config/canopy/user.conf`; loaded last |

### 4.3 Capability model

Detection runs **once**, at install/update/doctor, and is written to `05-caps.conf` as
plain options (`set -g @canopy_has_wt 1`). Layer files guard on the option, never on a
subprocess, so sourcing the config tree forks nothing.

Each layer is independently switchable (`@canopy_layer_agents off`) and
independently dead-able (missing capability). A disabled layer leaves zero bindings
and zero formats behind — no half-states. `doctor` reports which layers are dormant
**and why** ("worktree: wt not found").

### 4.4 Keys are data

A single table declares every binding: `name, key, command, group, description`. It
generates `10-keys.conf` *and* feeds the palette, which-key menu, and cheatsheet
(§8). Every binding invokes a dispatcher command, so every binding has a description
and a group by construction; there are no orphan keys.

### 4.5 Environment resolution

`display-popup` and `run-shell` execute in the **tmux server's** environment, which
never sourced the user's shell rc. `lib/env.sh` resolves the toolchain once and every
`bin/` script sources it. Scripts must not hardcode tool paths individually.

---

## 5. Install, ownership, and restore

### 5.1 The invariant

**We never write a file we don't own, and ownership is provable.** A file is ours only
if it is a symlink into our store, carries our marker block, or is a generated file
whose recorded hash still matches. Everything else is the user's.

**Preference order:** drop new files into an app's extension point → own a whole file
with a backup → splice into someone else's file. Splicing looks polite and behaves
badly; it is the last resort, marker-delimited, and rewritten only between markers.

### 5.2 Per-app integration

| App | What canopy does | Their file |
|---|---|---|
| tmux | owns the entry point; the user's existing config is backed up and re-sourced **last** as `90-user.conf` | backed up, replayed last |
| ghostty | drops a **new** theme file into `~/.config/ghostty/themes/` (collision-checked); optionally one marker-wrapped `theme =` line | untouched, or one line |
| starship | sets `STARSHIP_CONFIG` (via the mise `conf.d` fragment) to a **generated** file in canopy state, merged from our base + `~/.config/canopy/starship.user.toml` | **never touched** |

Third-party (non-tmux) integration is **opt-in per app** — `canopy theme install ghostty`
— never performed by `install`. Blast radius stays where we can test it.

For tmux specifically this is a **migration, not a merge**, and first run says so
explicitly rather than pretending to be additive.

### 5.3 Load-bearing settings

A small set of settings cannot be left to user override without silently breaking the
product. `doctor` asserts them and names the escape hatch:

- `status-right` retains continuum's hook (verified failure mode: a theme overwriting
  `status-right` stops autosave silently — you find out after a reboot)
- `status-interval` stays above zero (same reason)
- `@resurrect-processes` covers every installed adapter's command
- `@continuum-restore` is on

### 5.4 Two rollback classes, one guarantee

**Class A — config mutations.** Everything a fresh install does on a machine that
already has configs. Byte-captured before the change, **completely reversible,
forever**.

**Class B — canopy-owned state.** Caps cache, theme pointer, adopt records. Did not
exist before canopy. Migrations here are forward-only, which is harmless because they
cannot touch anything that predates canopy.

**Enforcement:** a migration may not write to a user-owned file. If it must, it opens
a config transaction and becomes Class A. The categories are enforced by the code
path, not by the author remembering.

> **Invariant (goes in the README):** the pre-install restore point is complete and
> reachable forever, no matter how many updates and migrations have run since.
> `canopy restore --all` returns every file that existed before canopy to its exact
> original bytes.

### 5.5 Transactions and restore

Every mutating operation (`install`, `update` when it touches user-owned files,
`theme install <app>`) opens a transaction first:

```
~/.local/state/canopy/backups/<ts>/
  manifest.json     # per path: action (own|splice|drop|generate|env), pre-state (absent | sha256+copy), post-state sha256
  files/...         # byte copies of everything that existed before
  restore.sh        # self-contained POSIX sh
```

Rules:

- **Restore is itself non-destructive.** A current-hash mismatch means the user edited
  the file after install; restore stops and names it rather than reverting newer work.
  `--force` proceeds. Either way restore opens its own restore point first.
- **The rollback tool does not depend on the thing it rolls back.** `restore.sh` is
  self-contained: no store, no dispatcher, no mise. It works when canopy itself is what
  broke.
- **The pre-install restore point is pinned and never pruned.** Others roll off after the
  most recent 10, configurable via `@canopy_backup_keep`.
- **Restore verifies before declaring success:** the restored tmux config is loaded on a
  throwaway socket (`tmux -L canopy-verify -f <file>`) so "your config is back" means it
  parses.
- **`~/.config/canopy/` is never touched.** `--purge` is a separate, explicit act.
- Restore ends by printing what was reverted, what was kept, and where the kept things are.

| Command | Does |
|---|---|
| `canopy restore` | roll back the last transaction |
| `canopy restore --list` | show restore points; marks the pinned pre-install point |
| `canopy restore --to <id>` | roll back to a specific point |
| `canopy restore --all` | back to pre-install state |
| `canopy uninstall` | `restore --all` + remove store and state (`--purge` also removes user overrides) |

### 5.6 CI proves it

An e2e job builds an image with a pre-existing `tmux.conf`, `ghostty/config` +
`themes/`, and `starship.toml`, records their hashes, then: install → update → run
migrations → `restore --all` → asserts every original file is byte-identical and no
canopy artifact remains. A restore promise that is not in CI stops being true around
version three.

---

## 6. Agent layer

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

### 7.1 Flow

1. **Launch** — adapter reports `idle` + session id → `@canopy_agent_session`.
2. **Save** — continuum triggers resurrect's save; canopy's vendored **save-command
   strategy** maps `PANE_PID → pane_id`, reads the pane's session option and the
   adapter's resume template, and writes the pane's saved command as
   `<resume template>`. Uniform for tiers 1 and 2. Launch-time pinning remains as a
   second channel, not the only one.
3. **Reboot** — tmux dies; agent state dies with it (derived, repopulated on restart).
4. **Boot** — continuum restores; panes come back running their resume commands;
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

| Surface | Trigger | Renderer | Backed by |
|---|---|---|---|
| Command palette | `prefix :` | `display-popup -E` + fzf, preview shows usage/args/examples | generated command index |
| Which-key menu | `prefix ?` | native `display-menu`, grouped | same index |
| Key search | `prefix ?` → `/` | fzf over live `list-keys` ⨝ index descriptions | live tmux + index |

- **The index is generated once**, at install/update, to
  `~/.local/state/canopy/commands.tsv`, by scanning `bin/canopy-*` metadata headers.
  The palette reads one file rather than stat-ing thirty.
- **Key search merges live `list-keys` with the index** so user-added bindings appear
  too, with their command as the description. A cheatsheet that omits the user's own
  keys is worse than none.
- **`doctor` cross-references** `list-keys` against the index: bindings without
  metadata are an error for ours, an FYI for the user's.
- **Extensions come free:** any executable named `canopy-*` on `PATH` with the metadata
  header is picked up by the dispatcher, appears in the palette, and can be bound. No
  manifest, no registry, no install step.
- **Fallbacks follow the layer rule:** without fzf, palette and search degrade to
  `display-menu`, which is built into tmux.
- **Not copied from fut:** the 700 ms prefix-pause auto-hint. tmux has no prefix-timeout
  hook; emulating it needs a custom key-table with a timer, whose failure mode is a
  wedged key-table. `prefix ?` is one keystroke and always correct.

---

## 9. Themes

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
  config for another program (e.g. neovim lua) in v1 — that is where config distros
  historically sink.

---

## 10. Worktree / project layer

- **No fourth level.** tmux has session/window/pane; the worktree directory on disk is
  the fourth level already, and `wt` (worktrunk) owns it. fut needs a workspace tier
  because nothing else tells it what a checkout is; canopy does not.
- **Context is a name prefix, not a container.** Sessions named
  `work/erasmusai@feat-netbird` let the picker group by context and by project without
  inventing a hierarchy. This preserves cockpit-style life-area contexts without
  conflicting with project/worktree identity.
- The layer activates only when `wt` is present; otherwise dormant, reported by doctor.

---

## 11. Milestones

Each milestone is independently dogfoodable; each ends in a state where canopy is
usable on a real machine.

| M | Content | Done means |
|---|---|---|
| **M1** | store skeleton, dispatcher + metadata headers, `lib/env.sh`, conf.d loader, caps model, `doctor`, transactions + `restore` + CI restore proof | install onto a machine with existing configs, then `restore --all` returns it byte-identical |
| **M2** | vendored resurrect/continuum, save-command strategy, Claude Code adapter, `reboot-check`, `adopt` with guards, stagger | a real reboot returns every claude pane to its own conversation, verified end to end |
| **M3** | agent layer proper: report CLI, rollups, render tokens, seen/unseen, `agent next`; opencode + pi + codex adapters with tiers recorded | four agents report; status and borders reflect state with zero forks per redraw |
| **M4** | palette, which-key, key search, generated index, manual generation | every command reachable by key, CLI, and palette from one definition |
| **M5** | theme system + tmux/ghostty/starship theming, opt-in per app | `theme set` repaints tmux and (opted-in) ghostty/starship; restore still passes CI |
| **M6** | worktree layer, session naming and picker grouping, autostart layer | worktrees navigable as peers; optional login autostart brings agents back before first attach |

Ordering rationale: M1 makes everything else safe to install; M2 is the wedge and the
only part that is urgent; M3 makes M2's `adopt` trivial by supplying session ids as a
byproduct; M4–M6 are experience layers that assume the skeleton.

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

# canopy M2 — Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reboot returns every agent pane to its own conversation, and `canopy reboot-check` says so truthfully beforehand.

**Architecture:** tmux-resurrect and tmux-continuum are vendored at pinned commits and loaded directly, no plugin manager. canopy supplies resurrect with its own save-command strategy, which rewrites an agent pane's saved command into that agent's resume command using the session id the pane already carries. Session ids arrive from an adapter: a small, one-way lifecycle reporter installed into the agent's own configuration. Nothing polls, and nothing runs during a redraw.

**Tech Stack:** POSIX sh, tmux 3.4 or newer, bats, shellcheck, shfmt, Docker for acceptance.

**Spec:** `docs/superpowers/specs/2026-09-17-canopy-design.md`, sections 6 and 7.

**Base:** branches from `m1-skeleton`. M1's macOS CI fix may land after this branch is cut; merge `m1-skeleton` forward rather than rebasing.

## Global Constraints

Everything in M1's Global Constraints still applies. In addition:

- **POSIX sh only** in `bin/` and `lib/`; test files may use bash.
- **No hardcoded paths.** `CANOPY_STORE|CONFIG|STATE|RUNTIME` are the only roots.
- **Nothing in a render path may fork.** Agent state is read from tmux options as `#{@…}`. A status line that shells out per redraw is a defect, not a style choice.
- **Verification runs the shipped artifact from a bare environment.** No `CANOPY_*` exported, no helper sourced. A milestone is complete when its container scenario passes, not when its unit tests do.
- **Never `env -i`.** Unset exactly `CANOPY_STORE`, `CANOPY_STATE`, `CANOPY_CONFIG`, `CANOPY_RUNTIME` when isolation is needed. Stripping the whole environment breaks tool resolution when a binary is reached through a shim, which is how M1's macOS CI broke.
- **Safety in tests:** every tmux command carries `-L <unique>`; never the default socket. Every test that runs `install` or `restore` sets `HOME` and `XDG_CONFIG_HOME` under `$BATS_TEST_TMPDIR`.
- **Writing rule:** never an em dash as a sentence break, including commit messages and comments.

## The test double, and why it exists

M2's acceptance cannot run a real coding agent: Claude Code needs credentials and a network, and a container has neither. So the contract is tested against a **fake agent**, `test/fixtures/fake-agent`, which implements exactly the adapter contract and nothing else: it accepts `--session-id <uuid>` and `--resume <uuid>`, it appends to a transcript file named for its session id, and it reports lifecycle states through canopy's reporter. The container scenario drives the fake agent; the real Claude Code path is verified by a documented manual procedure in `docs/`.

This is an honest boundary, not a shortcut. What the container proves is that canopy saves, restores, and resumes *the right session id per pane*. What it cannot prove is that Claude Code's own `--resume` behaves; that was verified by hand during design, including that a session id cannot be reused for a second launch.

---

## Task 1: Vendor resurrect and continuum at pinned commits

**Files:**
- Create: `plugins/README.md`, `plugins/vendor.sh`, `plugins/tmux-resurrect/…`, `plugins/tmux-continuum/…`
- Modify: `tmux/conf.d/30-plugins.conf`, `bin/canopy-doctor`
- Test: `test/plugins.bats`

**Interfaces:**
- Produces: `plugins/VERSIONS` — one line per plugin, `<name> <upstream-url> <commit-sha>`. `doctor` reads it and reports each plugin's pinned commit and whether the tree on disk matches.
- `plugins/vendor.sh <name>` re-vendors one plugin at the pinned commit, for updating later.

- [x] **Step 1: Write the failing test** — `test/plugins.bats` asserts `plugins/VERSIONS` exists with both plugins, that each named directory exists and is not a git submodule or a symlink, and that loading `30-plugins.conf` on a scratch socket defines a resurrect key binding.
- [x] **Step 2: Run it, observe failure.**
- [x] **Step 3: Vendor both plugins** by copying the upstream trees at a chosen commit, excluding their `.git`. Record the commit in `plugins/VERSIONS`. `30-plugins.conf` sources them by absolute path derived from the store, never by a plugin-manager call.
- [x] **Step 4: Teach doctor** to report the pinned commits and flag a modified vendored tree.
- [x] **Step 5: Run tests, lint, commit** — `feat(plugins): vendor resurrect and continuum at pinned commits`

---

## Task 2: The adapter contract and the fake agent

**Files:**
- Create: `docs/adapters/contract.md`, `test/fixtures/fake-agent`, `test/fixtures/fake-agent-adapter/`
- Test: `test/fake_agent.bats`

**Interfaces:**
- An adapter is a directory containing `manifest` with exactly these keys, one per line, `key=value`:
  - `id` — adapter name, for example `claude-code`
  - `command` — the process name canopy matches in a pane, for example `claude`
  - `resume_template` — the command to resume a session, with `{id}` as the placeholder, for example `claude --resume {id}`
  - `can_pin_at_launch` — `yes` or `no`, whether the agent accepts a caller-chosen id at launch
  - `launch_template` — used when `can_pin_at_launch=yes`, with `{id}`, for example `claude --session-id {id}`
- Produces: `canopy_adapter_get <id> <key>` in `lib/adapter.sh`, plus `canopy_adapter_list`.
- `test/fixtures/fake-agent` accepts `--session-id <uuid>` or `--resume <uuid>`, appends a line to `$FAKE_AGENT_HOME/<uuid>.transcript`, and stays alive until killed.

- [x] **Step 1: Write the failing tests** — reading each manifest key, rejecting a manifest with an unknown key, and the fake agent appending to the transcript named for the id it was given.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement** `lib/adapter.sh` and the fixture.
- [x] **Step 4: Write `docs/adapters/contract.md`**, the five keys and what each means, so M3's three further adapters have one document to conform to.
- [x] **Step 5: Tests, lint, commit** — `feat(lib): adapter contract, with a fake agent to test it`

---

## Task 3: `canopy agent report`, and the Claude Code adapter

**Files:**
- Create: `bin/canopy-agent`, `adapters/claude-code/manifest`, `adapters/claude-code/hooks.json`, `adapters/claude-code/report.sh`
- Test: `test/agent_report.bats`

**Interfaces:**
- `canopy agent report <state> [--source <id>] [--session-id <uuid>]` where state is one of `idle working blocked completed exited`.
- Writes to the pane named by `$TMUX_PANE`: `@canopy_agent_state`, `@canopy_agent_source`, `@canopy_agent_session`, `@canopy_agent_ts`. Exits 0 silently when `$TMUX_PANE` is unset, which is the case when the agent runs outside tmux.
- Reads the current value first and returns without writing when unchanged, so a chatty hook costs one `tmux show`.
- `canopy agent install <adapter-id>` installs the adapter into that agent's own configuration, as a transaction so `restore` undoes it.

- [x] **Step 1: Write the failing tests** — a report writes all four options; an unchanged state does not rewrite; no `TMUX_PANE` exits 0 and writes nothing; an invalid state is rejected.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement** `bin/canopy-agent` with a metadata header, and the Claude Code adapter files mapping its documented hook events to the five states.
- [x] **Step 4: Make `canopy agent install` transactional**, reusing `lib/manifest.sh`, so installing an adapter is as reversible as installing canopy.
- [x] **Step 5: Tests, lint, commit** — `feat(bin): agent state reporting, and the Claude Code adapter`

---

## Task 4: The save-command strategy

**Files:**
- Create: `plugins/strategies/canopy_save_command.sh`
- Modify: `tmux/conf.d/30-plugins.conf`, `plugins/vendor.sh`
- Test: `test/save_strategy.bats`

**Interfaces:**
- resurrect calls a save-command strategy with a pane's pid and expects the command to record for that pane. canopy's strategy maps pid to pane id, reads `@canopy_agent_session` and `@canopy_agent_source`, looks up the adapter's `resume_template`, and prints the resumed command. For a pane with no agent session it prints what resurrect would have printed, unchanged.
- If resurrect resolves strategies only from inside its own tree, `vendor.sh` applies a **recorded** patch so re-vendoring re-applies it deterministically. Record the patch in `plugins/patches/`.

- [x] **Step 1: Write the failing test** — a pane running the fake agent with a session option produces `fake-agent --resume <uuid>`; a plain shell pane is unchanged; an agent pane whose adapter is unknown is unchanged rather than mangled.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement**, including the vendor patch if needed.
- [x] **Step 4: Tests, lint, commit** — `feat(plugins): save agent panes as their own resume command`

---

## Task 5: `canopy reboot-check`

**Files:**
- Create: `bin/canopy-reboot-check`
- Test: `test/reboot_check.bats`

**Interfaces:**
- Lists every pane running a known adapter's `command`. Per pane: session name, window, pane, adapter, and a verdict of `will resume`, `will restart without its conversation`, or `not saved yet`, each with the reason.
- Exit 0 when every agent pane will resume, 1 when any will not, 2 when persistence itself is misconfigured, for example continuum's autosave hook missing from `status-right` or `status-interval` at zero.

- [x] **Step 1: Write the failing tests** — one pane with a session id reports `will resume`; one without reports `will restart without its conversation` and exits 1; removing continuum's hook from `status-right` yields exit 2 naming that setting.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement.**
- [x] **Step 4: Tests, lint, commit** — `feat(bin): reboot-check, a truthful pre-flight for persistence`

---

## Task 6: `canopy adopt`

**Files:**
- Create: `bin/canopy-adopt`
- Modify: `docs/adapters/contract.md` (adds the draft-detection key)
- Test: `test/adopt.bats`

**Interfaces:**
- Brings panes without a pinned session id under management: reads the pane's `@canopy_agent_session` when present, otherwise asks the adapter, then restarts the pane in place with the adapter's resume command.
- **Guards, all of them, because this command kills and restarts live work:**
  - dry run by default; `--yes` to act
  - skip a pane whose agent is mid-task
  - skip a pane holding unsent input, detected by an adapter-provided `detect_draft` command
  - fail closed: when it cannot tell, skip and say so
- Never touches a pane that is not running a known adapter's command.

- [x] **Step 1: Write the failing tests** — dry run changes nothing; a pane with unsent input is skipped and named; a pane whose state cannot be determined is skipped; `--yes` restarts a clean pane with the right resume command.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement.**
- [x] **Step 4: Tests, lint, commit** — `feat(bin): adopt, with guards that fail closed`

---

## Task 7: Staggered resume

**Files:**
- Modify: `plugins/strategies/canopy_save_command.sh` or a small wrapper it emits
- Test: `test/stagger.bats`

**Interfaces:**
- Restoring ten agent panes at once starts ten agents at once. The emitted resume command is wrapped so each pane waits a small, bounded, configurable delay before starting, default on, controlled by `@canopy_resume_stagger_ms`.
- Setting the option to `0` disables it exactly, with no wrapper emitted.

- [x] **Step 1: Write the failing test** — the emitted command contains the wrapper by default, contains no wrapper at `0`, and the delay is bounded by the option's value.
- [x] **Step 2: Run, observe failure.**
- [x] **Step 3: Implement.**
- [x] **Step 4: Tests, lint, commit** — `feat(plugins): stagger agent resumes so a reboot is not a thundering herd`

---

## Task 8: The container acceptance scenario

**Files:**
- Modify: `test/smoke/scenarios.sh`, `test/smoke/run.sh`, both Dockerfiles
- Modify: `.github/workflows/smoke.yml`

**Interfaces:**
- **Scenario 7, reboot:** in the container, start a tmux server with three panes each running the fake agent with a distinct session id, write a distinguishable line into each transcript, run `canopy reboot-check` and assert exit 0 with all three reported as resuming, force a continuum save, `kill-server` to simulate the reboot, start tmux again so the restore runs, then assert each pane is running the fake agent resumed with **its own** id and that each transcript is intact and belongs to the right pane.
- **Scenario 8, honest failure:** one pane runs the fake agent with no session id. `reboot-check` must exit 1 and name that pane, and after the simulated reboot that pane restarts without its conversation while the others keep theirs.

- [x] **Step 1: Write scenario 7 and watch it fail** against the code before Tasks 3 to 7 exist, or against a deliberately broken strategy if it is written last.
- [x] **Step 2: Implement the scenario helpers** needed for a simulated reboot inside one container.
- [x] **Step 3: Run `test/smoke/run.sh` on both images**, confirm 16 of 16.
- [x] **Step 4: Prove the scenario can fail** by tampering with the saved command, and confirm the harness reports it with expected and observed values.
- [x] **Step 5: Commit** — `test(smoke): a simulated reboot returns each agent pane to its own conversation`

---

## Task 9: Documentation

**Files:**
- Create: `docs/07-persistence.md`, `docs/08-agents.md`
- Modify: `README.md`, `docs/02-commands.md`, `docs/05-troubleshooting.md`, `docs/superpowers/specs/2026-09-17-canopy-design.md`

**Interfaces:**
- `docs/07-persistence.md` explains what survives a reboot and what does not, how the save strategy works, the load-bearing settings doctor defends, and the manual procedure for verifying with a real agent rather than the fake one.
- `docs/08-agents.md` explains the adapter contract, how to install the Claude Code adapter, and the capability tiers, marking the three M3 adapters as planned.
- The spec's M2 rows move from planned to implemented; nothing else changes status.

- [ ] **Step 1: Write the pages**, verifying every command and flag against the code rather than the spec.
- [ ] **Step 2: Update the README's status and roadmap** so M2 is described as it actually is.
- [ ] **Step 3: Commit** — `docs: persistence and the agent adapter contract`

---

## Self-Review

**Spec coverage:** section 7.1 flow is Tasks 3, 4 and 8; 7.2 `reboot-check` is Task 5; 7.3 `adopt` and its guards are Task 6; 7.4 stagger is Task 7 and the autostart layer is deferred to M6 as the spec says; 7.5 vendoring is Tasks 1 and 4. Section 6's report CLI is Task 3, with rollups, seen and unseen, and the remaining adapters deliberately left to M3.

**Deliberately out of scope for M2:** status line rendering of agent state, rollups up the tree, `agent next`, the opencode, pi and codex adapters. M2 needs session identity, not a display.

**Ordering for execution:** Task 1 and Task 2 are independent. Task 3 depends on 2. Task 4 depends on 1, 2 and 3. Tasks 5, 6 and 7 depend on 3 and 4. Task 8 depends on everything. Task 9 last.

# Remote awareness: plan

**Spec:** `docs/superpowers/specs/2026-11-16-remote-awareness-design.md`, its "Build" section.
**Issue:** #10. **Branch:** `feat/remote-awareness`.

Small enough for one implementer working in order; each step is test first.

1. **Spec and plan.** The Build section, with the owner ruling of 2026-11-18 on section 2
   (athome's `theme`, not canopy's M5 themes). Done when the spec names every criterion and
   test below.
2. **Tests.** `test/remote.bats`, the spec's test list 1 to 22, written before any code and
   seen failing: `canopy-remote` does not exist, the status layers have no segment, and
   `tmux.conf` sources no `25-remote.conf`.
3. **`bin/canopy-remote`.** `set`, `clear`, `follow-theme`; POSIX sh, the header metadata
   every command carries. Tests 1 to 8 and 16 to 19 pass.
4. **Layers.** The segment in `tmux/conf.d/20-status.conf` and
   `grofe/templates/20-canopy-status.toml`; `tmux/tmux.conf` sources
   `$CANOPY_STATE/25-remote.conf`; regenerate `grofe/conf.d`; three `generated` rows in
   `tmux/options.tsv`. Tests 9 to 15 and 20 to 22 pass, and the existing suite stays green.
5. **Docs.** `docs/02-commands.md` (a `canopy remote` section, the command count),
   `docs/04-configuration.md` (the indicator, its options, the title, theme following, the
   load order), `docs/01-installation-and-removal.md` (the two files), `README.md` (one line).
6. **Checks.** `mise run lint` and `mise run test`, with a grofe binary in `CANOPY_GROFE` so the
   grofe legs run, and the restore proof. Then the PR, review rounds and CI.

Not in this plan: athome follow-ups A to D in the spec. They are listed in the PR body for
athome to pick up.

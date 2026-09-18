# canopy

An opinionated, agent-aware tmux experience.

**Status: design.** No implementation yet. See
[`docs/superpowers/specs/2026-09-17-canopy-design.md`](docs/superpowers/specs/2026-09-17-canopy-design.md).

## Why

- **Sessions survive reboot with agent conversations intact.** Not "your panes come
  back": the same conversations, in the same panes. No other tmux setup or
  multiplexer does this today.
- **Agent state is tmux state.** Five normalized states (`idle · working · blocked ·
  completed · exited`) pushed from Claude Code, opencode, pi and codex into tmux
  options, rendered with zero subprocesses per redraw.
- **Preconfigured, not prescriptive.** Sensible defaults, one command namespace, a
  generated palette and cheatsheet, themes as data. Everything you don't have
  simply degrades instead of failing.

## The promise that makes it safe to install

> The pre-install restore point is complete and reachable forever, no matter how many
> updates and migrations have run since. `canopy restore --all` returns every file
> that existed before canopy to its exact original bytes.

Enforced in CI: install over pre-existing tmux, ghostty and starship configs → update
→ migrate → `restore --all` → byte-compare.

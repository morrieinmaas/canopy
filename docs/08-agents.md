# 08. Agents

Back to the [README](../README.md). Previous:
[07 Persistence](07-persistence.md).

canopy learns about a coding agent through an **adapter**: a small directory
that says how to recognise the agent in a pane and how to put it back into
that pane with its conversation intact.

One adapter ships today, for Claude Code. Three more (opencode, pi, codex) are
M3.

For writing an adapter, the authority is
[adapters/contract.md](adapters/contract.md). This page is about using one.

## Installing the Claude Code adapter

```
canopy agent install claude-code
```

This writes canopy's hooks into Claude Code's own `settings.json`, under
`$CLAUDE_CONFIG_DIR` or `~/.claude`. It:

- **requires that directory to already exist.** If Claude Code has never run
  for this user, canopy refuses rather than inventing a config directory for
  an agent that is not installed.
- **merges into an existing settings file, never replaces it.** Your model,
  theme, permissions and your own hooks survive. `jq` is required for the
  merge, and only for it; editing arbitrary JSON with `sed` is how a config
  file gets corrupted.
- **runs inside a transaction.** The prior bytes of every file it touches are
  recorded first, so `canopy restore` puts your settings back exactly as they
  were. Installing an adapter is as reversible as installing canopy.

The hooks it adds map Claude Code's events onto canopy's five states:

| Claude Code event | State |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | `working` |
| `Notification` (permission prompt) | `blocked` |
| `Notification` (idle prompt), `Stop` | `completed` |
| `SessionEnd` | `exited` |

Each hook runs `report.sh`, which is one call to `canopy agent report`.

## What a report does

```
canopy agent report <state> [--source <id>] [--session-id <id>]
```

It writes four tmux pane options: `@canopy_agent_state`,
`@canopy_agent_source`, `@canopy_agent_session` and `@canopy_agent_ts`.

Properties that matter, because hooks fire constantly:

- **It is cheap.** One `tmux display-message` reads all three carried values
  at once, and nothing is written when none of them moved. Only a real
  transition costs a write.
- **It is silent.** An agent running outside tmux has no `$TMUX_PANE`, and an
  agent whose pane has gone away gets no answer from tmux. Neither is the
  agent's problem, and a hook that fails is a hook that interrupts your work
  to report something you cannot act on. A state that is not one of the five
  is different: that is a bug in the adapter, and it is reported.
- **An option you do not name keeps its current value**, so a hook that knows
  only the state cannot blank out the session id the launch hook recorded.
- **The session id is compared, not just the state.** `/clear` starts a fresh
  conversation in the same pane, arriving as a new id whose state is `idle`
  when the pane is very often already `idle`. Debouncing on state alone would
  keep the old id, and the pane would come back from a reboot resumed into the
  wrong conversation.

## Capability tiers

Printed when you install an adapter, and read off the manifest rather than
stated separately, so it cannot drift:

| Tier | Means | Consequence |
|---|---|---|
| **1** | the agent takes a caller-chosen session id at launch (`can_pin_at_launch=yes`) | its panes are resumable from the moment they start |
| **2** | the agent invents its own id and can only resume by it | canopy has to learn the id afterwards, so there is a window where the pane holds a conversation that cannot yet be named |

Claude Code is tier 1.

## Which agent is in which pane

canopy identifies an agent pane by asking `ps` what the pane's process is
running and matching the command name against each installed adapter's
`command` key. This is why a `ps` that cannot report a process's parent
disables the entire feature set silently, and why `canopy doctor` checks for
one. See [07-persistence.md](07-persistence.md).

## Where adapters live

`$CANOPY_CONFIG/adapters/` is searched before `$CANOPY_STORE/adapters/`, so
your own adapter of a given id overrides the one canopy ships. The directory
name **is** the id, and a manifest whose `id` key disagrees with its directory
fails loudly the first time anything reads it.

An adapter with a manifest and no hooks is still a valid adapter. It just has
less to say about what its panes are doing.

## Limits worth knowing

- **`canopy adopt` cannot adopt a Claude Code pane.** Claude Code exposes no
  way to ask whether a pane holds unsent input, so its `detect_draft` is empty,
  which means "undetermined", which `adopt` is required to treat as "do not
  touch". See [07-persistence.md](07-persistence.md#canopy-adopt).
- **State is reported, never polled.** If an agent's hooks are not installed,
  or the agent is one canopy has no adapter for, its panes carry no state and
  no session id, and a reboot will restart them without their conversations.
  `canopy reboot-check` says so per pane, by name.

---

Back to the [README](../README.md) ·
[02 Commands](02-commands.md) ·
[07 Persistence](07-persistence.md) ·
[adapters/contract.md](adapters/contract.md)

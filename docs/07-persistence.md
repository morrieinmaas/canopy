# 07. Persistence: what survives a reboot

Back to the [README](../README.md). Previous:
[06 Contributing and testing](06-contributing-and-testing.md).

The promise is narrow and worth stating exactly:

> A pane running an agent comes back after a reboot **running that same
> conversation**, not a fresh one.

Not "your layout comes back". Layout restoration is what tmux-resurrect has
always done. What canopy adds is that the pane's command is rewritten, at save
time, into the command that resumes *that pane's* conversation by its own
session id.

This page describes what is built. Where something does not work, it says so
rather than describing the intention.

## Requirements, and what happens without them

| Needs | Why | Without it |
|---|---|---|
| tmux 3.4 or newer | the config loader | `canopy doctor` fails, exit 2 |
| `bash` | the vendored resurrect and continuum are `#!/usr/bin/env bash` scripts | the plugin layer loads nothing: no autosave, no restore |
| a `ps` that reports a process's parent | canopy recognises an agent pane by asking `ps` what the pane is running | **no pane is recognised as an agent**: saves record shells, and `reboot-check` reports no agent panes on a machine full of them |

Neither `bash` nor a capable `ps` ships in a BusyBox userland, and `ps` is
absent from many slim container images. Both are reported by `canopy doctor`
under **Plugins**, and `ps` is probed by running it rather than by looking for
the binary, because BusyBox ships a `ps` that exists and cannot answer.

canopy never installs either. It says what is missing and stops there.

## The chain

Five things have to line up. Each is independently observable, which is how a
break gets located rather than guessed at.

1. **An adapter** names the command that resumes a conversation, as a template
   with `{id}` in it. See [08-agents.md](08-agents.md).
2. **The agent reports its session id** into its own pane, through
   `canopy agent report`, called from the agent's own hooks. This sets the
   pane options `@canopy_agent_session`, `@canopy_agent_source`,
   `@canopy_agent_state` and `@canopy_agent_ts`.
3. **The save-command strategy** (`plugins/strategies/canopy_save_command.sh`)
   runs when resurrect saves. For a pane carrying a session id it writes the
   adapter's resume command instead of what the pane is running. For every
   other pane it defers to resurrect's own strategy, so a non-agent pane is
   saved exactly as it always was.
4. **continuum replays the save file** when a tmux server starts.
   `@continuum-restore` is set to `on` by canopy's plugin layer; upstream's
   default is off, which would make every step above write a file nothing ever
   reads back.
5. **The stagger wrapper** prefixes each resumed command with a short,
   bounded `sleep`, so ten agents do not all start in the same second.

A saved line ends up looking like this:

```
sleep 0.514 && claude --resume 3f2a…
```

## Settings canopy sets, and why

| Option | Value | Set by |
|---|---|---|
| `@continuum-restore` | `on` | canopy. Load-bearing: `canopy doctor` exits 2 if the config your machine loads leaves it off, and `canopy reboot-check` refuses to judge panes while it is off. |
| `@resurrect-dir` | `$CANOPY_STATE/resurrect` | canopy, so saves live under canopy's own state rather than in your home |
| `@resurrect-save-command-strategy` | canopy's strategy | canopy |
| `@continuum-save-interval` | not set, so continuum's own default of 15 minutes applies | upstream |
| `@canopy_resume_stagger_ms` | not set, so the default bound of 1000ms applies. `0` disables the wrapper exactly. | you, if you want |

Anything you set in `$CANOPY_CONFIG/user.conf` wins, because the entry point
sources it last. That is also why `doctor` reads `@continuum-restore` off the
config your machine actually loads rather than off canopy's own layer files: a
`user.conf` that turns it back off is caught here, rather than after a reboot.

## `canopy reboot-check`

Answers "is it safe to reboot?" **before** the reboot, by reading what
resurrect actually saved rather than what canopy intended to save.

```
canopy reboot-check
```

| Exit | Means |
|---|---|
| 0 | every agent pane will resume |
| 1 | at least one pane will not come back with its conversation |
| 2 | persistence is misconfigured, and no per-pane verdict is worth giving |

Per-pane verdicts:

| Verdict | Means |
|---|---|
| `will resume` | the last save records this pane's line as its adapter's resume command for the id it is carrying now |
| `will restart without its conversation` | no session id reported, no usable resume command, or the save records something else |
| `not saved yet` | the save exists but does not have this pane. Wait for the next autosave. |
| `will not be restored` | the restore path itself is off, so no pane comes back however well it was saved |

It also reports whether another tmux server is running, because continuum
refuses to auto-restore while one is, and that is exactly where a developer's
machine stops behaving like CI.

## `canopy adopt`

A pane where somebody started an agent by hand carries its conversation
nowhere durable: the id lives in a tmux pane option, gone the moment the pane
is replaced. `adopt` restarts such a pane as its own resume command, so the id
sits in the pane's command.

```
canopy adopt            # dry run, the default
canopy adopt --yes      # act
```

It kills and restarts live processes, so every guard fails closed. A pane is
restarted **only** when all of these hold:

- the agent reported a session id
- the adapter has a usable resume command
- the reported state is `idle` or `completed`
- the adapter says the pane holds **no** unsent input

Anything else is skipped and named: mid-task, unsent input, a state nobody
reported, or a draft state the adapter cannot determine. Undetermined is
treated exactly like "yes, there is a draft". The cost of skipping a clean
pane is that you run the command again; the cost of the other mistake is
somebody's half-typed message and the images pasted into it.

**Today this means `adopt` skips every Claude Code pane.** Claude Code exposes
no way to ask whether a pane holds unsent input, so its adapter leaves
`detect_draft` empty, which is "undetermined", which fails closed. This is
deliberate, and it makes `adopt` useful only for agents that can answer the
question. M3 removes most of the need for it by supplying session ids at
launch.

A pane that never reported an id is never adopted. Nothing can name that
conversation, and minting a fresh id would pin the pane by throwing away what
it holds.

## Verifying with a real agent

The container scenarios drive a fake agent, because Claude Code needs
credentials and a network and a container has neither. What the containers
prove is that canopy saves, restores and resumes **the right session id per
pane**. What they cannot prove is that Claude Code's own `--resume` behaves.

To check the real path on your own machine:

1. `canopy agent install claude-code`, then start Claude Code in a pane and
   let it do something, so a hook fires.
2. `tmux display-message -p '#{@canopy_agent_session}'` in that pane. A uuid
   means the adapter is reporting. Empty means the hooks are not installed or
   not firing, and nothing below will work.
3. `canopy reboot-check`. It should say `will resume` and name that id. If it
   says `not saved yet`, wait for continuum's next autosave, or force one:
   `tmux run-shell ~/.local/share/canopy/plugins/tmux-resurrect/scripts/save.sh`
4. `tmux kill-server`, then start tmux again.
5. The pane should come back running `claude --resume <the same id>`, and
   Claude Code should open the same conversation rather than a new one.

Step 5 is the only step a test cannot do for you.

## What is not built

- **Autostart.** Nothing starts a tmux server at login, so a restore happens
  when you first start tmux, not at boot. That is M6.
- **Adapters beyond Claude Code.** opencode, pi and codex are M3.
- **Draft detection for Claude Code**, as above.

---

Next: [08 Agents](08-agents.md)

Back to the [README](../README.md) ·
[02 Commands](02-commands.md) ·
[04 Configuration](04-configuration.md) ·
[05 Troubleshooting](05-troubleshooting.md)

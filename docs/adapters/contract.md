# The agent adapter contract

An **adapter** teaches canopy about one coding agent: how to recognise it
in a pane, and how to put it back into that pane with its conversation
intact after a reboot.

An adapter is a directory containing exactly one required file:

```
adapters/<id>/manifest
```

`lib/adapter.sh` is the only thing that reads it. Two functions:

| Function | Does |
|---|---|
| `canopy_adapter_list` | Prints every installed adapter id, one per line, sorted |
| `canopy_adapter_get <id> <key>` | Prints one key's value. Returns 1 when no adapter has that id |

## Where adapters are found

`$CANOPY_CONFIG/adapters/` is searched before `$CANOPY_STORE/adapters/`,
so your own adapter of a given id overrides the one canopy ships under
that id. `canopy_adapter_list` reports a shadowed adapter once, because
there is one adapter by that id as far as every caller is concerned.

**The directory name is the id.** The manifest's own `id` key must agree
with the directory it sits in, and reading a manifest where they disagree
fails loudly. This is on purpose: an adapter copied into place under the
wrong name is then caught the first time anything reads it, rather than
the first time a pane fails to come back.

## Manifest format

`key=value`, one per line. No spaces around the `=`. Blank lines are
ignored, and a line whose first character is `#` is a comment.

**All six keys are required in every manifest.** A value may be empty; a
key may not be absent. Absent-means-default is how two readers of the same
file end up disagreeing about what the default was.

Everything else is rejected, loudly, at read time: an unknown key, a
duplicated key, a line that is not `key=value`, an `id` that disagrees
with the directory, a `can_pin_at_launch` that is neither `yes` nor `no`,
or a template with no `{id}` in it. The whole manifest is validated on
every read, not just the line asked for, so a manifest that is wrong three
lines below the key you wanted still fails where the mistake is rather
than where it eventually bites.

## The six keys

### `id`

The adapter's name, and the directory it must live in.

```
id=claude-code
```

### `command`

The process name canopy matches in a pane to decide that pane is running
this agent. Not the full command line, the command.

```
command=claude
```

### `resume_template`

The command that resumes an existing conversation, with `{id}` standing
for the session id. Required to contain `{id}`; a resume template with
nothing to substitute into cannot resume anything.

```
resume_template=claude --resume {id}
```

This is the value that ends up saved as a pane's command, so that
restoring the pane restores the conversation rather than starting a fresh
one. It is the whole point of the contract.

### `can_pin_at_launch`

`yes` or `no`. Whether the agent accepts a caller-chosen session id when
it starts.

```
can_pin_at_launch=yes
```

It matters because the two cases need different strategies. An agent that
can be pinned gets its id chosen by canopy up front, and is therefore
resumable from the moment it starts. An agent that cannot be pinned
invents its own id, so canopy has to learn that id afterwards, and there
is a window during which the pane is running an agent whose conversation
cannot yet be named.

### `launch_template`

The command that starts a fresh conversation at a caller-chosen id, with
`{id}` as the placeholder.

```
launch_template=claude --session-id {id}
```

Required to contain `{id}` when `can_pin_at_launch=yes`. When
`can_pin_at_launch=no` the key is still required but may be empty, because
there is no such command to name:

```
can_pin_at_launch=no
launch_template=
```

### `detect_draft`

A shell command that reports whether a pane is holding unsent input, with
`{pane}` standing for the tmux pane id.

```
detect_draft=my-agent --has-draft {pane}
```

This one exists for `canopy adopt`, which kills and restarts a live pane
in order to bring it under management. Restarting a pane where somebody
has half a message typed and not yet sent destroys work that was never
written down anywhere, and no amount of correctness elsewhere makes up for
that.

So the command reports **three** outcomes, not two:

| Exit status | Means |
|---|---|
| `0` | The pane is holding unsent input |
| `1` | The pane is holding no unsent input |
| anything else | Undetermined |

An empty `detect_draft` means the adapter cannot answer the question at
all, and is equivalent to "undetermined" for every pane.

**Callers must fail closed.** Undetermined is not permission to proceed.
A pane whose draft state cannot be established is skipped and named, the
same as a pane that definitely has a draft. The cost of skipping a clean
pane is that somebody runs the command again; the cost of the other
mistake is somebody's unsent message.

## Placeholders

| Placeholder | Substituted with | Used in |
|---|---|---|
| `{id}` | the agent's session id | `resume_template`, `launch_template` |
| `{pane}` | the tmux pane id | `detect_draft` |

Substitution is literal text replacement. Values are never passed through
a shell for expansion by `lib/adapter.sh` itself, so a manifest cannot run
anything merely by being read.

## A complete example

`test/fixtures/fake-agent-adapter/manifest`, which is the adapter the test
suite uses, and the smallest thing that satisfies every rule above:

```
id=fake-agent
command=fake-agent
resume_template=fake-agent --resume {id}
can_pin_at_launch=yes
launch_template=fake-agent --session-id {id}
detect_draft=test -s ${FAKE_AGENT_HOME}/{pane}.draft
```

Its agent is `test/fixtures/fake-agent`, which accepts `--session-id <id>`
or `--resume <id>`, appends a line to `$FAKE_AGENT_HOME/<id>.transcript`,
and stays alive until it is killed. That transcript is how a test proves a
restored pane continued the same conversation instead of starting a new
one.

## Reporting state: the files beside the manifest

If the agent reports its own state, it also needs the hooks that call
`canopy agent report`, which live alongside the manifest in the same
directory. That is a separate concern from this contract: an adapter with
a manifest and no hooks is still a valid adapter, it just has less to say
about what its panes are doing. Nothing below adds a manifest key; the
contract is six keys and stays six keys.

The convention `canopy agent install <id>` follows, as the shipped
`adapters/claude-code/` demonstrates:

| File | Is |
|---|---|
| `hooks.json` | the agent's own hook configuration, with `{report}` standing for the absolute path of `report.sh` |
| `report.sh` | the reporter the hooks call, which turns one of the agent's events into one `canopy agent report` |
| `install.sh` | how the two above get into the agent's own configuration |

`install.sh` is **sourced** by `canopy agent install`, inside a transaction
it has already opened. It gets `$CANOPY_ADAPTER_DIR`, `$CANOPY_ADAPTER_ID`,
`$CANOPY_TX`, and two functions: `canopy_die`, and `canopy_agent_own <path>`.

**Call `canopy_agent_own` on every path before touching it.** That is what
records the file's prior bytes, and it is the whole reason `canopy restore`
can put the agent's configuration back exactly as it was. An installer that
writes to a path it did not own first has quietly broken canopy's one
promise. If the installer fails at any point, the transaction is rolled back
and marked failed.

An adapter with no `install.sh` is still a valid adapter. `canopy agent
install` refuses it by name, because canopy has no idea where that agent
keeps its configuration, and guessing is not a thing it is willing to do
with somebody else's config file.

## Adding an adapter

1. Create `adapters/<id>/manifest` with all six keys.
2. Read one key back with `canopy_adapter_get <id> id`. Validation runs on
   every read, so this is a full check of the file.
3. Confirm `canopy_adapter_list` names it.
4. If the agent can report its own state, add `hooks.json`, `report.sh` and
   `install.sh` next to the manifest, per the section above.

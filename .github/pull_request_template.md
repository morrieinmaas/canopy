<!--
The one rule this project has: a claim about behaviour is verified before it is
made. Not "this should work". Run it, and say what happened.
-->

## What this changes, and why

<!-- The why, not the what. The diff already says what. -->

## How it was verified

<!--
Paste what you ran and what came back. `mise run check` is the floor; a change
to the install, restore or persistence path wants `mise run smoke` too, and a
change that only shows up on one OS wants that OS named.
-->

```
$ mise run check
```

## Checklist

- [ ] `mise run check` passes (lint, unit suite, restore proof)
- [ ] New behaviour has a test, and that test fails without the change
- [ ] A new command has a section in `docs/02-commands.md`
- [ ] A new tmux option canopy sets is a row in `tmux/options.tsv`
- [ ] A new key binding is a row in `tmux/keys.tsv`, not a `bind` line
- [ ] Nothing in `bin/` or `lib/` needs bash

<!--
The last four are enforced by tests, so an unticked box is usually a red check
rather than a matter of taste.
-->

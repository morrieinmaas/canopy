# opensessions: incremental Claude Code transcript watching

## Problem

`opensessions-server`'s agent watcher (`apps/server-rs/src/lib.rs`,
`scan_claude_code_projects`) runs every 2 s (`AGENT_WATCHER_POLL_MS`). For each
`~/.claude/projects/**/*.jsonl` modified in the last 5 minutes it reads the
whole file and `claude_code_snapshot_from_jsonl`
(`packages/runtime-rs/src/agent_watchers.rs`) JSON-parses every line. With
many agents that is hundreds of MB parsed every 2 s (measured: 25 files,
524 MB), keeping the server at 40-150% CPU.

## Change

- Split the parser into plain data plus functions (no new trait or object):
  a `ClaudeCodeParseState` value (status, thread name, last user prompt,
  last entry is tool use, saw entry), a function that folds complete lines of
  a chunk into a state and returns the new state, and a function that turns a
  state plus `mtime_ms`/`now_ms` into the snapshot (the existing ageing
  rules: tool-use wait, stale). `claude_code_snapshot_from_jsonl` keeps its
  signature and becomes the composition of the two, so existing callers and
  tests are unchanged.
- The server's Claude scan keeps a per-file cache across ticks (owned by the
  watcher loop): file identity (device + inode), byte offset consumed, and
  the parse state. Per tick and file:
  - size and identity unchanged: no read; snapshot from the cached state
    (ageing still uses the current `now_ms`).
  - grew: read only from the offset, parse only complete lines (a trailing
    line without `\n` is left for the next tick), advance the offset.
  - shrank or identity changed: drop the entry and read from the start.
  - entries for files no longer in the recent window are dropped.

## Acceptance criteria

1. For any split of a transcript into chunks at any byte position, folding
   the chunks gives the same snapshot as parsing the whole file.
2. A partial last line is not parsed until its `\n` arrives.
3. A custom title or first prompt seen in an early chunk survives later
   chunks.
4. An unchanged file is not read again on the next tick.
5. Appending lines updates the status without re-reading earlier bytes.
6. A truncated or replaced file is re-read from the start.
7. The cache does not grow without bound: entries for files outside the
   recent window are removed.
8. Existing `cargo test --workspace` stays green.

## Delivery

canopy installs opensessions from release binaries pinned in
`plugins/ARTIFACTS`, so the fix ships as canopy's own release:
`.github/workflows/opensessions-release.yml` builds the four platform tarballs
from the vendored source on an `opensessions-v*` tag (same file names and
layout as upstream), and a follow-up change points the opensessions lines in
`plugins/ARTIFACTS` at that release. `bin/.opensessions-version` and
package.json stay `0.2.0-alpha.12`, so the plugin's own downloader does not
run. The fix is also offered upstream to Ataraxy-Labs/opensessions.

## Out of scope

The Codex, pi, amp, opencode and droid scanners (same pattern, not running on
this machine); the tmux state poll.

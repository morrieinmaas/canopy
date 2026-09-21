#!/bin/sh
# canopy's Claude Code reporter: one hook event in, one pane report out.
#
# Claude Code delivers a hook event as JSON on stdin and identifies it in a
# `hook_event_name` field. Which of canopy's five states an event means is
# decided in hooks.json, next to the matcher that selects the event, and
# arrives here as the single argument, so the mapping is one declarative
# table rather than a second `case` that can drift from it:
#
#   SessionStart                      -> idle
#   UserPromptSubmit                  -> working
#   PreToolUse, PostToolUse           -> working
#   Notification/permission_prompt    -> blocked
#   Notification/idle_prompt          -> completed
#   Stop                              -> completed
#   SessionEnd                        -> exited
#
# What this script adds is the session id, which is in the payload and
# nowhere else, and which is the whole reason the milestone exists: it is
# what lets a restored pane resume the same conversation.
#
# **This script exits 0 whatever happens after argument checking.** A
# PreToolUse hook that exits 2 BLOCKS the tool call, and every other
# non-zero exit is surfaced to the user as an error. A reporter that
# interrupts somebody's work because tmux was busy is worse than a reporter
# that misses a transition, and the next tool use reports again anyway.
set -eu

if [ "$#" -ne 1 ]; then
  printf 'report.sh: usage: report.sh <state>\n' >&2
  exit 1
fi
state="$1"

# The store is derived from this file's own location, which is where
# `canopy agent install` pointed the hook: adapters/<id>/report.sh, two
# levels under the store. $CANOPY_STORE wins when it is already set, which
# is the case for the test suite and for anyone running from a checkout.
: "${CANOPY_STORE:=$(cd "$(dirname "$0")/../.." && pwd)}"
agent="$CANOPY_STORE/bin/canopy-agent"

payload="$(cat)"
# A flat string field, read without a JSON parser: a hook on every tool use
# is not the place to require jq, and this script is on that path.
session="$(
  printf '%s' "$payload" |
    sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -1
)"

if [ -x "$agent" ]; then
  if [ -n "$session" ]; then
    "$agent" report "$state" --source claude-code --session-id "$session" || :
  else
    "$agent" report "$state" --source claude-code || :
  fi
fi
exit 0

#!/usr/bin/env bash
# Refresh the picker's agent cache whenever this agent changes state.
#
#   refresh-cache.sh [delay]   optional seconds to wait first, e.g. for the
#                              process to exit on SessionEnd.
#
# picker.sh paints its first frame from the cache (unless @claude_picker_cache is off).
# Claude's hooks fire at exactly the moments that status changes, so refreshing
# here keeps that first paint honest.
#
# Never fails and never prints: hook output lands in the transcript, and a failed
# refresh must not fail the turn.

# Only when this agent is itself inside tmux. agents.sh pairs each Claude with a
# tmux pane and emits nothing when it cannot reach a server — refreshing from a
# Claude running outside tmux would overwrite a good cache with an empty one.
[ -n "${TMUX:-}" ] || exit 0

# The Claude plugin ships inside the tmux-claude-hatch repo, so a
# marketplace checkout has scripts/ two levels up. The tpm paths cover a plugin
# dir installed on its own, alongside a normal tpm install of the tmux side.
for candidate in \
  "${CLAUDE_PLUGIN_ROOT:-}/../../scripts/picker.sh" \
  "$HOME/.tmux/plugins/tmux-claude-hatch/scripts/picker.sh" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-claude-hatch/scripts/picker.sh"; do
  if [ -x "$candidate" ]; then
    picker="$candidate"
    break
  fi
done
[ -n "${picker:-}" ] || exit 0

# Detached, so the turn never waits on agents.sh (nor on the delay).
# Concurrent refreshes from several agents are safe: --list writes a temp file
# and renames it over the cache, which is atomic.
delay="${1:-0}"
( { [ "$delay" != 0 ] && sleep "$delay"; "$picker" --list; } >/dev/null 2>&1 & )

exit 0

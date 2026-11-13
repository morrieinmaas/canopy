#!/usr/bin/env bash
# Ring the terminal bell so tmux counts it as one.
#
# tmux only raises an alert for a real BEL (\a) written to a pane's pty — the
# escape sequences the `iterm2`, `kitty` and `ghostty` notification channels
# send do not qualify. Writing \a here is what makes the window-status alert,
# and this plugin's bell forwarding, fire at all.
#
# Never fails and never prints: a bell that cannot be delivered must not fail
# the hook, or Claude reports a hook error on every turn. Note that `2>/dev/null`
# comes *before* the `/dev/tty` redirection — a failed redirection is reported by
# the shell itself, so a trailing `2>/dev/null` would be applied too late to
# suppress it.

# The hook's controlling terminal. Inside tmux that is the pane's own pty —
# exactly where Claude's built-in bell would land.
printf '\a' 2>/dev/null >/dev/tty && exit 0

# No controlling terminal (a hook is not guaranteed one). Resolve the pane's tty
# through tmux instead.
if [ -n "${TMUX_PANE:-}" ]; then
  tty="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null)"
  [ -n "$tty" ] && printf '\a' 2>/dev/null >"$tty"
fi

exit 0

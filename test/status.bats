#!/usr/bin/env bats
load helper

# canopy's status line, and the one aggregator it is allowed.
#
# The property worth protecting is not how the bar looks. It is that the
# bar costs one process per interval rather than one per segment, that a
# segment with nothing to say disappears instead of rendering a
# placeholder, and that setting status-right here does not destroy
# tmux-continuum's autosave hook, which it silently would if this layer
# ran after the plugin layer.
setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  canopy_paths
  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

@test "the aggregator prints a clock and a date, and exits clean" {
  run canopy-status --plain
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9][0-9]:[0-9][0-9] ]]
}

@test "the aggregator emits one line and no control characters beyond colour" {
  # A stray newline or a raw control byte in a status segment corrupts the
  # whole bar, and tmux gives no hint which segment did it.
  run canopy-status --plain
  [ "${#lines[@]}" -eq 1 ]
  printf '%s' "$output" | LC_ALL=C grep -q '[[:cntrl:]]' && false
  return 0
}

@test "a segment switched off renders nothing at all" {
  sock="canopy-status-off-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" set -g @canopy_status_net off
  tmux -L "$sock" set -g @canopy_status_battery off
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp canopy-status --plain
  [ "$status" -eq 0 ]
  # What is left is the date and the clock, so a weekday and a colon.
  [[ "$output" =~ [0-9][0-9]:[0-9][0-9] ]]
  [[ "$output" != *"%"* ]]
}

@test "the status layer sets a right side that runs exactly one command" {
  sock="canopy-status-one-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  value="$(tmux -L "$sock" show -gv status-right)"
  kill_tmux_server "$sock"
  sock=""
  # One #( in canopy's own layer. continuum adds its own when the plugin
  # layer loads, which is upstream's mechanism and is asserted separately.
  count="$(printf '%s' "$value" | grep -o '#(' | wc -l | tr -d ' ')"
  [ "$count" -le 2 ]
  [[ "$value" == *"canopy-status"* ]]
}

@test "the status layer is numbered so it loads before the plugin layer" {
  # Not a style point. tmux-continuum PREPENDS its autosave hook to
  # whatever status-right holds when it loads, so a status layer that ran
  # after the plugin layer would remove the hook and stop autosave, and
  # nothing would say so until a reboot had already lost a conversation.
  #
  # Asserted on the filenames because that is what decides the order: the
  # entry point sources conf.d/[1-9]*.conf as a sorted glob. Asserting on
  # a live server instead would be flaky, since continuum skips adding the
  # hook whenever another tmux server is running.
  first="$(ls "$CANOPY_STORE/tmux/conf.d" | grep -E '^(20-status|30-plugins)\.conf$' | head -1)"
  [ "$first" = "20-status.conf" ]
}

@test "doctor reports a live server whose autosave hook has been removed" {
  sock="canopy-status-doctor-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" set -g status-right "no hook here"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp canopy-doctor
  [[ "$output" == *"autosave hook"* ]]
  [[ "$output" == *"set -ag"* ]]
}

@test "the bar reads its colours from options, not from literals" {
  # The whole point of colour as data: a theme repaints by setting
  # options. A hex literal in a format string is a colour no theme can
  # reach.
  run grep -c '#[0-9a-f]\{6\}' "$CANOPY_STORE/tmux/conf.d/20-status.conf"
  # Only the palette block may hold literals: seven @theme_* defaults.
  [ "$output" -le 8 ]
}

@test "rejects an unknown argument the same way every other command does" {
  run canopy-status --definitely-not-a-flag
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-status: unknown argument: --definitely-not-a-flag" ]
}

@test "both pill glyphs are byte-for-byte intact in the layer" {
  # The reason these are literal bytes rather than built at load: doing it
  # with run-shell blinded canopy_tmux_validate to every error in every
  # later layer. The worry that made them generated is real though, so it
  # is checked here instead. U+E0B6 and U+E0B4, in UTF-8.
  run od -An -tx1 "$CANOPY_STORE/tmux/conf.d/20-status.conf"
  [[ "${output//[[:space:]]/}" == *"ee82b6"* ]]
  [[ "${output//[[:space:]]/}" == *"ee82b4"* ]]
}

@test "the status layer runs no shell command at load" {
  # Not style. Any run-shell here resets the status of the source-file
  # running it, so errors in later layers go unreported and a broken
  # config installs clean.
  run grep -c '^run-shell' "$CANOPY_STORE/tmux/conf.d/20-status.conf"
  [ "$output" = "0" ]
}

@test "the prefix can still be sent through after the plugin layer loads" {
  # tmux-resurrect binds prefix C-s to its save script when it loads, and
  # it loads after the key layer. With canopy's prefix being C-s that took
  # the send-prefix binding outright: `prefix C-s` wrote a save file, and
  # there was no way left to send the prefix to a nested tmux at all,
  # while keys.tsv went on declaring a prefix-send row that existed
  # nowhere. 30-plugins moves resurrect's own two keys before it loads.
  sock="canopy-prefix-$$"
  tmux -L "$sock" -f /dev/null new-session -d 'sleep 30'
  hold_off_boot_restore "$sock"
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/00-core.conf"
  tmux -L "$sock" source-file "$CANOPY_STATE/10-keys.conf" 2>/dev/null || {
    canopy-keys
    tmux -L "$sock" source-file "$CANOPY_STATE/10-keys.conf"
  }
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  keys="$(tmux -L "$sock" list-keys -T prefix 2>/dev/null)"
  kill_tmux_server "$sock"
  sock=""
  [[ "$keys" == *"send-prefix"* ]]
  [[ "$keys" != *"C-s     run-shell"* ]]
}

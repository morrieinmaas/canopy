#!/usr/bin/env bats
load helper

# `canopy reboot-check`: the pre-flight that answers "is it safe to reboot?"
# before the reboot rather than after it.
#
# What makes the answer worth anything is that it is read off what was
# actually saved, not off what canopy hopes it saved. A pane counts as
# resuming when resurrect's own save file records that pane's line as the
# adapter's resume command for the session id the pane is carrying right
# now. Anything less would be a command that says "yes" while the save file
# holds a shell prompt.
#
# Every test here starts tmux on its own named socket with a scratch $HOME.
# Nothing may reach the default socket: on a developer's machine that is
# their real session, holding real work.
setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/adapter.sh"
  . "$CANOPY_STORE/lib/pane.sh"
  canopy_paths

  fixtures="$BATS_TEST_DIRNAME/fixtures"

  FAKE_AGENT_HOME="$BATS_TEST_TMPDIR/agent-home"
  export FAKE_AGENT_HOME
  mkdir -p "$FAKE_AGENT_HOME"

  agent_bin="$BATS_TEST_TMPDIR/agentbin"
  mkdir -p "$agent_bin"
  ln -sf "$fixtures/fake-agent" "$agent_bin/fake-agent"
  PATH="$agent_bin:$PATH"
  export PATH

  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"

  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

# A scratch server carrying canopy's plugin layer, with $TMUX exported.
# reboot-check talks to the server the same way every other canopy command
# does, through a bare `tmux`, so the environment is what points it at this
# server rather than at the developer's own.
rc_start() {
  sock="cnp-reboot-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" -f /dev/null new-session -d -s main
  hold_off_boot_restore "$sock"
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  export TMUX
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

rc_wait_for_command() {
  local i=0
  while [ "$i" -lt 50 ]; do
    case "$(canopy_pane_command "$1")" in
      *"$2"*) return 0 ;;
      *) ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

rc_wait_for_file() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# rc_run_agent <pane> <launch-id>
# Puts a real running agent in the pane, which is what makes the pane an
# agent pane: reboot-check finds panes by the command they are running.
rc_run_agent() {
  tmux -L "$sock" send-keys -t "$1" "fake-agent --session-id $2" Enter
  rc_wait_for_command "$1" fake-agent
}

# rc_report <pane> <session-id>
# What `canopy agent report` leaves on a pane once the agent has said which
# conversation it is in.
rc_report() {
  tmux -L "$sock" set -p -t "$1" @canopy_agent_session "$2"
  tmux -L "$sock" set -p -t "$1" @canopy_agent_source fake-agent
}

rc_save() {
  tmux -L "$sock" run-shell "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh quiet"
  rc_wait_for_file "$CANOPY_STATE/resurrect/last"
}

# --- the verdicts ----------------------------------------------------------

@test "a pane whose resume command is in the last save will resume" {
  rc_start
  rc_run_agent "$pane" 11111111-2222-3333-4444-555555555555
  rc_report "$pane" 11111111-2222-3333-4444-555555555555
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"main:0.0"* ]]
  [[ "$output" == *"fake-agent"* ]]
  [[ "$output" == *"will resume"* ]]
  [[ "$output" == *"11111111-2222-3333-4444-555555555555"* ]]
}

@test "a pane launched with its own id is resumable even though nothing reported it" {
  # This test used to assert the opposite, and the opposite was wrong. An
  # agent that takes a caller chosen id carries that id in the command it
  # is running, whether or not a hook ever reported it, so there is no
  # honest way to call the pane idless. Reading only the resume form is how
  # canopy came to look at sixteen live panes, every one with its uuid in
  # plain sight, and report that not one of them had a session id.
  #
  # And it resumes, because the id being readable is what lets the save
  # strategy write a resume command for a pane that was never reported:
  # the pane runs the launch form, the save holds the resume form. That is
  # the whole path a machine full of hand-started agents needs, and it is
  # the difference between sixteen conversations surviving a reboot and
  # none of them.
  rc_start
  rc_run_agent "$pane" 66666666-7777-8888-9999-000000000000
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"will resume"* ]]
  [[ "$output" == *"66666666-7777-8888-9999-000000000000"* ]]
  [[ "$output" != *"no session id"* ]]
}

@test "a pane whose agent cannot be handed an id has no session id anywhere" {
  # The genuine idless case, and the only one left: an adapter that cannot
  # pin an id at launch has an empty launch_template, so there is nothing
  # in the pane's command to read back and nothing reported either.
  rc_start
  awk -F'\t' '{ print }' /dev/null || true
  manifest="$CANOPY_CONFIG/adapters/fake-agent/manifest"
  tmp="$BATS_TEST_TMPDIR/m"
  awk '
    /^can_pin_at_launch=/ { print "can_pin_at_launch=no"; next }
    /^launch_template=/   { print "launch_template="; next }
    { print }
  ' "$manifest" >"$tmp"
  mv "$tmp" "$manifest"

  rc_run_agent "$pane" 77777777-8888-9999-aaaa-bbbbbbbbbbbb
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session id has been reported"* ]]
}

@test "a pane that appeared after the last save is not saved yet" {
  rc_start
  rc_save
  tmux -L "$sock" new-window -d
  other="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | tail -1)"
  [ "$other" != "$pane" ]
  rc_run_agent "$other" aaaa-bbbb
  rc_report "$other" aaaa-bbbb
  run canopy-reboot-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not saved yet"* ]]
}

@test "a pane saved under a different conversation will restart without this one" {
  # The pane was saved carrying one session id and has since started
  # another, which is what /clear does. The save on disk resumes the old
  # conversation, so the honest verdict is that this one does not survive.
  rc_start
  rc_run_agent "$pane" cccc-dddd
  rc_report "$pane" cccc-dddd
  rc_save
  rc_report "$pane" eeee-ffff
  run canopy-reboot-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"will restart without its conversation"* ]]
  [[ "$output" == *"cccc-dddd"* ]]
}

@test "a pane that is not running an agent is not listed at all" {
  rc_start
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no agent panes"* ]]
}

# --- persistence itself ----------------------------------------------------

@test "continuum autosave turned off is exit 2, naming the setting" {
  rc_start
  rc_run_agent "$pane" 1111-2222
  rc_report "$pane" 1111-2222
  rc_save
  tmux -L "$sock" set -g @continuum-save-interval 0
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"@continuum-save-interval"* ]]
}

@test "status-interval at zero is exit 2, naming the setting" {
  # continuum's save rides on a status line interpolation, so a status line
  # that never redraws is a save that never runs.
  rc_start
  rc_run_agent "$pane" 1111-2222
  rc_report "$pane" 1111-2222
  rc_save
  tmux -L "$sock" set -g status-interval 0
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"status-interval"* ]]
}

@test "a save older than two autosave intervals is exit 2" {
  rc_start
  stale="$BATS_TEST_TMPDIR/stale-resurrect"
  mkdir -p "$stale"
  : >"$stale/last"
  touch -t 200001010000 "$stale/last"
  tmux -L "$sock" set -g @resurrect-dir "$stale"
  tmux -L "$sock" set -g @continuum-save-last-timestamp 1
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"autosave"* ]]
}

@test "the resurrect directory is read from the option, not assumed" {
  # The same stale directory proves the option is honoured: if reboot-check
  # looked in $CANOPY_STATE/resurrect it would find the fresh save this test
  # just wrote and report nothing wrong.
  rc_start
  rc_save
  [ -e "$CANOPY_STATE/resurrect/last" ]
  stale="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$stale"
  : >"$stale/last"
  touch -t 200001010000 "$stale/last"
  tmux -L "$sock" set -g @resurrect-dir "$stale"
  tmux -L "$sock" set -g @continuum-save-last-timestamp 1
  run canopy-reboot-check
  [ "$status" -eq 2 ]
}

@test "a healthy server with a fresh save reports the autosave interval" {
  # Five, which is canopy's layer talking, not continuum's default of
  # fifteen. The number is asserted rather than the label because the
  # interval is the window in which a reboot loses a conversation, so a
  # silent revert to upstream's default is a real regression in the
  # promise and not a cosmetic one.
  rc_start
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"every 5 minutes"* ]]
}

# --- the restore path ------------------------------------------------------
# Autosave is only half of persistence. The other half is whether anything
# reads the save file back when the machine comes up, and continuum
# defaults that to off. A pre-flight that answers "is it safe to reboot"
# per pane while the restore path is disabled is a confident yes about a
# machine that would restore nothing at all.

@test "the shipped plugin layer leaves continuum's restore on" {
  rc_start
  [ "$(tmux -L "$sock" show -gv @continuum-restore)" = "on" ]
}

@test "continuum's restore turned off is exit 2, naming the setting" {
  rc_start
  rc_run_agent "$pane" 1111-2222
  rc_report "$pane" 1111-2222
  rc_save
  tmux -L "$sock" set -g @continuum-restore off
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"@continuum-restore"* ]]
}

@test "a disabled restore path is never reported as a pane that will resume" {
  # The whole point of the exit 2 above. This pane's resume command is in
  # the last save, so every per-pane check passes and the old verdict was
  # "will resume" on a machine where nothing would be restored.
  rc_start
  rc_run_agent "$pane" 1111-2222
  rc_report "$pane" 1111-2222
  rc_save
  tmux -L "$sock" set -g @continuum-restore off
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" != *"will resume"* ]]
}

@test "continuum's halt file is exit 2, naming the file" {
  # continuum's own documented off switch, and it is off switch enough:
  # the restore script checks for this file before it does anything.
  rc_start
  rc_run_agent "$pane" 1111-2222
  rc_report "$pane" 1111-2222
  rc_save
  : >"$HOME/tmux_no_auto_restore"
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"tmux_no_auto_restore"* ]]
}

@test "a second tmux server is reported, because continuum will not restore past one" {
  # A developer desktop with a second server behaves differently from CI,
  # where the server under test is the only one. Silent divergence between
  # what CI proves and what a real machine does is what this line exists
  # to say out loud.
  rc_start
  rc_save
  other="cnp-reboot-other-$$-${BATS_TEST_NUMBER}"
  tmux -L "$other" -f /dev/null new-session -d
  run canopy-reboot-check
  kill_tmux_server "$other"
  [[ "$output" == *"another tmux server"* ]]
}

@test "a restored pane is recognised by the command it is running, not only by its option" {
  # The bug this pins. resurrect saves no user pane options, so a pane
  # brought back as `agent --resume <id>` has an empty
  # @canopy_agent_session, and reading only that option made this command
  # report "no session id has been reported" about a pane it had just
  # restored correctly. The id is still there, in the command.
  rc_start
  tmux -L "$sock" send-keys -t "$pane" \
    "fake-agent --resume dddddddd-1111-2222-3333-444444444444" Enter
  rc_wait_for_command "$pane" -- resume
  # Deliberately NOT reported: this is a pane as it comes back from a
  # restore, carrying its command and nothing else.
  [ -z "$(tmux -L "$sock" display-message -p -t "$pane" '#{@canopy_agent_session}')" ]
  rc_save

  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"will resume"* ]]
  [[ "$output" == *"dddddddd-1111-2222-3333-444444444444"* ]]
  [[ "$output" == *"read from the command the pane is running"* ]]
}

@test "the id is read from the launch form as well as the resume form" {
  # Both forms carry it, and a pane is running whichever one started it:
  # the resume command after a restore, the launch command before one.
  # Reading only the resume form left every freshly launched pane looking
  # idless, which on a real machine meant all of them.
  rc_start
  rc_run_agent "$pane" eeeeeeee-1111-2222-3333-444444444444
  rc_save
  run canopy-reboot-check
  [[ "$output" == *"eeeeeeee-1111-2222-3333-444444444444"* ]]
}

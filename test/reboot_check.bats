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

@test "a pane that has reported no session id will restart without its conversation" {
  rc_start
  rc_run_agent "$pane" 66666666-7777-8888-9999-000000000000
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"will restart without its conversation"* ]]
  [[ "$output" == *"no session id"* ]]
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
  rc_start
  rc_save
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"15 minutes"* ]]
}

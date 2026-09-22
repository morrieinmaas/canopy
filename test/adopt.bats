#!/usr/bin/env bats
load helper

# `canopy adopt`: brings an agent pane under management by restarting it in
# place as its own resume command.
#
# Every test here kills and restarts a live pane, which is the whole point
# and also the whole danger. The guards are not decoration: a pane holding
# a half-typed message holds the only copy of it, and the pasted images in
# that message exist nowhere but that process. So the tests that prove a
# pane is left alone matter more than the one that proves a pane is
# adopted, and there are more of them on purpose.
#
# Every test starts tmux on its own named socket with a scratch $HOME.
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

# A scratch server with $TMUX exported, so a bare `tmux` inside the command
# under test reaches this server and not the developer's own.
#
# The plugin layer is not sourced here. adopt talks to panes and adapters,
# not to resurrect, and a layer that arms a boot restore would fight the
# panes each test builds.
adopt_start() {
  sock="cnp-adopt-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" -f /dev/null new-session -d -s main
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  export TMUX
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

adopt_wait_for_command() {
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

# adopt_run_agent <pane> <launch-id>
# A real running agent in the pane, started the way a user starts one: by
# typing it at a shell, which is exactly the case adopt exists for. The
# pane's own start command is the shell, so nothing about this pane records
# which conversation it is in.
adopt_run_agent() {
  tmux -L "$sock" send-keys -t "$1" "fake-agent --session-id $2" Enter
  adopt_wait_for_command "$1" fake-agent
}

# adopt_report <pane> <session-id> [state]
# What `canopy agent report` leaves on a pane. The state defaults to idle
# because most tests are about some other guard, and a pane that is mid
# task would be skipped before they got to it.
adopt_report() {
  tmux -L "$sock" set -p -t "$1" @canopy_agent_session "$2"
  tmux -L "$sock" set -p -t "$1" @canopy_agent_source fake-agent
  tmux -L "$sock" set -p -t "$1" @canopy_agent_state "${3:-idle}"
}

adopt_transcript() {
  cat "$FAKE_AGENT_HOME/$1.transcript" 2>/dev/null || true
}

# Rewrites one key in the installed adapter's manifest. Every key stays
# present, because the contract requires all six and a missing one fails
# the read rather than defaulting.
adopt_set_manifest_key() {
  local manifest tmp
  manifest="$CANOPY_CONFIG/adapters/fake-agent/manifest"
  tmp="$BATS_TEST_TMPDIR/manifest.$$"
  awk -v k="$1" -v v="$2" '
    $0 ~ "^" k "=" { print k "=" v; next }
    { print }
  ' "$manifest" >"$tmp"
  mv "$tmp" "$manifest"
}

# --- the pane is adopted ---------------------------------------------------

@test "--yes restarts a clean pane as its own resume command" {
  adopt_start
  adopt_run_agent "$pane" 11111111-2222-3333-4444-555555555555
  adopt_report "$pane" 11111111-2222-3333-4444-555555555555

  run canopy-adopt --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopted"* ]]

  adopt_wait_for_command "$pane" "--resume"
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --resume 11111111-2222-3333-4444-555555555555"* ]]
}

@test "the adopted pane continues the same conversation" {
  # The claim the milestone exists to make good on, at pane scale: the
  # transcript the agent was writing before adoption is the transcript it
  # writes to afterwards. A new id here would mean adopt had quietly
  # started a different conversation in the same pane.
  adopt_start
  adopt_run_agent "$pane" 99999999-8888-7777-6666-555555555555
  adopt_report "$pane" 99999999-8888-7777-6666-555555555555

  run canopy-adopt --yes
  [ "$status" -eq 0 ]
  adopt_wait_for_command "$pane" "--resume"

  [ "$(adopt_transcript 99999999-8888-7777-6666-555555555555)" = "launch 99999999-8888-7777-6666-555555555555
resume 99999999-8888-7777-6666-555555555555" ]
}

@test "a pane that already carries its resume command is left alone" {
  # Idempotence, and it is a safety property rather than a nicety: the
  # second run of a command that kills panes must not kill the panes the
  # first run just fixed.
  adopt_start
  adopt_run_agent "$pane" 22222222-3333-4444-5555-666666666666
  adopt_report "$pane" 22222222-3333-4444-5555-666666666666
  run canopy-adopt --yes
  [ "$status" -eq 0 ]
  adopt_wait_for_command "$pane" "--resume"

  run canopy-adopt --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
  [ "$(adopt_transcript 22222222-3333-4444-5555-666666666666)" = "launch 22222222-3333-4444-5555-666666666666
resume 22222222-3333-4444-5555-666666666666" ]
}

# --- the pane is left alone ------------------------------------------------

@test "a dry run is the default, and it changes nothing" {
  adopt_start
  adopt_run_agent "$pane" 33333333-4444-5555-6666-777777777777
  adopt_report "$pane" 33333333-4444-5555-6666-777777777777

  run canopy-adopt
  [ "$status" -eq 1 ]
  [[ "$output" == *"would adopt"* ]]
  [[ "$output" == *"--yes"* ]]

  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 33333333-4444-5555-6666-777777777777"* ]]
  [ "$(adopt_transcript 33333333-4444-5555-6666-777777777777)" = "launch 33333333-4444-5555-6666-777777777777" ]
}

@test "a pane holding unsent input is skipped and named" {
  adopt_start
  adopt_run_agent "$pane" 44444444-5555-6666-7777-888888888888
  adopt_report "$pane" 44444444-5555-6666-7777-888888888888
  # What the fixture's detect_draft looks for: a non-empty file named for
  # the pane. The real thing is somebody's half-typed message.
  printf 'two pasted images and a paragraph\n' >"$FAKE_AGENT_HOME/$pane.draft"

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"main:0.0"* ]]
  [[ "$output" == *"unsent input"* ]]

  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 44444444-5555-6666-7777-888888888888"* ]]
  [ "$(adopt_transcript 44444444-5555-6666-7777-888888888888)" = "launch 44444444-5555-6666-7777-888888888888" ]
}

@test "a pane whose draft state cannot be determined is skipped" {
  # Fail closed. An adapter that cannot answer the question is not
  # permission to proceed, it is the same answer as yes.
  adopt_start
  adopt_set_manifest_key detect_draft ""
  adopt_run_agent "$pane" 55555555-6666-7777-8888-999999999999
  adopt_report "$pane" 55555555-6666-7777-8888-999999999999

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be determined"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 55555555-6666-7777-8888-999999999999"* ]]
}

@test "a detect_draft that fails in some third way is skipped, not read as no" {
  adopt_start
  adopt_set_manifest_key detect_draft "sh -c 'exit 7' {pane}"
  adopt_run_agent "$pane" 66666666-7777-8888-9999-aaaaaaaaaaaa
  adopt_report "$pane" 66666666-7777-8888-9999-aaaaaaaaaaaa

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be determined"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 66666666-7777-8888-9999-aaaaaaaaaaaa"* ]]
}

@test "a pane whose agent is mid task is skipped and named" {
  adopt_start
  adopt_run_agent "$pane" 77777777-8888-9999-aaaa-bbbbbbbbbbbb
  adopt_report "$pane" 77777777-8888-9999-aaaa-bbbbbbbbbbbb working

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"mid task"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 77777777-8888-9999-aaaa-bbbbbbbbbbbb"* ]]
}

@test "a pane that has reported no state at all is skipped" {
  # Not the same as idle. Nothing has said what this pane is doing, and
  # the whole point of the guard is to not guess.
  adopt_start
  adopt_run_agent "$pane" 88888888-9999-aaaa-bbbb-cccccccccccc
  tmux -L "$sock" set -p -t "$pane" @canopy_agent_session 88888888-9999-aaaa-bbbb-cccccccccccc
  tmux -L "$sock" set -p -t "$pane" @canopy_agent_source fake-agent

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"has not reported"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id 88888888-9999-aaaa-bbbb-cccccccccccc"* ]]
}

@test "a pane with no session id is skipped, and told why nothing can be done" {
  # The case M3 removes by supplying ids at launch. Until then there is
  # nothing to resume: no id exists anywhere for this conversation, and
  # minting a fresh one would pin the pane by throwing away what it holds.
  adopt_start
  adopt_run_agent "$pane" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

  run canopy-adopt --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session id"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
}

@test "a pane that is not running an agent is never touched" {
  adopt_start
  run canopy-adopt --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"no agent panes"* ]]
}

# --- the shape of the command ----------------------------------------------

@test "adopt says nothing alarming when there is no tmux server" {
  # Points $TMUX at a socket path where nothing is listening rather than
  # unsetting it: an unset $TMUX falls through to the default socket,
  # which on a developer's machine is their real session.
  TMUX="$BATS_TEST_TMPDIR/no-such-socket,0,0"
  export TMUX
  run canopy-adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tmux server"* ]]
}

@test "--dry-run is accepted explicitly and means the same as the default" {
  adopt_start
  adopt_run_agent "$pane" bbbbbbbb-cccc-dddd-eeee-ffffffffffff
  adopt_report "$pane" bbbbbbbb-cccc-dddd-eeee-ffffffffffff

  run canopy-adopt --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"would adopt"* ]]
  [[ "$(canopy_pane_command "$pane")" == *"fake-agent --session-id bbbbbbbb-cccc-dddd-eeee-ffffffffffff"* ]]
}

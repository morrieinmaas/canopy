#!/usr/bin/env bats
load helper

# canopy's save-command strategy: the piece that makes resurrect record an
# agent pane as the command that RESUMES its conversation instead of the
# command that happened to start it.
#
# Two properties are under test here and they are not symmetrical. That an
# agent pane comes back resumed is the feature. That every other pane is
# recorded byte for byte as resurrect would have recorded it is the
# guarantee: this code runs inside resurrect's save path, on every pane of
# every session, every time continuum fires. A strategy that mangles an
# ordinary shell pane, or that fails and records an empty command, is worse
# than no strategy at all, because it breaks persistence for panes canopy
# was never asked to manage.
#
# Every test that starts tmux does so on its own named socket and with a
# scratch $HOME. Nothing here may reach the default socket: on a
# developer's machine that is their real session, holding real work.
setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/adapter.sh"
  . "$CANOPY_STORE/lib/pane.sh"
  canopy_paths

  fixtures="$BATS_TEST_DIRNAME/fixtures"
  strategy="$CANOPY_STORE/plugins/strategies/canopy_save_command.sh"
  default_strategy="$CANOPY_STORE/plugins/tmux-resurrect/save_command_strategies/ps.sh"

  FAKE_AGENT_HOME="$BATS_TEST_TMPDIR/agent-home"
  export FAKE_AGENT_HOME
  mkdir -p "$FAKE_AGENT_HOME"

  # The fixture agent under the bare name its adapter's `command` key
  # names, for the one lookup here that goes through the pane's command
  # line rather than through the pane's options.
  agent_bin="$BATS_TEST_TMPDIR/agentbin"
  mkdir -p "$agent_bin"
  ln -sf "$fixtures/fake-agent" "$agent_bin/fake-agent"
  PATH="$agent_bin:$PATH"
  export PATH

  sock=""
  pane=""
}

# Cleanup lives in teardown, not at the end of each test: bats aborts a
# test at its first failing command, so a kill placed after the assertion
# never runs on the day it matters and the socket leaks.
teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

# strategy_tmux_start [pane-command]
# A scratch server with $TMUX exported, because that is how the strategy
# finds its server for real: resurrect's save runs it as a plain child
# process with no -L and no target, and the only thing telling it which
# tmux to talk to is the environment.
#
# The closing assertion is not ceremony. When $TMUX does not parse, tmux
# silently falls back to the DEFAULT socket, and a test that quietly read
# a developer's real session would still look green.
strategy_tmux_start() {
  sock="cnp-save-$$-${BATS_TEST_NUMBER}"
  if [ "$#" -gt 0 ]; then
    tmux -L "$sock" -f /dev/null new-session -d "$1"
  else
    tmux -L "$sock" -f /dev/null new-session -d
  fi
  # The resume stagger is off for every test in this file. What is under
  # test here is which command a pane is saved as, and a wait in front of
  # it would only make each assertion say so twice. The wrapper has its own
  # file, test/stagger.bats.
  tmux -L "$sock" set -g @canopy_resume_stagger_ms 0
  hold_off_boot_restore "$sock"
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  export TMUX
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

pane_pid_of() { tmux -L "$sock" display-message -p -t "$1" '#{pane_pid}'; }

# mark_agent_pane <pane> <session-id> [source]
# What `canopy agent report` leaves on a pane. The source is optional on
# purpose: a pane can carry a session id and no source, and the strategy
# has to cope with that rather than assume one writer wrote both.
mark_agent_pane() {
  tmux -L "$sock" set -p -t "$1" @canopy_agent_session "$2"
  if [ "$#" -gt 2 ]; then
    tmux -L "$sock" set -p -t "$1" @canopy_agent_source "$3"
  fi
  return 0
}

install_fake_adapter() {
  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"
}

write_fake_adapter_manifest() {
  mkdir -p "$CANOPY_CONFIG/adapters/fake-agent"
  cat >"$CANOPY_CONFIG/adapters/fake-agent/manifest"
}

# Bounded waits, so a pane whose program never starts fails in a few
# seconds rather than making every run pay for the slowest machine.
wait_for_default_output() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -n "$("$default_strategy" "$1")" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_pane_command() {
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

wait_for_file() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- the feature -----------------------------------------------------------

@test "an agent pane is recorded as its adapter's resume command" {
  install_fake_adapter
  strategy_tmux_start
  mark_agent_pane "$pane" 11111111-2222-3333-4444-555555555555 fake-agent
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent --resume 11111111-2222-3333-4444-555555555555" ]
}

@test "an adapter that cannot pin an id at launch resumes by id all the same" {
  # The whole reason the id is read off the pane option rather than parsed
  # back out of the launch command: an agent that cannot be handed an id
  # when it starts is still resumable, because canopy learns the id from
  # the agent's own report and never needs it to have been on the command
  # line.
  write_fake_adapter_manifest <<'MANIFEST'
id=fake-agent
command=fake-agent
resume_template=fake-agent --resume {id}
can_pin_at_launch=no
launch_template=
detect_draft=
MANIFEST
  strategy_tmux_start
  mark_agent_pane "$pane" 66666666-7777-8888-9999-000000000000 fake-agent
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent --resume 66666666-7777-8888-9999-000000000000" ]
}

@test "a pane that reported a session id but no source is resolved through the command it runs" {
  # The three pane options are written by more than one caller, and a hook
  # that reports only a state leaves the source empty. The id is still
  # there, so the pane is still resumable: the adapter comes from the
  # command the pane is running, through the same lookup every other
  # canopy command uses.
  install_fake_adapter
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "fake-agent --session-id aaaa-bbbb" Enter
  wait_for_pane_command "$pane" fake-agent
  mark_agent_pane "$pane" aaaa-bbbb
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent --resume aaaa-bbbb" ]
}

@test "the pid resurrect passes picks out its own pane, with several open" {
  install_fake_adapter
  strategy_tmux_start
  tmux -L "$sock" new-window -d
  other="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | tail -1)"
  [ "$other" != "$pane" ]
  mark_agent_pane "$pane" uuid-one fake-agent
  mark_agent_pane "$other" uuid-two fake-agent
  run "$strategy" "$(pane_pid_of "$other")"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent --resume uuid-two" ]
}

# --- the guarantee ---------------------------------------------------------

@test "a pane with no agent session is recorded exactly as resurrect would have recorded it" {
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ] # a comparison of two empty strings proves nothing
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "an agent pane whose adapter canopy does not have is left alone, not mangled" {
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  mark_agent_pane "$pane" cccc-dddd an-agent-canopy-has-never-heard-of
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "a broken adapter manifest falls back to resurrect's own answer, not to a partial one" {
  # The lookup made to fail on purpose. A manifest whose resume_template
  # has no {id} is a fatal error everywhere else in canopy, and this is the
  # one path where dying is not allowed: resurrect is waiting for a line,
  # and an empty one would erase what that pane was running.
  write_fake_adapter_manifest <<'MANIFEST'
id=fake-agent
command=fake-agent
resume_template=fake-agent --resume
can_pin_at_launch=yes
launch_template=fake-agent --session-id {id}
detect_draft=
MANIFEST
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  mark_agent_pane "$pane" eeee-ffff fake-agent
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "a session id carrying a tab is recorded as resurrect would have recorded it" {
  # resurrect's save file is tab delimited, one line per pane. A command
  # with a tab in it would not merely lose this pane, it would move every
  # field that comes after it on the line.
  install_fake_adapter
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  mark_agent_pane "$pane" "$(printf 'bad\tid')" fake-agent
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "a store with no adapters at all still records every pane" {
  CANOPY_CONFIG="$BATS_TEST_TMPDIR/empty-config"
  export CANOPY_CONFIG
  mkdir -p "$CANOPY_CONFIG"
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  mark_agent_pane "$pane" 1111-2222
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "no pid at all is recorded as nothing, exactly as resurrect's own strategy does it" {
  strategy_tmux_start
  run "$strategy"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run "$default_strategy"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a pid belonging to no pane on this server is recorded as resurrect would record it" {
  strategy_tmux_start
  run "$strategy" 999999999
  [ "$status" -eq 0 ]
  [ "$output" = "$("$default_strategy" 999999999)" ]
}

# --- how resurrect reaches it ----------------------------------------------

@test "30-plugins.conf points resurrect at canopy's strategy file and nowhere else" {
  # resurrect builds exactly one path out of this option:
  #   <its own tree>/save_command_strategies/<option>.sh
  # and falls back to its default when that path does not exist. The test
  # builds the same path by hand, so a change to either end is caught here
  # rather than by a user whose agent panes quietly stopped resuming.
  strategy_tmux_start
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  value="$(tmux -L "$sock" show -gv @resurrect-save-command-strategy)"
  [ -n "$value" ]
  resolved="$CANOPY_STORE/plugins/tmux-resurrect/save_command_strategies/$value.sh"
  [ -x "$resolved" ]
  [ "$resolved" -ef "$strategy" ]
}

@test "resurrect's own save writes the resume command into the save file" {
  # End to end through resurrect itself, which is the only test here that
  # proves resurrect resolves canopy's strategy at all. Everything above
  # would still pass if the option pointed nowhere and resurrect quietly
  # used its default.
  install_fake_adapter
  strategy_tmux_start
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  mark_agent_pane "$pane" 12345678-90ab-cdef-1234-567890abcdef fake-agent
  tmux -L "$sock" run-shell "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh quiet"
  wait_for_file "$CANOPY_STATE/resurrect/last"
  run cat "$CANOPY_STATE/resurrect/last"
  [ "$status" -eq 0 ]
  [[ "$output" == *":fake-agent --resume 12345678-90ab-cdef-1234-567890abcdef"* ]]
}

@test "resurrect's own save leaves a pane that is not an agent alone" {
  strategy_tmux_start
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  tmux -L "$sock" run-shell "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh quiet"
  wait_for_file "$CANOPY_STATE/resurrect/last"
  run cat "$CANOPY_STATE/resurrect/last"
  [ "$status" -eq 0 ]
  [[ "$output" == *":$expected"* ]]
}

@test "a restored pane is saved with its resume command, and the stagger put back" {
  # Before, the lookup gave up on a pane with no session option and
  # resurrect's own strategy saved the running command verbatim. Right by
  # luck, and without the stagger, so the reboot after that started every
  # agent in the same second.
  install_fake_adapter
  strategy_tmux_start
  tmux -L "$sock" send-keys -t "$pane" \
    "fake-agent --resume ffffffff-1111-2222-3333-444444444444" Enter
  i=0
  while [ "$i" -lt 50 ]; do
    case "$(canopy_pane_command "$pane")" in
      *"--resume"*) break ;;
      *) ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  [ -z "$(tmux -L "$sock" display-message -p -t "$pane" '#{@canopy_agent_session}')" ]
  tmux -L "$sock" set -g @canopy_resume_stagger_ms 400

  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [[ "$output" == "sleep "*" && fake-agent --resume ffffffff-1111-2222-3333-444444444444" ]]
}

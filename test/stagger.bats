#!/usr/bin/env bats
load helper

# The stagger: ten agent panes restored at once would otherwise launch ten
# agents at once, and an agent is not a cheap process.
#
# The wrapper is baked into the command resurrect saves, so it lands in the
# command line a human may later read in the save file or type again by
# hand. That is why it is a plain `sleep` and an `&&` rather than anything
# cleverer: whoever reads it should need no explanation.
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

  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"

  # On PATH before any tmux server starts, because a server inherits the
  # environment of whoever started it and the panes inherit it from there.
  agent_bin="$BATS_TEST_TMPDIR/agentbin"
  mkdir -p "$agent_bin"
  ln -sf "$fixtures/fake-agent" "$agent_bin/fake-agent"
  PATH="$agent_bin:$PATH"
  export PATH

  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

stagger_tmux_start() {
  sock="cnp-stagger-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" -f /dev/null new-session -d
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  export TMUX
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

pane_pid_of() { tmux -L "$sock" display-message -p -t "$1" '#{pane_pid}'; }

mark_agent_pane() {
  tmux -L "$sock" set -p -t "$1" @canopy_agent_session "$2"
  tmux -L "$sock" set -p -t "$1" @canopy_agent_source fake-agent
}

# The delay the emitted command carries, in milliseconds, or "none" when it
# carries no wrapper at all.
delay_ms_of() {
  case "$1" in
    "sleep "*" && "*)
      local seconds="${1#sleep }"
      seconds="${seconds%% &&*}"
      local whole="${seconds%%.*}"
      local frac="${seconds#*.}"
      printf '%s\n' "$((whole * 1000 + frac))"
      ;;
    *) printf 'none\n' ;;
  esac
}

wait_for_default_output() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -n "$("$default_strategy" "$1")" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- the wrapper -----------------------------------------------------------

@test "by default an agent pane's saved command waits before it starts" {
  stagger_tmux_start
  mark_agent_pane "$pane" 11111111-2222-3333-4444-555555555555
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [[ "$output" == "sleep "*" && fake-agent --resume 11111111-2222-3333-4444-555555555555" ]]
}

@test "the option at 0 emits no wrapper at all, not a wrapper waiting zero" {
  stagger_tmux_start
  tmux -L "$sock" set -g @canopy_resume_stagger_ms 0
  mark_agent_pane "$pane" 66666666-7777-8888-9999-000000000000
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent --resume 66666666-7777-8888-9999-000000000000" ]
}

@test "the wait never exceeds the option's value, and differs between panes" {
  # Both halves matter. Bounded, because a wait nobody asked for is a pane
  # that looks hung. Different per pane, because a stagger that gives every
  # pane the same wait is not a stagger, it is a pause.
  stagger_tmux_start
  tmux -L "$sock" set -g @canopy_resume_stagger_ms 400
  tmux -L "$sock" new-window -d
  tmux -L "$sock" new-window -d
  delays=""
  for p in $(tmux -L "$sock" list-panes -a -F '#{pane_id}'); do
    mark_agent_pane "$p" "id-$p"
    out="$("$strategy" "$(pane_pid_of "$p")")"
    ms="$(delay_ms_of "$out")"
    [ "$ms" != "none" ]
    [ "$ms" -ge 1 ]
    [ "$ms" -le 400 ]
    delays="$delays$ms "
  done
  distinct="$(printf '%s\n' $delays | sort -u | wc -l)"
  [ "$distinct" -ge 2 ]
}

@test "a nonsense option value falls back to the default rather than to no wrapper" {
  stagger_tmux_start
  tmux -L "$sock" set -g @canopy_resume_stagger_ms banana
  mark_agent_pane "$pane" aaaa-bbbb
  run "$strategy" "$(pane_pid_of "$pane")"
  [ "$status" -eq 0 ]
  [[ "$output" == "sleep "*" && fake-agent --resume aaaa-bbbb" ]]
}

# --- the guarantee ---------------------------------------------------------

@test "a pane that is not an agent is never wrapped" {
  # The wrapper belongs to canopy's own resume commands. Putting it in
  # front of a pane canopy was never asked to manage would change what that
  # pane runs on restore, which is not canopy's to change.
  stagger_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "sleep 600" Enter
  pid="$(pane_pid_of "$pane")"
  wait_for_default_output "$pid"
  expected="$("$default_strategy" "$pid")"
  [ -n "$expected" ]
  run "$strategy" "$pid"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "reboot-check still recognises a saved command carrying the wrapper" {
  # The wrapper is emitted into the save file, so the pre-flight that reads
  # that file has to know the pane resumes despite it.
  sock="cnp-stagger-rc-$$"
  tmux -L "$sock" -f /dev/null new-session -d -s main
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  export TMUX

  tmux -L "$sock" send-keys -t "$pane" "fake-agent --session-id cccc-dddd" Enter
  i=0
  while [ "$i" -lt 50 ]; do
    case "$(canopy_pane_command "$pane")" in
      *fake-agent*) break ;;
      *) ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  mark_agent_pane "$pane" cccc-dddd
  tmux -L "$sock" run-shell "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh quiet"
  i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$CANOPY_STATE/resurrect/last" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -q "sleep " "$CANOPY_STATE/resurrect/last"

  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"will resume"* ]]
}

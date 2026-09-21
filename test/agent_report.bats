#!/usr/bin/env bats
load helper

# `canopy agent report`, the pane-identity lookup it feeds, and the Claude
# Code adapter that calls it.
#
# Every test that starts tmux does so on its own named socket and with a
# scratch $HOME. Nothing here may reach the default socket: on a developer's
# machine that is their real session, holding real work.
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

  # The fixture agent reachable under the bare name its adapter's `command`
  # key names. The pane lookup matches a pane's command line, so the name on
  # that command line is the thing under test and it has to be the real one.
  agent_bin="$BATS_TEST_TMPDIR/agentbin"
  mkdir -p "$agent_bin"
  ln -sf "$fixtures/fake-agent" "$agent_bin/fake-agent"
  PATH="$agent_bin:$PATH"
  export PATH

  CLAUDE_CONFIG_DIR="$HOME/.claude"
  export CLAUDE_CONFIG_DIR

  sock=""
  pane=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

# agent_tmux_start [pane-command]
# A scratch tmux server, plus the two environment variables a hook inherits
# inside one of its panes: $TMUX, which names the server, and $TMUX_PANE.
# `canopy agent report` reaches its pane's server exactly the way a hook
# does, so the test has to stand in a pane rather than pass -L.
#
# The closing assertion is not ceremony. When $TMUX does not parse, tmux
# silently falls back to the DEFAULT socket, and a test that quietly wrote
# pane options onto a developer's real session would still look green.
agent_tmux_start() {
  sock="cnp-agent-$$-${BATS_TEST_NUMBER}"
  if [ "$#" -gt 0 ]; then
    tmux -L "$sock" -f /dev/null new-session -d "$1"
  else
    tmux -L "$sock" -f /dev/null new-session -d
  fi
  pane="$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  TMUX="$sock_path,0,0"
  TMUX_PANE="$pane"
  export TMUX TMUX_PANE
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

pane_opt() { tmux -L "$sock" show -pqv -t "$pane" "$1"; }

install_fake_adapter() {
  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"
}

# wait_for_pane_command <pane-id> <needle>
# Bounded wait for the pane lookup to see <needle>, so a pane whose program
# never starts fails in a second rather than making every run pay for the
# slowest machine.
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

# --- report: the write path ------------------------------------------------

@test "a report writes all four pane options" {
  agent_tmux_start
  run canopy-agent report working --source fake-agent --session-id 11111111-2222-3333-4444-555555555555
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_state)" = "working" ]
  [ "$(pane_opt @canopy_agent_source)" = "fake-agent" ]
  [ "$(pane_opt @canopy_agent_session)" = "11111111-2222-3333-4444-555555555555" ]
  [ -n "$(pane_opt @canopy_agent_ts)" ]
}

@test "the four options read back as tmux format variables, so nothing has to fork to render them" {
  agent_tmux_start
  canopy-agent report blocked --source fake-agent --session-id abc-123
  run tmux -L "$sock" display-message -p -t "$pane" \
    '#{@canopy_agent_state}/#{@canopy_agent_source}/#{@canopy_agent_session}'
  [ "$status" -eq 0 ]
  [ "$output" = "blocked/fake-agent/abc-123" ]
}

@test "an unchanged report is not written a second time" {
  agent_tmux_start
  canopy-agent report working --source fake-agent --session-id abc-123
  first_ts="$(pane_opt @canopy_agent_ts)"
  [ -n "$first_ts" ]

  # The chatty case: PostToolUse fires again with nothing new to say. The
  # timestamp is the witness, because it is the one value that would move on
  # every write.
  sleep 1.1
  run canopy-agent report working --source fake-agent --session-id abc-123
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_ts)" = "$first_ts" ]
}

@test "a real transition is written, and moves the timestamp" {
  agent_tmux_start
  canopy-agent report working --source fake-agent --session-id abc-123
  first_ts="$(pane_opt @canopy_agent_ts)"
  sleep 1.1
  run canopy-agent report blocked --source fake-agent --session-id abc-123
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_state)" = "blocked" ]
  [ "$(pane_opt @canopy_agent_ts)" != "$first_ts" ]
}

@test "a new session id is written even when the state is unchanged" {
  # /clear starts a fresh conversation in the same pane: a new session id
  # arrives with SessionStart, whose state is idle, and the pane may already
  # be idle. Debouncing on the state alone would leave the old id in place,
  # and the pane would come back after a reboot resumed into the wrong
  # conversation, which is the single failure this milestone exists to stop.
  agent_tmux_start
  canopy-agent report idle --source fake-agent --session-id first-session
  run canopy-agent report idle --source fake-agent --session-id second-session
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_session)" = "second-session" ]
}

@test "a report with no TMUX_PANE exits 0 and writes nothing" {
  agent_tmux_start
  unset TMUX_PANE
  run canopy-agent report working --source fake-agent --session-id abc-123
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(pane_opt @canopy_agent_state)" = "" ]
}

@test "a report whose pane is gone exits 0 rather than failing the agent's hook" {
  agent_tmux_start
  kill_tmux_server "$sock"
  sock=""
  run canopy-agent report working --source fake-agent --session-id abc-123
  [ "$status" -eq 0 ]
}

# --- report: argument handling ---------------------------------------------

@test "an invalid state is rejected, naming the state and the five that are valid" {
  agent_tmux_start
  run canopy-agent report busy
  [ "$status" -ne 0 ]
  [[ "$output" == *"busy"* ]]
  [[ "$output" == *"idle"* ]]
  [ "$(pane_opt @canopy_agent_state)" = "" ]
}

@test "every one of the five states is accepted" {
  agent_tmux_start
  for state in idle working blocked completed exited; do
    run canopy-agent report "$state"
    [ "$status" -eq 0 ]
    [ "$(pane_opt @canopy_agent_state)" = "$state" ]
  done
}

@test "an invalid state is rejected even outside tmux" {
  # A malformed hook is a bug in the adapter, and it must not be swallowed
  # by the same silence that covers an agent running in an IDE.
  unset TMUX_PANE
  run canopy-agent report nonsense
  [ "$status" -ne 0 ]
}

@test "report requires a state" {
  run canopy-agent report
  [ "$status" -ne 0 ]
}

@test "--source and --session-id each require a value" {
  agent_tmux_start
  run canopy-agent report working --source
  [ "$status" -ne 0 ]
  run canopy-agent report working --session-id
  [ "$status" -ne 0 ]
}

@test "canopy-agent rejects an unknown subcommand and an unknown flag the same way every command does" {
  run canopy-agent --definitely-not-a-flag
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-agent: unknown argument: --definitely-not-a-flag" ]
}

@test "canopy agent report dispatches through the canopy entry point" {
  agent_tmux_start
  run canopy agent report completed --source fake-agent --session-id abc-123
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_state)" = "completed" ]
}

# --- the pane lookup -------------------------------------------------------

@test "a pane is identified by its command line, which is not what pane_current_command reports" {
  install_fake_adapter
  agent_tmux_start
  tmux -L "$sock" send-keys -t "$pane" "fake-agent --session-id aaaa-bbbb" Enter
  wait_for_pane_command "$pane" fake-agent

  # The ruling this lookup exists for: tmux reports the interpreter, or on a
  # real machine an agent's version string, as pane_current_command. Matching
  # on it was never going to find the agent.
  current="$(tmux -L "$sock" display-message -p -t "$pane" '#{pane_current_command}')"
  [ "$current" != "fake-agent" ]

  run canopy_pane_adapter "$pane"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent" ]
}

@test "a pane whose agent was given as the pane's own command is identified too" {
  install_fake_adapter
  agent_tmux_start "fake-agent --session-id cccc-dddd"
  run canopy_pane_adapter "$pane"
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent" ]
}

@test "a pane running no known agent has no adapter" {
  install_fake_adapter
  agent_tmux_start
  run canopy_pane_adapter "$pane"
  [ "$output" = "" ]
}

@test "a pane running an agent canopy has no adapter for has no adapter" {
  agent_tmux_start "fake-agent --session-id eeee-ffff"
  run canopy_pane_adapter "$pane"
  [ "$output" = "" ]
}

@test "canopy_pane_agent_panes lists every pane running a known agent, and only those" {
  install_fake_adapter
  agent_tmux_start "fake-agent --session-id 1111-2222"
  tmux -L "$sock" new-window -d
  run canopy_pane_agent_panes
  [ "$status" -eq 0 ]
  [ "$output" = "$pane	fake-agent" ]
}

# --- the Claude Code adapter -----------------------------------------------

@test "the shipped claude-code adapter satisfies the contract without being copied anywhere" {
  run canopy_adapter_get claude-code id
  [ "$status" -eq 0 ]
  [ "$output" = "claude-code" ]
  [ "$(canopy_adapter_get claude-code command)" = "claude" ]
  [[ "$(canopy_adapter_get claude-code resume_template)" == *"--resume {id}"* ]]
  [ "$(canopy_adapter_get claude-code can_pin_at_launch)" = "yes" ]
  [[ "$(canopy_adapter_get claude-code launch_template)" == *"--session-id {id}"* ]]
  run canopy_adapter_list
  [[ "$output" == *"claude-code"* ]]
}

@test "hooks.json routes every event through the reporter, naming all five states and only those" {
  hooks="$CANOPY_STORE/adapters/claude-code/hooks.json"
  [ -f "$hooks" ]
  # Every hook command is "{report} <state>": the placeholder install
  # substitutes, then the state that event means. Read without a JSON parser
  # on purpose, so the check runs everywhere the suite does.
  used="$(grep -o '{report}[^"]*" [a-z]*' "$hooks" | sed 's/.* //' | sort -u | tr '\n' ' ')"
  [ "$used" = "blocked completed exited idle working " ]

  # no hook command that forgot to call the reporter
  [ "$(grep -c '{report}' "$hooks")" -eq "$(grep -c '"type": "command"' "$hooks")" ]

  # and the Notification split the design calls for
  [[ "$(cat "$hooks")" == *"permission_prompt"* ]]
  [[ "$(cat "$hooks")" == *"idle_prompt"* ]]
}

@test "report.sh turns a Claude Code hook payload into a pane report" {
  agent_tmux_start
  run sh -c 'printf "%s" "{\"session_id\":\"9f8e7d6c-0000-1111-2222-333344445555\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" | "$1" working' \
    sh "$CANOPY_STORE/adapters/claude-code/report.sh"
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_state)" = "working" ]
  [ "$(pane_opt @canopy_agent_source)" = "claude-code" ]
  [ "$(pane_opt @canopy_agent_session)" = "9f8e7d6c-0000-1111-2222-333344445555" ]
}

@test "report.sh is silent and exits 0 when the agent is not in a pane" {
  unset TMUX_PANE
  run sh -c 'printf "%s" "{\"session_id\":\"x\",\"hook_event_name\":\"Stop\"}" | "$1" completed' \
    sh "$CANOPY_STORE/adapters/claude-code/report.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "report.sh still reports a state when the payload carries no session id" {
  agent_tmux_start
  run sh -c 'printf "%s" "{\"hook_event_name\":\"Stop\"}" | "$1" completed' \
    sh "$CANOPY_STORE/adapters/claude-code/report.sh"
  [ "$status" -eq 0 ]
  [ "$(pane_opt @canopy_agent_state)" = "completed" ]
  [ "$(pane_opt @canopy_agent_session)" = "" ]
}

# --- agent install ---------------------------------------------------------

@test "agent install writes canopy's hooks into the agent's own configuration" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_CONFIG_DIR/settings.json" ]
  body="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
  [[ "$body" == *"$CANOPY_STORE/adapters/claude-code/report.sh"* ]]
  [[ "$body" != *"{report}"* ]]
  [[ "$body" == *"PostToolUse"* ]]
}

@test "agent install names the capability tier so the user meets it at install time" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier 1"* ]]
}

@test "canopy restore undoes an agent install" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{\n  "model": "opus",\n  "theme": "dark"\n}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
  before="$(canopy_sha256 "$CLAUDE_CONFIG_DIR/settings.json")"

  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$CLAUDE_CONFIG_DIR/settings.json")" != "$before" ]

  run canopy-restore --all
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$CLAUDE_CONFIG_DIR/settings.json")" = "$before" ]
}

@test "agent install keeps the settings the user already had" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{\n  "model": "opus",\n  "theme": "dark"\n}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  body="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
  [[ "$body" == *"opus"* ]]
  [[ "$body" == *"dark"* ]]
  [[ "$body" == *"report.sh"* ]]
}

@test "agent install keeps the user's own hooks on an event canopy also hooks" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/my/own/hook.sh" } ] }
    ]
  }
}
EOF
  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  body="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
  [[ "$body" == *"/my/own/hook.sh"* ]]
  [[ "$body" == *"report.sh"* ]]
}

@test "agent install run twice leaves one copy of canopy's hooks, not two" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  canopy-agent install claude-code
  once="$(grep -c 'report.sh' "$CLAUDE_CONFIG_DIR/settings.json")"
  [ "$once" -gt 0 ]
  run canopy-agent install claude-code
  [ "$status" -eq 0 ]
  [ "$(grep -c 'report.sh' "$CLAUDE_CONFIG_DIR/settings.json")" -eq "$once" ]
}

@test "agent install refuses an adapter that is not installed" {
  run canopy-agent install no-such-agent
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-agent"* ]]
}

@test "agent install refuses an adapter that ships no installer" {
  install_fake_adapter
  run canopy-agent install fake-agent
  [ "$status" -ne 0 ]
  [[ "$output" == *"fake-agent"* ]]
}

@test "agent install requires an adapter id" {
  run canopy-agent install
  [ "$status" -ne 0 ]
}

@test "agent install refuses when the agent's own configuration directory is absent" {
  # Nothing to hook into, and creating the directory would be canopy
  # inventing a configuration for an agent that is not installed.
  rm -rf "$CLAUDE_CONFIG_DIR"
  run canopy-agent install claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"$CLAUDE_CONFIG_DIR"* ]]
  [ ! -e "$CLAUDE_CONFIG_DIR" ]
}

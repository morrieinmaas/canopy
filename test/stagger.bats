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
      # 10# because the fraction is printed zero padded to three digits,
      # and bash reads a leading zero as octal: a delay of 39ms arrives
      # here as "039" and aborts the test with "value too great for base".
      # Which delays a run produces depends on the pane pids it happened
      # to get, so this failed roughly one run in ten and looked random.
      printf '%s\n' "$((10#$whole * 1000 + 10#$frac))"
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
  hold_off_boot_restore "$sock"
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

@test "a leading zero falls back to the default rather than to octal or an error" {
  # 0500 is 320 in shell arithmetic, and 0900 is not a number at all:
  # "value too great for base", which fails the function and silently
  # drops the stagger from the saved command. A plain 0 still means off.
  . "$CANOPY_STORE/lib/resume.sh"
  [ -z "$(canopy_resume_stagger_prefix 12345 0)" ]
  [ -n "$(canopy_resume_stagger_prefix 12345 0500 2>&1)" ]
  [[ "$(canopy_resume_stagger_prefix 12345 0900 2>&1)" != *"base"* ]]
  [[ "$(canopy_resume_stagger_prefix 12345 0900 2>&1)" == "sleep "* ]]
}

@test "the wrapper a save writes matches the pattern the restore list carries" {
  # The wrapper's shape is written three times, in three languages: a printf
  # format in canopy_resume_stagger_prefix, a shell glob in
  # canopy_resume_stagger_strip, and an extended regex in
  # canopy_resume_stagger_pattern, which is what goes into
  # @resurrect-processes. Each has exactly one caller, so none of them
  # checks the others.
  #
  # The regex is the dangerous one. If it stopped matching what the prefix
  # emits, canopy would keep writing perfect resume commands and resurrect
  # would simply never replay them: the pane comes back a bare shell, the
  # conversation is gone, and nothing anywhere reports a failure. This test
  # is the only thing standing between those two literals.
  #
  # Matched with bash's own `=~` because that is literally what resurrect
  # uses: `[[ "$pane_full_command" =~ ($match) ]]` in
  # plugins/tmux-resurrect/scripts/process_restore_helpers.sh.
  . "$CANOPY_STORE/lib/resume.sh"
  pattern="$(canopy_resume_stagger_pattern)"

  # Pids chosen to land on both sides of a second: the format is
  # `sleep <whole>.<milli>`, and a delay under 1000ms gives `sleep 0.123`
  # while one over gives `sleep 1.023`.
  for pid in 1 2 7 999 12345 99999 2147483647; do
    for bound in 1 500 1000 5000; do
      wrapped="$(canopy_resume_stagger_prefix "$pid" "$bound")fake-agent --resume abc"
      [[ "$wrapped" =~ ($pattern) ]] || {
        printf 'pid=%s bound=%s produced %s, which the pattern %s does not match\n' \
          "$pid" "$bound" "$wrapped" "$pattern"
        false
      }
      # And the glob takes back off exactly what the format put on.
      [ "$(canopy_resume_stagger_strip "$wrapped")" = "fake-agent --resume abc" ]
    done
  done
}

@test "the restore list's own entry matches a staggered command end to end" {
  # One level up from the previous test: not the pattern in isolation, but
  # the entry as canopy_resume_processes_option actually emits it, matched
  # the way resurrect matches it, including stripping the leading ~ that
  # marks an entry as a regex rather than a word.
  . "$CANOPY_STORE/lib/resume.sh"
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]

  # resurrect splits the option with `eval set`, then drops the ~.
  eval "set -- $output"
  found=0
  for entry in "$@"; do
    case "$entry" in
      '~'*) ;;
      *) continue ;;
    esac
    match="${entry#\~}"
    case "$match" in
      *fake-agent) ;;
      *) continue ;;
    esac
    wrapped="$(canopy_resume_stagger_prefix 4242 1000)fake-agent --resume abc"
    [[ "$wrapped" =~ ($match) ]]
    found=1
  done
  [ "$found" -eq 1 ]
}

#!/usr/bin/env bats
load helper

setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/adapter.sh"
  canopy_paths
  fixtures="$BATS_TEST_DIRNAME/fixtures"
  fake_agent="$fixtures/fake-agent"
  FAKE_AGENT_HOME="$BATS_TEST_TMPDIR/agent-home"
  export FAKE_AGENT_HOME
  mkdir -p "$FAKE_AGENT_HOME"
  agent_pid=""
}

teardown() {
  [ -n "${agent_pid:-}" ] && kill "$agent_pid" 2>/dev/null
  return 0
}

# install_fake_adapter [id]
# Puts the fixture adapter where canopy looks for adapters, under the id
# canopy will address it by. This is deliberately a copy rather than a
# read from test/fixtures: the lookup key is the directory name, so an
# adapter has to be installed under its own id to be found at all, which
# is exactly what `canopy agent install` will do for a real one.
install_fake_adapter() {
  local id="${1:-fake-agent}"
  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/$id"
}

# write_adapter <id> <manifest-body>
# An adapter with a hand-written manifest, for the cases where the
# manifest is the thing under test.
write_adapter() {
  mkdir -p "$CANOPY_CONFIG/adapters/$1"
  printf '%s' "$2" >"$CANOPY_CONFIG/adapters/$1/manifest"
}

# wait_for_lines <uuid> <count>
# Bounded wait for the fixture to have written <count> lines. Bounded, and
# not a flat sleep, so a fixture that never writes fails in a second
# instead of making every run pay for the slowest machine.
wait_for_lines() {
  local i=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$FAKE_AGENT_HOME/$1.transcript" ] &&
      [ "$(wc -l <"$FAKE_AGENT_HOME/$1.transcript")" -ge "$2" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_transcript() { wait_for_lines "$1" 1; }

valid_manifest() {
  cat <<'EOF'
id=probe
command=probe
resume_template=probe --resume {id}
can_pin_at_launch=yes
launch_template=probe --session-id {id}
detect_draft=probe --has-draft {pane}
EOF
}

# --- the contract ----------------------------------------------------------

@test "the contract defines exactly six keys" {
  run canopy_adapter_keys
  [ "$status" -eq 0 ]
  set -- $output
  [ "$#" -eq 6 ]
  for key in id command resume_template can_pin_at_launch launch_template detect_draft; do
    [[ " $output " == *" $key "* ]]
  done
}

@test "every contract key is readable from the fixture adapter" {
  install_fake_adapter
  run canopy_adapter_get fake-agent id
  [ "$status" -eq 0 ]
  [ "$output" = "fake-agent" ]

  run canopy_adapter_get fake-agent command
  [ "$output" = "fake-agent" ]

  run canopy_adapter_get fake-agent resume_template
  [[ "$output" == *"--resume {id}"* ]]

  run canopy_adapter_get fake-agent can_pin_at_launch
  [ "$output" = "yes" ]

  run canopy_adapter_get fake-agent launch_template
  [[ "$output" == *"--session-id {id}"* ]]

  run canopy_adapter_get fake-agent detect_draft
  [ -n "$output" ]
  [[ "$output" == *"{pane}"* ]]
}

@test "a manifest key may hold spaces and is returned verbatim" {
  install_fake_adapter
  run canopy_adapter_get fake-agent resume_template
  [ "$output" = "fake-agent --resume {id}" ]
}

@test "comments and blank lines in a manifest are ignored" {
  write_adapter probe "$(
    printf '# what this adapter is for\n\n'
    valid_manifest
    printf '\n'
  )"
  run canopy_adapter_get probe command
  [ "$status" -eq 0 ]
  [ "$output" = "probe" ]
}

@test "a manifest with an unknown key is rejected, naming the key" {
  write_adapter probe "$(
    valid_manifest
    printf 'resume_timeout=30\n'
  )"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"resume_timeout"* ]]
}

@test "a manifest with a duplicate key is rejected" {
  write_adapter probe "$(
    valid_manifest
    printf 'command=probe2\n'
  )"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "a manifest missing a contract key is rejected, naming the key" {
  write_adapter probe "$(valid_manifest | grep -v '^detect_draft=')"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"detect_draft"* ]]
}

@test "a manifest line that is not key=value is rejected" {
  write_adapter probe "$(
    valid_manifest
    printf 'this is not a setting\n'
  )"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
}

@test "an id that disagrees with the directory name is rejected" {
  write_adapter probe "$(valid_manifest | sed 's/^id=probe$/id=something-else/')"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"something-else"* ]]
}

@test "can_pin_at_launch must be yes or no" {
  write_adapter probe "$(valid_manifest | sed 's/^can_pin_at_launch=yes$/can_pin_at_launch=true/')"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"can_pin_at_launch"* ]]
}

@test "resume_template must carry the {id} placeholder" {
  write_adapter probe "$(valid_manifest | sed 's/^resume_template=.*$/resume_template=probe --resume/')"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"{id}"* ]]
}

@test "launch_template must carry {id} when the agent can be pinned at launch" {
  write_adapter probe "$(valid_manifest | sed 's/^launch_template=.*$/launch_template=probe/')"
  run canopy_adapter_get probe command
  [ "$status" -ne 0 ]
  [[ "$output" == *"launch_template"* ]]
}

@test "launch_template may be empty when the agent cannot be pinned at launch" {
  write_adapter probe "$(
    valid_manifest |
      sed 's/^can_pin_at_launch=yes$/can_pin_at_launch=no/' |
      sed 's/^launch_template=.*$/launch_template=/'
  )"
  run canopy_adapter_get probe can_pin_at_launch
  [ "$status" -eq 0 ]
  [ "$output" = "no" ]
  run canopy_adapter_get probe launch_template
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "asking for a key the contract does not define is rejected" {
  install_fake_adapter
  run canopy_adapter_get fake-agent nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonsense"* ]]
}

@test "asking for an adapter that is not installed returns non-zero" {
  run canopy_adapter_get no-such-agent command
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-agent"* ]]
}

# --- listing ---------------------------------------------------------------

@test "canopy_adapter_list names every installed adapter" {
  install_fake_adapter
  install_fake_adapter other-agent
  run canopy_adapter_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake-agent"* ]]
  [[ "$output" == *"other-agent"* ]]
}

# empty_store
# Points the lookup at a store with no adapters/ tree at all. canopy now
# ships an adapter of its own, and the two claims below are about the
# lookup, not about what happens to be vendored in the tree this week.
empty_store() {
  CANOPY_STORE="$BATS_TEST_TMPDIR/empty-store"
  export CANOPY_STORE
  mkdir -p "$CANOPY_STORE"
}

@test "canopy_adapter_list is empty when nothing is installed" {
  empty_store
  run canopy_adapter_list
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a directory without a manifest is not an adapter" {
  empty_store
  mkdir -p "$CANOPY_CONFIG/adapters/not-an-adapter"
  run canopy_adapter_list
  [ "$output" = "" ]
}

@test "a user's adapter overrides a shipped one of the same id" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/adapters/probe"
  valid_manifest | sed 's/^command=probe$/command=shipped/' \
    >"$store_copy/adapters/probe/manifest"
  write_adapter probe "$(valid_manifest | sed 's/^command=probe$/command=mine/')"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy_adapter_get probe command
  [ "$status" -eq 0 ]
  [ "$output" = "mine" ]

  # and it is listed once, not twice
  run canopy_adapter_list
  [ "$(printf '%s\n' "$output" | grep -c '^probe$')" -eq 1 ]
}

# --- the fake agent --------------------------------------------------------

@test "the fake agent appends to the transcript named for its session id" {
  uuid="11111111-2222-3333-4444-555555555555"
  "$fake_agent" --session-id "$uuid" &
  agent_pid=$!
  wait_for_transcript "$uuid"
  [ -f "$FAKE_AGENT_HOME/$uuid.transcript" ]
  [[ "$(cat "$FAKE_AGENT_HOME/$uuid.transcript")" == *"$uuid"* ]]
}

@test "a resume appends to the same transcript rather than starting a new one" {
  uuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  "$fake_agent" --session-id "$uuid" &
  agent_pid=$!
  wait_for_transcript "$uuid"
  kill "$agent_pid"
  agent_pid=""

  "$fake_agent" --resume "$uuid" &
  agent_pid=$!
  wait_for_lines "$uuid" 2

  [ "$(wc -l <"$FAKE_AGENT_HOME/$uuid.transcript")" -eq 2 ]
  [ "$(ls "$FAKE_AGENT_HOME" | wc -l)" -eq 1 ]
  run head -1 "$FAKE_AGENT_HOME/$uuid.transcript"
  [[ "$output" == launch* ]]
  run tail -1 "$FAKE_AGENT_HOME/$uuid.transcript"
  [[ "$output" == resume* ]]
}

@test "the fake agent stays alive until it is killed" {
  uuid="99999999-8888-7777-6666-555555555555"
  "$fake_agent" --session-id "$uuid" &
  agent_pid=$!
  wait_for_transcript "$uuid"
  kill -0 "$agent_pid"
  kill "$agent_pid"
  agent_pid=""
}

@test "the fake agent rejects arguments that are not the two it accepts" {
  run "$fake_agent"
  [ "$status" -ne 0 ]
  run "$fake_agent" --resume
  [ "$status" -ne 0 ]
  run "$fake_agent" --what 1234
  [ "$status" -ne 0 ]
}

@test "the fake agent refuses to run without FAKE_AGENT_HOME" {
  unset FAKE_AGENT_HOME
  run "$fake_agent" --session-id 1234
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAKE_AGENT_HOME"* ]]
}

@test "the fixture adapter's templates name the fixture the tests run" {
  install_fake_adapter
  resume="$(canopy_adapter_get fake-agent resume_template)"
  launch="$(canopy_adapter_get fake-agent launch_template)"
  [ "${resume%% *}" = "fake-agent" ]
  [ "${launch%% *}" = "fake-agent" ]
}

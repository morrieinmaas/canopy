#!/usr/bin/env bats
load helper

# The other half of the restore loop.
#
# resurrect replays a pane's saved command only when that command matches
# @resurrect-processes. Without it, canopy can write a perfect resume
# command into the save file and resurrect will never type it back: the
# pane comes up as a bare shell and the conversation is gone. The list is
# generated from the adapters canopy has, so installing an adapter is what
# makes its panes restorable and a machine with no adapters changes
# nothing about what resurrect already did.
setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/adapter.sh"
  . "$CANOPY_STORE/lib/resume.sh"
  canopy_paths

  fixtures="$BATS_TEST_DIRNAME/fixtures"
  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

install_fake_adapter() {
  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"
}

# A store that ships no adapters of its own, so the list is built from the
# config directory alone.
use_empty_store() {
  CANOPY_STORE="$BATS_TEST_TMPDIR/empty-store"
  export CANOPY_STORE
  mkdir -p "$CANOPY_STORE"
}

# --- what goes in the list -------------------------------------------------

@test "a machine with no adapters gets an empty list" {
  use_empty_store
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "an adapter's command is absent before it is installed and present after" {
  use_empty_store
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [[ "$output" != *"fake-agent"* ]]

  install_fake_adapter
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake-agent"* ]]
}

@test "the list matches a saved command carrying the stagger wrapper" {
  # The stagger puts a wait in front of the saved command, and resurrect
  # anchors a plain entry at the start of the line. An entry for the bare
  # command alone would stop matching the moment the wrapper appeared.
  use_empty_store
  install_fake_adapter
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [[ "$output" == *"~^sleep "*"fake-agent"* ]]
}

@test "a command that is not a plain word is left out" {
  # The value is split by resurrect with `eval set`, so a command carrying
  # shell syntax would be run rather than matched. An adapter naming one is
  # dropped: its panes are not restorable, which is a loss, and running its
  # manifest as code would be a hole.
  use_empty_store
  mkdir -p "$CANOPY_CONFIG/adapters/sneaky"
  cat >"$CANOPY_CONFIG/adapters/sneaky/manifest" <<'MANIFEST'
id=sneaky
command=agent`touch /tmp/canopy-pwned`
resume_template=agent --resume {id}
can_pin_at_launch=no
launch_template=
detect_draft=
MANIFEST
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [[ "$output" != *"touch"* ]]
}

@test "the shipped adapters are in the list, not only the ones under config" {
  run canopy_resume_processes_option
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
}

# --- how the option reaches the server -------------------------------------

@test "sourcing the plugin layer sets the option from the adapters on disk" {
  install_fake_adapter
  sock="cnp-procs-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  value="$(tmux -L "$sock" show -gqv @resurrect-processes)"
  [[ "$value" == *"fake-agent"* ]]
}

@test "without that adapter the option does not name it" {
  sock="cnp-procs-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  value="$(tmux -L "$sock" show -gqv @resurrect-processes)"
  [[ "$value" != *"fake-agent"* ]]
}

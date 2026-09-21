#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

@test "prints the store's VERSION file" {
  run canopy-version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$CANOPY_STORE/VERSION")" ]
}

@test "rejects an unknown argument instead of silently ignoring it" {
  run canopy-version --short
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-version: unknown argument: --short" ]
}

@test "every command that takes no options rejects an unknown argument the same way" {
  # The shape is one message and one exit code across the whole CLI: a
  # typo must not be swallowed by one command and refused by the next.
  for cmd in caps doctor index install reboot-check restore version; do
    run "canopy-$cmd" --definitely-not-a-flag
    [ "$status" -eq 1 ]
    [ "$output" = "canopy: canopy-$cmd: unknown argument: --definitely-not-a-flag" ]
  done
}

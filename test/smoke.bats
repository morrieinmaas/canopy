#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

@test "helper isolates every CANOPY path into the test tmpdir" {
  [ -d "$CANOPY_CONFIG" ]
  [ -d "$CANOPY_STATE" ]
  case "$CANOPY_CONFIG" in "$BATS_TEST_TMPDIR"/*) ;; *) false ;; esac
  case "$CANOPY_STATE"  in "$BATS_TEST_TMPDIR"/*) ;; *) false ;; esac
}

@test "store points at the repo checkout" {
  [ -f "$CANOPY_STORE/README.md" ]
}

@test "the restricted PATH still resolves tmux, on whatever machine this is" {
  # The invariant three test files quietly depended on and none of them
  # checked. restricted_path used to name this developer's package
  # prefix, which exists on no other machine, so on CI it produced a PATH
  # with no tmux: `canopy install` then had nothing to validate the config
  # it had just written with, and failed there while passing here.
  #
  # Asserted rather than assumed, because the failure it causes appears in
  # install and doctor, several layers from the helper that caused it.
  run env PATH="$(restricted_path)" sh -c 'command -v tmux'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

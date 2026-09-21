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

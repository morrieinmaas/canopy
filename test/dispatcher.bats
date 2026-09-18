#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

@test "dispatches to a subcommand" {
  run canopy version
  [ "$status" -eq 0 ]
}

@test "help lists commands grouped, using summary metadata" {
  run canopy help
  [ "$status" -eq 0 ]
  [[ "$output" == *"core"* ]]
  [[ "$output" == *"Print the canopy version"* ]]
}

@test "unknown command exits 2 and suggests" {
  run canopy verzion
  [ "$status" -eq 2 ]
  [[ "$output" == *"version"* ]]
}

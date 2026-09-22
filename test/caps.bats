#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

# The restricted PATH these tests run under lives in test/helper.bash.

@test "generates 05-caps.conf under CANOPY_STATE" {
  run canopy-caps
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_STATE/05-caps.conf" ]
}

@test "a tool that is absent yields 0" {
  PATH="$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -qx 'set -g @canopy_has_wt 0' "$CANOPY_STATE/05-caps.conf"
  grep -qx 'set -g @canopy_has_fzf 0' "$CANOPY_STATE/05-caps.conf"
}

@test "a tool that is present yields 1" {
  fake_bin="$BATS_TEST_TMPDIR/fakebin-present"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/fzf" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/fzf"
  PATH="$fake_bin:$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -qx 'set -g @canopy_has_fzf 1' "$CANOPY_STATE/05-caps.conf"
}

@test "sets the tmux version option" {
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -q '^set -g @canopy_tmux_version ' "$CANOPY_STATE/05-caps.conf"
}

@test "running twice produces byte-identical output" {
  run canopy-caps
  [ "$status" -eq 0 ]
  first="$(cat "$CANOPY_STATE/05-caps.conf")"
  run canopy-caps
  [ "$status" -eq 0 ]
  second="$(cat "$CANOPY_STATE/05-caps.conf")"
  [ "$first" = "$second" ]
}

@test "running twice under restricted PATH is also byte-identical" {
  PATH="$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  first="$(cat "$CANOPY_STATE/05-caps.conf")"
  run canopy-caps
  [ "$status" -eq 0 ]
  second="$(cat "$CANOPY_STATE/05-caps.conf")"
  [ "$first" = "$second" ]
}

@test "--print writes a human summary to stdout without changing the file" {
  run canopy-caps --print
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux"* ]]
  [ -f "$CANOPY_STATE/05-caps.conf" ]
}

@test "plain run (no --print) writes no stdout" {
  run canopy-caps
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the generated file loads under the tmux loader" {
  run canopy-caps
  [ "$status" -eq 0 ]
  # The loader is sourced with this harness's CANOPY_* in the server
  # environment, standing in for the installed entry point's
  # set-environment lines. Whether the shipped entry point really provides
  # them is test/installed_entry.bats' job, from a bare environment.
  sock="canopy-test-capsload-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  run tmux -L "$sock" source-file "$CANOPY_STORE/tmux/tmux.conf"
  kill_tmux_server "$sock"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
load helper

setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
}

# This file exercises the store's own tmux.conf, which reads its three
# paths from the tmux server's environment and so only loads when something
# has put them there. That something is the installed entry point, and
# whether it does is a question about the shipped artifact, not about this
# loader: test/installed_entry.bats answers it from a bare environment.
# Here the harness stands in for the stub, which is the repo checkout case.
@test "the shipped config loads on a scratch socket when the paths are set" {
  sock="canopy-test-shipped-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  run tmux -L "$sock" source-file "$CANOPY_STORE/tmux/tmux.conf"
  kill_tmux_server "$sock"
  [ "$status" -eq 0 ]
}

@test "user.conf is sourced last and wins" {
  mkdir -p "$CANOPY_CONFIG"
  echo 'set -g @canopy_test_marker user-wins' > "$CANOPY_CONFIG/user.conf"
  sock="canopy-test-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @canopy_test_marker
  kill_tmux_server "$sock"
  [ "$output" = "user-wins" ]
}

@test "canopy_tmux_validate fails with captured stderr for a broken config" {
  bad="$BATS_TEST_TMPDIR/bad.conf"
  printf 'totally-not-a-real-tmux-command\n' > "$bad"
  run canopy_tmux_validate "$bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"totally-not-a-real-tmux-command"* ]]
}

@test "canopy_tmux_validate fails for a missing file" {
  run canopy_tmux_validate "$BATS_TEST_TMPDIR/does-not-exist.conf"
  [ "$status" -ne 0 ]
}

@test "canopy_tmux_version_ok accepts the installed tmux" {
  run canopy_tmux_version_ok
  [ "$status" -eq 0 ]
}

@test "canopy_tmux_version_ok rejects a tmux below the 3.4 floor" {
  fake_bin="$BATS_TEST_TMPDIR/fakebin-low"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/tmux" <<'EOF'
#!/bin/sh
echo "tmux 3.3a"
EOF
  chmod +x "$fake_bin/tmux"
  PATH="$fake_bin:$PATH"
  run canopy_tmux_version_ok
  [ "$status" -ne 0 ]
}

@test "canopy_tmux_version_ok accepts a tmux exactly at the 3.4 floor" {
  fake_bin="$BATS_TEST_TMPDIR/fakebin-floor"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/tmux" <<'EOF'
#!/bin/sh
echo "tmux 3.4"
EOF
  chmod +x "$fake_bin/tmux"
  PATH="$fake_bin:$PATH"
  run canopy_tmux_version_ok
  [ "$status" -eq 0 ]
}

@test "05-caps.conf is sourced from CANOPY_STATE, immediately after 00-core" {
  mkdir -p "$CANOPY_STATE"
  echo 'set -g @canopy_caps_marker present' > "$CANOPY_STATE/05-caps.conf"
  sock="canopy-test-caps-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @canopy_caps_marker
  kill_tmux_server "$sock"
  [ "$output" = "present" ]
}

@test "00-core.conf is sourced exactly once, not re-sourced by the layer glob" {
  # The store is read-only by convention; copy the tree so a counter line
  # can be planted in 00-core.conf without touching the checked-out file.
  # set -ga appends, so a single source yields "x" and a double source
  # (the bug this loader guards against) would yield "xx".
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf 'set -ga @canopy_test_counter x\n' >>"$store_copy/tmux/conf.d/00-core.conf"

  sock="canopy-test-sourceonce-$$"
  CANOPY_STORE="$store_copy" tmux -L "$sock" -f "$store_copy/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @canopy_test_counter
  kill_tmux_server "$sock"
  [ "$output" = "x" ]
}

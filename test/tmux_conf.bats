#!/usr/bin/env bats
load helper

setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
}

@test "the shipped config loads on a scratch socket" {
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

@test "user.conf is sourced last and wins" {
  mkdir -p "$CANOPY_CONFIG"
  echo 'set -g @canopy_test_marker user-wins' > "$CANOPY_CONFIG/user.conf"
  sock="canopy-test-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @canopy_test_marker
  tmux -L "$sock" kill-server
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
  tmux -L "$sock" kill-server
  [ "$output" = "present" ]
}

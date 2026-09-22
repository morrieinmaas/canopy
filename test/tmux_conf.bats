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

@test "canopy_tmux_validate works when tmux is reached through a wrapper that needs the environment" {
  # Validation used to run tmux under `env -i`, which strips everything. A
  # tmux reached through a shim (mise, asdf, a distro wrapper) is a program
  # that needs its environment to find the binary it forwards to, so env -i
  # killed it before it ever ran: that is how milestone 1's macOS CI broke.
  # Isolation now means unsetting exactly the four CANOPY_* roots, which is
  # the property the bare environment was ever actually about.
  real_tmux="$(command -v tmux)"
  shim_dir="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim_dir"
  cat >"$shim_dir/tmux" <<EOF
#!/bin/sh
# Stands in for a version-manager shim: without its own variable in the
# environment it cannot work out what to forward to.
[ -n "\${CANOPY_TEST_SHIM_TARGET-}" ] || {
  echo "shim: CANOPY_TEST_SHIM_TARGET is not set" >&2
  exit 127
}
exec "\$CANOPY_TEST_SHIM_TARGET" "\$@"
EOF
  chmod +x "$shim_dir/tmux"
  CANOPY_TEST_SHIM_TARGET="$real_tmux"
  export CANOPY_TEST_SHIM_TARGET
  PATH="$shim_dir:$PATH"

  good="$BATS_TEST_TMPDIR/good.conf"
  printf 'set -g @canopy_shim_marker ok\n' >"$good"
  run canopy_tmux_validate "$good"
  [ "$status" -eq 0 ]
}

@test "validation still hides CANOPY_* from the tmux server it starts" {
  # The reason the bare environment exists at all: tmux expands a variable
  # in a source-file path from the SERVER's environment, which on a user's
  # machine holds no CANOPY_* at all. A config that resolves only because
  # the caller exported CANOPY_STORE is a config that loads nothing for the
  # person who installed it, and that shipped once, green, past 93 tests.
  conf="$BATS_TEST_TMPDIR/needs-store.conf"
  printf 'source-file "$CANOPY_STORE/tmux/conf.d/00-core.conf"\n' >"$conf"
  run canopy_tmux_validate "$conf"
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

@test "canopy_tmux_loaded_option reads the value the config actually loads" {
  . "$CANOPY_STORE/lib/tmux.sh"
  conf="$BATS_TEST_TMPDIR/sets.conf"
  printf 'set -g @canopy_probe loaded\n' >"$conf"
  run canopy_tmux_loaded_option "$conf" @canopy_probe
  [ "$status" -eq 0 ]
  [ "$output" = "loaded" ]
}

@test "canopy_tmux_loaded_option gives up on a config that does not load, and leaves no server running" {
  # The regression this pins is a deadlock, not a wrong answer. Asking a
  # scratch server for an option in the same command chain that sources
  # the config leaves the client waiting when the source fails, while the
  # scratch session holds the reader's pipe open, so the kill-server that
  # would end it cannot run until the session's own sleep expires. It once
  # held a CI run open for ten minutes after every test had passed.
  #
  # A return of this bug shows up as this test never finishing, and as the
  # surviving server the last assertion looks for.
  . "$CANOPY_STORE/lib/tmux.sh"
  broken="$BATS_TEST_TMPDIR/broken.conf"
  printf 'this-is-not-a-tmux-command\n' >"$broken"

  run canopy_tmux_loaded_option "$broken" @canopy_probe
  [ "$status" -ne 0 ]

  run bare_tmux -L "canopy-option-$$" list-sessions
  [ "$status" -ne 0 ]
}

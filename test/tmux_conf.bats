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

@test "canopy_tmux_validate leaves \$HOME exactly as it found it" {
  # Regression test for a defect found while milestone 2 exercised this
  # code from a different direction: a bare `new-session -d` starts
  # whatever login shell the passwd entry names, and that shell can write
  # into $HOME on startup (a history file, a completion cache, whatever its
  # rc files do). validate runs during install, restore and doctor, all of
  # which promise never to leave a mark on $HOME, so this asserts the
  # property directly rather than the mechanism: run validate, then $HOME
  # must hold exactly the files it held before, nothing more. Seeded with
  # rc/profile files for both zsh and bash so whichever shell the local
  # passwd entry names has something to run.
  #
  # Whether the shell actually gets far enough to write before validate's
  # own kill-server call is itself a race (that is why it shipped past 93
  # tests): on this machine a single attempt reproduces it only one time in
  # roughly fifteen to twenty. The loop below is amplification, not a
  # softer assertion, every one of these attempts must come back clean, and
  # the first one that does not fails the test immediately.
  #
  # .zshenv is deliberately not seeded here: zsh sources it unconditionally
  # on every invocation, including a plain `zsh -c '<command>'`, which is
  # not something any command-argument-based fix can suppress, and, by zsh's
  # own convention, .zshenv is meant to hold variable exports only, never
  # the state-writing setup (history files, completion caches, plugin
  # managers) that actually lives in the interactive/login files below.
  setup_canopy_home
  for rc in .zshrc .zprofile .zlogin .bashrc .bash_profile .profile; do
    printf '#!/bin/sh\ntouch "$HOME/rc-ran-%s"\n' "$rc" >"$HOME/$rc"
  done

  attempt=0
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    conf="$BATS_TEST_TMPDIR/pollution-check-$attempt.conf"
    printf 'set -g @canopy_pollution_marker ok\n' >"$conf"

    before="$(find "$HOME" | sort)"
    run canopy_tmux_validate "$conf"
    after="$(find "$HOME" | sort)"

    [ "$status" -eq 0 ]
    [ "$before" = "$after" ]
  done
}

@test "canopy_tmux_validate succeeds when tmux is reached through a wrapper that needs the bare environment to work" {
  # Stands in for a version-manager shim (mise, asdf, ...): a thin wrapper
  # on PATH that resolves and execs the real tmux, and refuses to run at
  # all unless HOME is set, the one variable a shim needs to find its own
  # install data that canopy_tmux_bare's env -i is specifically supposed
  # to preserve. If canopy_tmux_bare ever regressed to a bare env -i with
  # no variables carried through, this wrapper would fail and so would
  # this test.
  real_tmux="$(command -v tmux)"
  wrapper_dir="$BATS_TEST_TMPDIR/wrapper-bin"
  mkdir -p "$wrapper_dir"
  cat > "$wrapper_dir/tmux" <<EOF
#!/bin/sh
[ -n "\$HOME" ] || { echo "wrapper: HOME not set, cannot resolve the real tmux" >&2; exit 1; }
exec "$real_tmux" "\$@"
EOF
  chmod +x "$wrapper_dir/tmux"
  PATH="$wrapper_dir:/usr/bin:/bin"

  conf="$BATS_TEST_TMPDIR/wrapper-ok.conf"
  printf 'set -g @canopy_wrapper_marker ok\n' > "$conf"
  run canopy_tmux_validate "$conf"
  [ "$status" -eq 0 ]
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

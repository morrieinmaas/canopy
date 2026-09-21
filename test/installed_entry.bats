#!/usr/bin/env bats
# The tests that would have caught the headline bug: install into a scratch
# HOME, then load the installed entry point the way a user's tmux loads it,
# from an environment with no CANOPY_* in it at all. Every other test file
# exports those variables before invoking anything, which is why a config
# that loaded nothing on a real machine passed all of them.
load helper

setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
  sock="canopy-bare-$BATS_SUITE_TEST_NUMBER-$$"
}

teardown() {
  bare_tmux_cleanup "$sock"
}

@test "the installed entry point loads canopy's config with no CANOPY_* set" {
  run canopy install
  [ "$status" -eq 0 ]
  entry="$XDG_CONFIG_HOME/tmux/tmux.conf"

  bare_tmux -L "$sock" -f "$entry" new-session -d
  run bare_tmux -L "$sock" show -gv @canopy_test_marker
  [ "$status" -eq 0 ]
  [ "$output" = "shipped-default" ]
}

@test "the installed entry point sources user.conf last, with no CANOPY_* set" {
  run canopy install
  [ "$status" -eq 0 ]
  printf 'set -g @canopy_test_marker user-wins\n' >>"$CANOPY_CONFIG/user.conf"

  bare_tmux -L "$sock" -f "$XDG_CONFIG_HOME/tmux/tmux.conf" new-session -d
  run bare_tmux -L "$sock" show -gv @canopy_test_marker
  [ "$output" = "user-wins" ]
}

@test "the caps layer in CANOPY_STATE is loaded with no CANOPY_* set" {
  run canopy install
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_STATE/05-caps.conf" ]

  bare_tmux -L "$sock" -f "$XDG_CONFIG_HOME/tmux/tmux.conf" new-session -d
  run bare_tmux -L "$sock" show -gv @canopy_tmux_version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "sourcing the installed entry point from a bare environment succeeds" {
  run canopy install
  [ "$status" -eq 0 ]

  bare_tmux -L "$sock" -f /dev/null new-session -d
  run bare_tmux -L "$sock" source-file "$XDG_CONFIG_HOME/tmux/tmux.conf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the installed entry point publishes CANOPY_* into the server environment" {
  # What run-shell, display-popup and the M3 agent hooks inherit. Nothing
  # else ever sets these for a tmux server.
  run canopy install
  [ "$status" -eq 0 ]

  bare_tmux -L "$sock" -f "$XDG_CONFIG_HOME/tmux/tmux.conf" new-session -d
  run bare_tmux -L "$sock" show-environment -g CANOPY_STORE
  [ "$output" = "CANOPY_STORE=$CANOPY_STORE" ]
  run bare_tmux -L "$sock" show-environment -g CANOPY_STATE
  [ "$output" = "CANOPY_STATE=$CANOPY_STATE" ]
  run bare_tmux -L "$sock" show-environment -g CANOPY_CONFIG
  [ "$output" = "CANOPY_CONFIG=$CANOPY_CONFIG" ]
}

@test "the installed entry point references no variable, only absolute paths" {
  run canopy install
  [ "$status" -eq 0 ]
  entry="$XDG_CONFIG_HOME/tmux/tmux.conf"
  ! grep -q '[$]CANOPY_' "$entry"
  grep -q "source-file \"$CANOPY_STORE/tmux/tmux.conf\"" "$entry"
}

@test "doctor exits 2 when the installed entry point does not load" {
  run canopy install
  [ "$status" -eq 0 ]
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]

  # The stub canopy used to install: a variable reference tmux expands from
  # the server's own environment, where nothing sets it. doctor reported OK
  # on exactly this file.
  cat >"$XDG_CONFIG_HOME/tmux/tmux.conf" <<'EOF'
# canopy:entry-point: managed by canopy, do not edit directly.
source-file "$CANOPY_STORE/tmux/tmux.conf"
EOF

  run canopy-doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "doctor warns rather than reporting OK when canopy is not installed" {
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
  [[ "$output" != *"canopy doctor: OK"* ]]
}

@test "install fails and rolls back when the entry point it wrote cannot load" {
  # The store the stub's absolute literal points at is broken, so the only
  # way to catch it is to load the entry point itself.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf 'totally-not-a-real-tmux-command\n' >"$store_copy/tmux/conf.d/99-broken.conf"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy install
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_CONFIG_HOME/tmux/tmux.conf" ]
}

@test "canopy_tmux_validate leaves no socket file behind" {
  sock_dir="/tmp/tmux-$(id -u)"
  before="$(find "$sock_dir" -name 'canopy-verify-*' 2>/dev/null | wc -l)"
  run canopy_tmux_validate "$CANOPY_STORE/tmux/conf.d/00-core.conf"
  [ "$status" -eq 0 ]
  after="$(find "$sock_dir" -name 'canopy-verify-*' 2>/dev/null | wc -l)"
  [ "$before" -eq "$after" ]
}

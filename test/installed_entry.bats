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
  # The scratch server's socket, and everything else it writes, lives in a
  # canopy-tmux.* directory of its own under $CANOPY_SCRATCH_TMPDIR, removed
  # afterwards. The suite names that root inside its own tree, so looking
  # under /tmp here would watch a directory nothing writes to and pass on
  # an empty set either way.
  scratch_root="${CANOPY_SCRATCH_TMPDIR:-/tmp}"
  before="$(find "$scratch_root" -maxdepth 1 -name 'canopy-tmux.*' 2>/dev/null | sort)"
  run canopy_tmux_validate "$CANOPY_STORE/tmux/conf.d/00-core.conf"
  [ "$status" -eq 0 ]
  after="$(find "$scratch_root" -maxdepth 1 -name 'canopy-tmux.*' 2>/dev/null | sort)"
  [ "$before" = "$after" ]
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


setup_canopy_env() {
  CANOPY_STORE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CANOPY_CONFIG="$BATS_TEST_TMPDIR/config"
  CANOPY_STATE="$BATS_TEST_TMPDIR/state"
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/run"
  export CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
  mkdir -p "$CANOPY_CONFIG" "$CANOPY_STATE"
  # 0700, the mode canopy_runtime_ensure creates this directory with and
  # the only mode it will accept. A bare mkdir here would take the mode
  # from the harness's umask, so a machine running with a group-writable
  # umask would see canopy refuse its own test fixture.
  (umask 077 && mkdir -p "$CANOPY_RUNTIME")
  PATH="$CANOPY_STORE/bin:$PATH"; export PATH
}

# setup_canopy_home
# A scratch $HOME and $XDG_CONFIG_HOME under BATS_TEST_TMPDIR. Never the
# real $HOME: install, restore and doctor all write to, or read, whatever
# $HOME says.
setup_canopy_home() {
  HOME="$BATS_TEST_TMPDIR/home"
  XDG_CONFIG_HOME="$HOME/.config"
  export HOME XDG_CONFIG_HOME
  mkdir -p "$HOME"
}

# hold_off_boot_restore <socket-name>
# Disarms continuum's boot-time auto restore on a scratch server, and must
# be called before canopy's plugin layer is sourced into it.
#
# 30-plugins.conf sets @continuum-restore on, which is what makes a real
# machine come back after a reboot. A test server is not a machine that
# just booted: it already holds the panes the test built, and a restore
# firing a second later would replace them with whatever the last save
# holds. On a server with a single pane resurrect does that by killing the
# pane it found, so the agent under test would be gone mid-assertion.
#
# continuum arms the restore only when the server started within
# @continuum-restore-max-delay seconds, so zero disarms it, and it has to
# be set first because continuum reads it as it loads. The restore path
# itself is proven by the reboot scenario in test/smoke, on a server that
# really did just start.
hold_off_boot_restore() {
  tmux -L "$1" set -g @continuum-restore-max-delay 0
}

# bare_tmux [arg...]
# tmux with no CANOPY_* in its environment, the same way lib/tmux.sh runs
# it and the same way a user's tmux runs. A test that exports those and then
# checks the installed config is checking the harness, which is precisely
# how an entry point that loaded nothing passed 93 tests.
#
# Exactly those four are removed and nothing else, matching
# canopy_tmux_bare. `env -i` used to empty the environment outright, which
# breaks a tmux reached through a version-manager shim: the shim needs its
# own environment to find what it forwards to.
bare_tmux() {
  local bin
  bin="$(command -v tmux)"
  (
    unset CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
    export TMUX_TMPDIR=/tmp
    exec "$bin" "$@"
  )
}

# bare_tmux_cleanup <socket-name>
# Stops a scratch bare_tmux server and removes the socket file kill-server
# leaves behind. The path is known because bare_tmux names TMUX_TMPDIR.
bare_tmux_cleanup() {
  bare_tmux -L "$1" kill-server >/dev/null 2>&1 || true
  rm -f "/tmp/tmux-$(id -u)/$1"
}

# kill_tmux_server <socket-name>
# Same, for a scratch server started with this harness's own environment:
# tmux is asked where its socket is before the server that knows goes away.
# kill-server stops the server and leaves the socket file; roughly 900 of
# those accumulated under /tmp/tmux-<uid>/ before anyone noticed.
kill_tmux_server() {
  local path
  path="$(tmux -L "$1" display-message -p '#{socket_path}' 2>/dev/null || true)"
  tmux -L "$1" kill-server >/dev/null 2>&1 || true
  [ -n "$path" ] && rm -f "$path"
  return 0
}

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

# bare_tmux [arg...]
# tmux with nothing of this harness in its environment, the same way
# lib/tmux.sh runs it and the same way a user's tmux runs: no CANOPY_*
# anywhere. A test that exports those and then checks the installed config
# is checking the harness, which is precisely how an entry point that
# loaded nothing passed 93 tests.
bare_tmux() {
  local bin
  bin="$(command -v tmux)"
  env -i HOME="$HOME" PATH="${bin%/*}:/usr/bin:/bin" TMUX_TMPDIR=/tmp "$bin" "$@"
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

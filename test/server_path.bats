#!/usr/bin/env bats
load helper

# What a server job means by bare `tmux`.
#
# Every plugin is a shell script calling bare `tmux` dozens to hundreds of
# times as it loads, and what that resolves to comes from the tmux SERVER's
# PATH: a snapshot of whichever shell started the server, never refreshed.
# A version-manager shim sitting ahead of the real binary on that snapshot
# costs the manager's whole startup per call, which is how a `prefix r`
# reload measured 32 seconds instead of 2.7, and a second installation at a
# different version makes those scripts speak a different client version to
# the server than the server is running.
#
# The properties worth protecting, in the order they bite:
#
#   1. The shadow points at the binary this server is running, and is a
#      symlink to it rather than a copy, so an upgrade under it is visible.
#   2. When a shim sits in front, the server's own binary goes first.
#   3. Running it again does not stack a second copy on PATH. 00-core runs
#      this on every config load, so a non-idempotent version would grow the
#      server's PATH without bound across a session, which is the same class
#      of bug as the appending-layer guard in 00-core itself.
setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  canopy_paths
  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

# A scratch server plus the $TMUX value that makes bare `tmux` reach it,
# which is what the script under test uses: it takes no socket argument
# precisely because it runs from inside the server it corrects.
start_scratch_server() {
  sock="canopy-serverpath-$$-${BATS_TEST_NUMBER}"
  tmux -L "$sock" new-session -d -s t
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
}

server_path_option() {
  env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp \
    tmux -L "$sock" show-environment -g PATH 2>/dev/null || true
}

@test "bare tmux in a job becomes a symlink to the server's own binary" {
  start_scratch_server

  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp canopy-server-path
  [ "$status" -eq 0 ]

  # A symlink, never a copy: a tmux upgraded underneath this must be what
  # the next job gets, and a copy would pin the old bytes until something
  # thought to refresh them.
  [ -L "$CANOPY_RUNTIME/bin/tmux" ]
  target="$(readlink "$CANOPY_RUNTIME/bin/tmux")"
  [ -x "$target" ]

  # It is this server's binary, which is the whole claim: ask the thing the
  # symlink points at which server it reaches, and get this one back.
  expected="$(env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp \
    tmux -L "$sock" display-message -p '#{pid}')"
  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp \
    "$CANOPY_RUNTIME/bin/tmux" -L "$sock" display-message -p '#{pid}'
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "a shim ahead of the real tmux is overtaken by the server's own binary" {
  start_scratch_server

  # Stand in for a version-manager shim: a wrapper that does reach the real
  # tmux, so the script can still talk to the server through it, but which
  # is a different path and so would be what every plugin call resolved.
  real_tmux="$(command -v tmux)"
  shim_dir="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexec %s "$@"\n' "$real_tmux" >"$shim_dir/tmux"
  chmod +x "$shim_dir/tmux"

  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp PATH="$shim_dir:$PATH" \
    canopy-server-path
  [ "$status" -eq 0 ]

  # The shadow is a symlink to a real executable, not a copy and not the shim.
  [ -L "$CANOPY_RUNTIME/bin/tmux" ]
  target="$(readlink "$CANOPY_RUNTIME/bin/tmux")"
  [ "$target" != "$shim_dir/tmux" ]
  [ -x "$target" ]

  # And the server's PATH now starts with it, so a job resolves it first.
  run server_path_option
  [[ "$output" == "PATH=$CANOPY_RUNTIME/bin:"* ]]
}

@test "running it again does not stack a second copy on the server PATH" {
  start_scratch_server

  real_tmux="$(command -v tmux)"
  shim_dir="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexec %s "$@"\n' "$real_tmux" >"$shim_dir/tmux"
  chmod +x "$shim_dir/tmux"

  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp PATH="$shim_dir:$PATH" \
    canopy-server-path
  [ "$status" -eq 0 ]

  # Second pass with the PATH a job would now inherit, which is the real
  # shape of a reload: the correction is already in front.
  corrected="$(server_path_option)"
  corrected="${corrected#PATH=}"
  run env TMUX="$sock_path,0,0" TMUX_TMPDIR=/tmp PATH="$corrected" \
    canopy-server-path
  [ "$status" -eq 0 ]

  final="$(server_path_option)"
  occurrences="$(printf '%s' "$final" | grep -o "$CANOPY_RUNTIME/bin" | wc -l | tr -d ' ')"
  [ "$occurrences" -eq 1 ]
}

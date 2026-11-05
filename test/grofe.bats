#!/usr/bin/env bats
load helper

# canopy on grofe, the multiplexer that answers to the name `tmux`.
#
# Owner ruling 2026-11-05: on grofe, grofe's own persistence (snapshot,
# restore, resume, `grofe reboot-check`) replaces tmux-resurrect and
# tmux-continuum. So on grofe the plugin layer loads neither, generates no
# @resurrect-processes, and the two commands that judge persistence say
# what grofe does instead of what continuum would have done.
#
# grofe under the tmux name reports `tmux -V` as tmux's compat level, so a
# version string cannot tell the two apart. What tells them apart is
# #{grofe_version}: grofe expands it under either identity, and real tmux
# expands any variable it does not know to the empty string.
#
# These tests need a grofe binary and skip without one, loudly: set
# CANOPY_TEST_GROFE to its path, or put `grofe` on PATH. The binary is
# reached through a `tmux` symlink in a scratch directory at the front of
# PATH, so every bare `tmux` canopy runs is grofe under tmux identity, the
# way it is on a machine that switched. grofe keeps its sockets and its
# state under XDG_RUNTIME_DIR and XDG_STATE_HOME, and both point into the
# test's own scratch tree, so no test touches a real grofe or a real tmux.

setup() {
  setup_canopy_env
  setup_canopy_home

  grofe_bin="${CANOPY_TEST_GROFE:-$(command -v grofe 2>/dev/null || true)}"
  if [ -z "$grofe_bin" ] || [ ! -x "$grofe_bin" ]; then
    skip "no grofe binary: set CANOPY_TEST_GROFE to one"
  fi

  grofe_path="$BATS_TEST_TMPDIR/grofe-path"
  mkdir -p "$grofe_path"
  ln -s "$grofe_bin" "$grofe_path/tmux"
  PATH="$grofe_path:$PATH"
  export PATH

  XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run-xdg"
  XDG_STATE_HOME="$BATS_TEST_TMPDIR/state-xdg"
  export XDG_RUNTIME_DIR XDG_STATE_HOME
  (umask 077 && mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME")

  # Inherited from a developer's own session, either would point a bare
  # `tmux` at a server this file did not start.
  unset TMUX TMUX_PANE GROFE GROFE_PANE

  sock="cnp-grofe-$$-${BATS_TEST_NUMBER}"
}

teardown() {
  [ -n "${sock:-}" ] && tmux -L "$sock" kill-server >/dev/null 2>&1
  return 0
}

# g_start
# A grofe server under tmux identity carrying canopy's whole entry point,
# loaded the way the installed stub loads it: the three roots put into the
# server's environment first, then the store's tmux.conf sourced. GROFE and
# TMUX are exported so a bare `tmux` reaches this server, as it does from
# inside one of its panes (grofe reads GROFE; TMUX is for tools).
g_start() {
  # A shell pane, not a command: grofe records a pane started with a
  # command as one to resume, which would make every verdict here wait on
  # grofe's first snapshot write. /bin/sh so no login shell writes into
  # the scratch home.
  SHELL=/bin/sh tmux -L "$sock" -f /dev/null new-session -d -s main
  tmux -L "$sock" set-environment -g CANOPY_STORE "$CANOPY_STORE"
  tmux -L "$sock" set-environment -g CANOPY_STATE "$CANOPY_STATE"
  tmux -L "$sock" set-environment -g CANOPY_CONFIG "$CANOPY_CONFIG"
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/tmux.conf"
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
  GROFE="$sock_path"
  TMUX="$sock_path,0,0"
  export GROFE TMUX
  [ "$(tmux display-message -p '#{socket_path}')" = "$sock_path" ]
}

@test "the tmux on PATH is grofe under tmux identity, which -V cannot tell" {
  run tmux -V
  [ "$status" -eq 0 ]
  [[ "$output" == "tmux "* ]]
  g_start
  run tmux display-message -p '#{grofe_version}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "on grofe the plugin layer records grofe as the persistence backend" {
  g_start
  run tmux show -gqv @canopy_persistence
  [ "$status" -eq 0 ]
  [ "$output" = "grofe" ]
}

@test "on grofe neither resurrect nor continuum is loaded" {
  g_start
  # Loaded, resurrect binds its save and restore scripts and continuum
  # records its save timestamp and prepends its autosave to status-right.
  run tmux list-keys
  [ "$status" -eq 0 ]
  [[ "$output" != *"tmux-resurrect/scripts"* ]]
  run tmux show -gqv status-right
  [[ "$output" != *"continuum restore at server start"* ]]
  run tmux show -gqv @continuum-save-last-timestamp
  [ -z "$output" ]
  run tmux show -gqv @continuum-restore
  [ -z "$output" ]
  run tmux show -gqv @resurrect-dir
  [ -z "$output" ]
}

@test "on grofe no @resurrect-processes is generated, even with an adapter installed" {
  mkdir -p "$CANOPY_CONFIG/adapters"
  cp -R "$BATS_TEST_DIRNAME/fixtures/fake-agent-adapter" "$CANOPY_CONFIG/adapters/fake-agent"
  g_start
  run tmux show -gqv @resurrect-processes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reboot-check on grofe hands the verdict to grofe reboot-check" {
  g_start
  run canopy-reboot-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"grofe-native"* ]]
  # grofe's own line for the pane: target, uid, verdict.
  [[ "$output" == *"main:"* ]]
  [[ "$output" == *"restores as a shell"* ]]
  # And none of the resurrect path's own report.
  [[ "$output" != *"continuum restore at server start"* ]]
  [[ "$output" != *"Agent panes:"* ]]
}

@test "reboot-check on grofe passes through grofe's exit 1" {
  g_start
  pane="$(tmux list-panes -a -F '#{pane_id}' | head -1)"
  "$grofe_bin" -S "$sock_path" pane-set-resume -t "$pane" --expect "no session id reported"
  run canopy-reboot-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"will restart without its conversation (no session id reported)"* ]]
}

@test "reboot-check on grofe passes through grofe's exit 2" {
  g_start
  tmux set -g restore-on-start off
  run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"restore-on-start is off"* ]]
}

@test "reboot-check on grofe says so when no grofe binary can be found to ask" {
  g_start
  # CANOPY_GROFE, when set, is the only candidate, so naming a binary that
  # is not there leaves nothing to run the check with even though the
  # server's own executable is grofe.
  CANOPY_GROFE=/nonexistent/grofe run canopy-reboot-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"no grofe binary"* ]]
}

@test "doctor on grofe reports grofe-native persistence and asks nothing of continuum" {
  run canopy install
  [ "$status" -eq 0 ]
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  g_start
  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"persistence: grofe-native"* ]]
  [[ "$output" != *"@continuum-restore is on"* ]]
  [[ "$output" != *"continuum autosave hook in status-right"* ]]
}

@test "a throwaway validation server on grofe leaves nothing in grofe's runtime or state dirs" {
  # grofe keeps a .lock beside each socket and an instance directory and a
  # log under its state dir, and keeps the socket on kill-server as tmux
  # does. canopy's scratch servers are pointed into a directory of their
  # own, so the user's grofe dirs (here, the test's) see none of it.
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
  before="$(find /tmp -maxdepth 1 -name 'canopy-tmux.*' 2>/dev/null | sort)"
  run canopy_tmux_validate "$CANOPY_STORE/tmux/conf.d/00-core.conf"
  [ "$status" -eq 0 ]
  run canopy_tmux_loaded_option "$CANOPY_STORE/tmux/conf.d/30-plugins.conf" @canopy_persistence
  [ "$status" -eq 0 ]
  [ "$output" = "grofe" ]
  # canopy's own runtime directory lives under XDG_RUNTIME_DIR too, and is
  # not grofe's, so it is the one entry allowed there.
  run find "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" -mindepth 1 -not -path "$CANOPY_RUNTIME" -not -path "$CANOPY_RUNTIME/*"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  after="$(find /tmp -maxdepth 1 -name 'canopy-tmux.*' 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}

@test "config on grofe reads the unset resurrect and continuum rows as unused, not as changed" {
  g_start
  run canopy config
  [ "$status" -eq 0 ]
  [[ "$output" == *"@continuum-restore"*"(not used on grofe)"* ]]
  [[ "$output" == *"@resurrect-dir"*"(not used on grofe)"* ]]
  [[ "$output" != *"* @continuum-restore"* ]]
  [[ "$output" != *"* @resurrect-"* ]]
  [[ "$output" == *"@canopy_persistence"*"grofe"* ]]
}

@test "on grofe the save-now and restore-now keys run nothing of resurrect's" {
  g_start
  # Each row's command, run on this server exactly as the key would run it.
  # On real tmux it runs resurrect's script; on grofe there is no
  # resurrect to save into or restore from, and a restore from a stale
  # save would replace what is open.
  for name in save-now restore-now; do
    awk -F'\t' -v n="$name" '$1 == n { print $4 }' "$CANOPY_STORE/tmux/keys.tsv" \
      >"$BATS_TEST_TMPDIR/$name.conf"
    [ -s "$BATS_TEST_TMPDIR/$name.conf" ]
    run tmux source-file "$BATS_TEST_TMPDIR/$name.conf"
    [ "$status" -eq 0 ]
  done
  sleep 1
  [ ! -e "$CANOPY_STATE/resurrect" ]
  [ ! -e "$HOME/.local/share/tmux/resurrect" ]
  [ ! -e "$HOME/.tmux/resurrect" ]
}

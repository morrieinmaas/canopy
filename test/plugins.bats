#!/usr/bin/env bats
load helper

# The vendored plugin trees and the layer that loads them.
#
# Every test here that starts tmux does so on its own named socket and gets
# a scratch $HOME, both non-negotiable. continuum's very first act on load
# is handle_tmux_automatic_start.sh, which on a machine where
# @continuum-boot is off (the default) runs osx_disable.sh, and that script
# is an unconditional `rm "$HOME/Library/LaunchAgents/Tmux.Start.plist"`.
# A test here that inherited the real $HOME would delete a real file of the
# user's on every run.
setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/plugins.sh"
  canopy_paths
  sock=""
}

# Cleanup lives in teardown, not at the end of each test: bats aborts a
# test at its first failing command, so a kill placed after the assertion
# never runs on the day it matters and the socket leaks. Roughly 900 of
# them accumulated in this project that way.
teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

plugins_dir() { printf '%s' "$CANOPY_STORE/plugins"; }

@test "VERSIONS pins both plugins to an upstream url and a full commit sha" {
  [ -f "$(plugins_dir)/VERSIONS" ]
  for name in tmux-resurrect tmux-continuum; do
    line="$(awk -v n="$name" '$1 == n { print; exit }' "$(plugins_dir)/VERSIONS")"
    [ -n "$line" ]
    url="$(printf '%s' "$line" | awk '{ print $2 }')"
    commit="$(printf '%s' "$line" | awk '{ print $3 }')"
    [[ "$url" == *"tmux-plugins/$name"* ]]
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
  done
}

@test "each vendored plugin is a real directory, not a symlink" {
  for name in tmux-resurrect tmux-continuum; do
    [ -d "$(plugins_dir)/$name" ]
    [ ! -L "$(plugins_dir)/$name" ]
  done
}

@test "no vendored plugin is a git submodule" {
  # Three ways a plugin could be a submodule rather than a vendored copy,
  # all of them excluded: a .gitmodules at the repo root, a .git inside the
  # tree, and a gitlink (mode 160000) in canopy's own index.
  [ ! -e "$CANOPY_STORE/.gitmodules" ]
  for name in tmux-resurrect tmux-continuum; do
    [ ! -e "$(plugins_dir)/$name/.git" ]
  done
  run git -C "$CANOPY_STORE" ls-files -s plugins
  [ "$status" -eq 0 ]
  [[ "$output" != *"160000"* ]]
}

@test "a vendored tree holds nothing a git checkout cannot reproduce" {
  # The invariant CHECKSUMS depends on: what vendor.sh writes is what a
  # clone gets back. git stores neither an empty directory nor a dangling
  # symlink's missing target, and a nested .gitignore makes git drop files
  # from canopy's own copy of the tree, so any of the three would make
  # every fresh clone report as modified.
  for name in tmux-resurrect tmux-continuum; do
    dir="$(plugins_dir)/$name"
    dangling="$(find "$dir" -type l | while IFS= read -r link; do
      [ -e "$link" ] || printf '%s\n' "$link"
    done)"
    [ -z "$dangling" ]
    [ -z "$(find "$dir" -type d -empty)" ]
    [ -z "$(find "$dir" \( -name .gitignore -o -name .gitmodules \) -print)" ]
  done
}

@test "each plugin's entry point is present and executable" {
  [ -x "$(plugins_dir)/tmux-resurrect/resurrect.tmux" ]
  [ -x "$(plugins_dir)/tmux-continuum/continuum.tmux" ]
}

@test "30-plugins.conf defines resurrect's save and restore key bindings" {
  sock="cnp-plg-a-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  run tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  [ "$status" -eq 0 ]
  run tmux -L "$sock" list-keys -T prefix
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux-resurrect/scripts/save.sh"* ]]
  [[ "$output" == *"tmux-resurrect/scripts/restore.sh"* ]]
}

@test "30-plugins.conf loads continuum, which acts on the status line" {
  # Asserted through continuum's #{continuum_status} substitution rather
  # than through its autosave hook, because the autosave hook is not
  # deterministic: continuum adds it only when no other tmux server is
  # running, so a developer with their own tmux open would watch this test
  # fail for a reason that has nothing to do with the change under test.
  # The substitution runs unconditionally whenever continuum loads at all.
  sock="cnp-plg-b-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" set -g status-right 'left#{continuum_status}right'
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  run tmux -L "$sock" show -gv status-right
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux-continuum/scripts/continuum_status.sh"* ]]
}

@test "the plugin paths come from the store, not from a plugin manager" {
  # The binding resurrect installs must name this checkout's own tree. A
  # path under ~/.tmux/plugins or ~/.local/share/tmux/plugins would mean
  # something fetched the plugin at runtime instead.
  sock="cnp-plg-c-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  run tmux -L "$sock" show -gv @resurrect-save-script-path
  [ "$status" -eq 0 ]
  [ "$output" = "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh" ]
}

@test "the layer is reached through the store's own tmux.conf" {
  # 30-plugins.conf matches the loader's conf.d/[1-9]*.conf glob, so a user
  # who loads the shipped entry point gets the plugins without naming them.
  sock="cnp-plg-d-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @resurrect-save-script-path
  [ "$status" -eq 0 ]
  [[ "$output" == *"/plugins/tmux-resurrect/scripts/save.sh"* ]]
}

@test "resurrect saves into canopy's own state tree, not upstream's default" {
  # The saves are the data persistence depends on. Left at upstream's
  # default (~/.local/share/tmux/resurrect) they sit outside the tree
  # restore and uninstall reason about, so canopy could neither promise to
  # put a machine back nor say where the saves went.
  sock="cnp-plg-e-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  run tmux -L "$sock" show -gv @resurrect-dir
  [ "$status" -eq 0 ]
  [ "$output" = "$CANOPY_STATE/resurrect" ]
}

@test "the resurrect directory is expanded by tmux, not left as a literal" {
  # tmux expands $CANOPY_STATE from the SERVER's environment, which the
  # installed entry point populates. A value that reached resurrect still
  # holding the dollar sign would have it create a directory literally
  # named $CANOPY_STATE in whatever the cwd happened to be.
  sock="cnp-plg-f-$$"
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  run tmux -L "$sock" show -gv @resurrect-dir
  [ "$status" -eq 0 ]
  [[ "$output" != *'$'* ]]
  [[ "$output" == /* ]]
}

@test "canopy_plugin_digest is stable and changes when a file changes" {
  copy="$BATS_TEST_TMPDIR/tree"
  cp -R "$(plugins_dir)/tmux-continuum" "$copy"
  first="$(canopy_plugin_digest "$copy")"
  [ -n "$first" ]
  [ "$first" = "$(canopy_plugin_digest "$copy")" ]
  printf '\n# local edit\n' >>"$copy/continuum.tmux"
  [ "$first" != "$(canopy_plugin_digest "$copy")" ]
}

@test "CHECKSUMS records the digest of each vendored tree as shipped" {
  [ -f "$(plugins_dir)/CHECKSUMS" ]
  for name in tmux-resurrect tmux-continuum; do
    recorded="$(awk -v n="$name" '$1 == n { print $2; exit }' "$(plugins_dir)/CHECKSUMS")"
    [ -n "$recorded" ]
    [ "$recorded" = "$(canopy_plugin_digest "$(plugins_dir)/$name")" ]
  done
}

@test "vendor.sh is executable and rejects a plugin that is not pinned" {
  [ -x "$(plugins_dir)/vendor.sh" ]
  run "$(plugins_dir)/vendor.sh" not-a-plugin
  [ "$status" -ne 0 ]
  [[ "$output" == *"not-a-plugin"* ]]
}

@test "vendor.sh requires exactly one plugin name" {
  run "$(plugins_dir)/vendor.sh"
  [ "$status" -ne 0 ]
  run "$(plugins_dir)/vendor.sh" tmux-resurrect tmux-continuum
  [ "$status" -ne 0 ]
}

@test "doctor reports each plugin's pinned commit and that the tree matches" {
  run canopy-doctor
  [[ "$output" == *"Plugins:"* ]]
  for name in tmux-resurrect tmux-continuum; do
    commit="$(awk -v n="$name" '$1 == n { print $3; exit }' "$(plugins_dir)/VERSIONS")"
    [[ "$output" == *"$name"*"$commit"* ]]
  done
  [[ "$output" != *"MODIFIED"* ]]
}

@test "doctor flags a modified vendored tree" {
  # The real store is read-only by convention, so the tree doctor is asked
  # about is a copy, the same way doctor.bats plants a broken conf fragment.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  cp -R "$CANOPY_STORE/plugins" "$store_copy/plugins"
  printf '\n# local edit\n' >>"$store_copy/plugins/tmux-resurrect/resurrect.tmux"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-doctor
  [[ "$output" == *"tmux-resurrect"*"MODIFIED"* ]]
  [ "$status" -ne 0 ]
}

@test "doctor flags a vendored tree that is missing entirely" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  cp -R "$CANOPY_STORE/plugins" "$store_copy/plugins"
  rm -rf "$store_copy/plugins/tmux-continuum"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-doctor
  [[ "$output" == *"tmux-continuum"*"MISSING"* ]]
  [ "$status" -ne 0 ]
}

@test "autosave runs every five minutes, not at continuum's fifteen" {
  # continuum's own default is 15. Five is canopy's, because the window a
  # save interval leaves open is the window in which a reboot loses a
  # conversation, and reboot-check can only report what the last save
  # holds: at fifteen minutes a pane opened twelve minutes ago is
  # truthfully reported as "not saved yet", which is correct and useless.
  sock="cnp-plg-int-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  run tmux -L "$sock" show -gv @continuum-save-interval
  kill_tmux_server "$sock"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "an nvim pane is saved as a session rather than as a bare editor" {
  # resurrect can ask nvim to write its own session file and restore it,
  # which is the difference between a pane that comes back in the editor
  # and a pane that comes back in the editor with the buffers, splits and
  # cursor positions it had. The same claim this milestone makes for an
  # agent pane, for the other program a pane is most likely to be holding.
  sock="cnp-plg-nvim-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  run tmux -L "$sock" show -gv @resurrect-strategy-nvim
  kill_tmux_server "$sock"
  [ "$status" -eq 0 ]
  [ "$output" = "session" ]
}

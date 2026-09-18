#!/usr/bin/env bats
load helper
setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/manifest.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
  target="$BATS_TEST_TMPDIR/target.conf"
  # Safety: restore's post-restore tmux validation resolves against
  # HOME/XDG_CONFIG_HOME — every test gets its own fake ones under
  # BATS_TEST_TMPDIR, never the real $HOME.
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  HOME="$home"
  XDG_CONFIG_HOME="$home/.config"
  export HOME XDG_CONFIG_HOME
}

@test "restore --all returns a pre-existing file to its exact original bytes" {
  printf 'original\n' > "$target"; orig="$(canopy_sha256 "$target")"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$target"
  printf 'canopy-owned\n' > "$target"
  canopy_tx_commit "$tx"
  run canopy restore --all
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$target")" = "$orig" ]
}

@test "restore refuses a file edited after install, and says which" {
  printf 'original\n' > "$target"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$target"
  printf 'canopy-owned\n' > "$target"
  canopy_tx_commit "$tx"
  printf 'my later edit\n' > "$target"
  run canopy restore --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"target.conf"* ]]
  [ "$(cat "$target")" = "my later edit" ]
}

@test "--force reverts anyway but backs the current state up first" {
  printf 'original\n' > "$target"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$target"
  printf 'canopy-owned\n' > "$target"
  canopy_tx_commit "$tx"
  printf 'my later edit\n' > "$target"
  run canopy restore --all --force
  [ "$status" -eq 0 ]
  grep -rq 'my later edit' "$CANOPY_STATE"/backups/*/files/
}

@test "a dropped file is deleted only if unmodified" {
  # absent pre-state + matching post hash -> deleted
  # absent pre-state + changed content -> kept, reported
  dropped_ok="$BATS_TEST_TMPDIR/dropped-ok.conf"
  dropped_edited="$BATS_TEST_TMPDIR/dropped-edited.conf"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" drop "$dropped_ok"
  canopy_tx_record "$tx" drop "$dropped_edited"
  printf 'canopy-generated\n' > "$dropped_ok"
  printf 'canopy-generated\n' > "$dropped_edited"
  canopy_tx_commit "$tx"

  printf 'user changed this after install\n' > "$dropped_edited"

  run canopy restore --all
  [ "$status" -ne 0 ]
  [ ! -e "$dropped_ok" ]
  [ -f "$dropped_edited" ]
  [ "$(cat "$dropped_edited")" = "user changed this after install" ]
  [[ "$output" == *"dropped-edited.conf"* ]]
}

@test "restore never removes the user config dir" {
  echo x > "$CANOPY_CONFIG/user.conf"
  canopy restore --all
  [ -f "$CANOPY_CONFIG/user.conf" ]
}

@test "restore removes a directory canopy created, once it is empty" {
  entry_dir="$BATS_TEST_TMPDIR/xdg/tmux"
  entry="$entry_dir/tmux.conf"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" drop "$entry"
  mkdir -p "$entry_dir"
  printf 'canopy-generated\n' > "$entry"
  printf '%s\n' "$entry_dir" >> "$tx/dirs-created.txt"
  canopy_tx_commit "$tx"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ ! -e "$entry" ]
  [ ! -d "$entry_dir" ]
}

@test "restore declines to remove a directory that still holds other content" {
  entry_dir="$BATS_TEST_TMPDIR/xdg/tmux"
  entry="$entry_dir/tmux.conf"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" drop "$entry"
  mkdir -p "$entry_dir"
  printf 'canopy-generated\n' > "$entry"
  printf '%s\n' "$entry_dir" >> "$tx/dirs-created.txt"
  canopy_tx_commit "$tx"

  touch "$entry_dir/plugins.keep"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ ! -e "$entry" ]
  [ -d "$entry_dir" ]
  [ -f "$entry_dir/plugins.keep" ]
}

@test "restore fails and surfaces tmux's own error when the restored config is broken" {
  entry_dir="$XDG_CONFIG_HOME/tmux"
  entry="$entry_dir/tmux.conf"
  mkdir -p "$entry_dir"
  printf 'totally-not-a-real-tmux-command\n' > "$entry"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$entry"
  printf 'set -g @preexisting yes\n' > "$entry"
  canopy_tx_commit "$tx"

  run canopy restore --all
  [ "$status" -ne 0 ]
  [ "$(cat "$entry")" = "totally-not-a-real-tmux-command" ]
  [[ "$output" == *"totally-not-a-real-tmux-command"* ]]
}

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

@test "--to reverts the named transaction and every newer one, leaving older ones byte-identical" {
  a="$BATS_TEST_TMPDIR/a.conf"
  b="$BATS_TEST_TMPDIR/b.conf"
  c="$BATS_TEST_TMPDIR/c.conf"
  printf 'orig-a\n' > "$a"
  printf 'orig-b\n' > "$b"; orig_b="$(canopy_sha256 "$b")"
  printf 'orig-c\n' > "$c"; orig_c="$(canopy_sha256 "$c")"

  # Labels sort alphabetically after "install", so ordering stays correct
  # even if two of these land in the same wall-clock second (the id's
  # tie-break is lexicographic on the whole "<epoch>-<label>" string).
  tx1="$(canopy_tx_begin install)"; touch "$tx1/.pinned"
  canopy_tx_record "$tx1" own "$a"
  printf 'canopy-a\n' > "$a"
  canopy_tx_commit "$tx1"

  tx2="$(canopy_tx_begin step2)"
  canopy_tx_record "$tx2" own "$b"
  printf 'canopy-b\n' > "$b"
  canopy_tx_commit "$tx2"

  tx3="$(canopy_tx_begin step3)"
  canopy_tx_record "$tx3" own "$c"
  printf 'canopy-c\n' > "$c"
  canopy_tx_commit "$tx3"

  tx2_id="$(basename "$tx2")"
  run canopy restore --to "$tx2_id"
  [ "$status" -eq 0 ]
  # tx1 (older than the named id) is untouched: still canopy-owned bytes.
  [ "$(cat "$a")" = "canopy-a" ]
  # tx2 (the named id) is reverted.
  [ "$(canopy_sha256 "$b")" = "$orig_b" ]
  # tx3 (newer than the named id) is reverted too.
  [ "$(canopy_sha256 "$c")" = "$orig_c" ]
}

@test "--list shows newest first, marks the pinned install, and distinguishes a failed transaction from a committed one" {
  tx1="$(canopy_tx_begin install)"; touch "$tx1/.pinned"
  canopy_tx_record "$tx1" own "$target"
  canopy_tx_commit "$tx1"

  # "zfailed" sorts after "install" alphabetically, so this stays the
  # newest entry even if both land in the same wall-clock second.
  tx2="$(canopy_tx_begin zfailed)"
  canopy_tx_record "$tx2" own "$target"
  touch "$tx2/.failed"

  run canopy restore --list
  [ "$status" -eq 0 ]
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  second_line="$(printf '%s\n' "$output" | sed -n '2p')"
  [[ "$first_line" == *"zfailed"* ]]
  [[ "$first_line" == *"FAILED"* ]]
  [[ "$second_line" == *"install"* ]]
  [[ "$second_line" == *"PINNED"* ]]
  [[ "$second_line" != *"FAILED"* ]]
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

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
  # HOME/XDG_CONFIG_HOME; every test gets its own fake ones under
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

@test "two transactions touching one file replay newest first, landing on the pre-first bytes" {
  # Replay order is load-bearing and, with a single transaction, entirely
  # unobservable: every other test in this file uses exactly one. tx1 took
  # the file from original to v1, tx2 from v1 to v2. Replayed newest
  # first, tx2 puts v1 back and tx1 then puts the original back. Replayed
  # oldest first, tx1's hash guard sees v2 where it expects v1, keeps the
  # row, and the file is left holding canopy's bytes instead of the
  # user's.
  f="$BATS_TEST_TMPDIR/two-tx.conf"
  printf 'original\n' > "$f"; orig="$(canopy_sha256 "$f")"

  tx1="$(canopy_tx_begin install)"; touch "$tx1/.pinned"
  canopy_tx_record "$tx1" own "$f"
  printf 'canopy-v1\n' > "$f"
  canopy_tx_commit "$tx1"

  # "zlater" sorts after "install", so this stays the newer transaction
  # even when both land in the same wall-clock second.
  tx2="$(canopy_tx_begin zlater)"
  canopy_tx_record "$tx2" own "$f"
  printf 'canopy-v2\n' > "$f"
  canopy_tx_commit "$tx2"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 reverted, 0 kept"* ]]
  [ "$(canopy_sha256 "$f")" = "$orig" ]
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

@test "--list survives a transaction with an empty manifest, listing all three and marking it INCOMPLETE" {
  a="$BATS_TEST_TMPDIR/list-a.conf"
  c="$BATS_TEST_TMPDIR/list-c.conf"
  tx1="$(canopy_tx_begin install)"; touch "$tx1/.pinned"
  canopy_tx_record "$tx1" own "$a"
  canopy_tx_commit "$tx1"

  # Deliberately begun and left alone: never recorded into, never
  # committed, never marked failed. This is exactly the empty-manifest
  # shape (manifest.tsv holding only its header row) that an interrupted
  # transaction leaves behind, and the shape that used to make --list
  # exit 1 and print nothing at all.
  canopy_tx_begin interrupted >/dev/null

  tx3="$(canopy_tx_begin zlater)"
  canopy_tx_record "$tx3" own "$c"
  canopy_tx_commit "$tx3"

  run canopy restore --list
  [ "$status" -eq 0 ]
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 3 ]
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  second_line="$(printf '%s\n' "$output" | sed -n '2p')"
  third_line="$(printf '%s\n' "$output" | sed -n '3p')"
  [[ "$first_line" == *"zlater"* ]]
  [[ "$second_line" == *"interrupted"* ]]
  [[ "$second_line" == *"INCOMPLETE"* ]]
  [[ "$third_line" == *"install"* ]]
  [[ "$third_line" == *"PINNED"* ]]
}

# interrupt_install
# Reproduces exactly the on-disk state canopy-install leaves behind when
# it is killed between writing the entry point and reaching
# canopy_tx_commit: the transaction has recorded rows and a byte copy of
# the user's original config, but no .committed marker and no .pinned
# marker. Built directly rather than by racing a real install so the
# window is deterministic. Sets $entry, $orig_hash and $tx.
interrupt_install() {
  entry_dir="$XDG_CONFIG_HOME/tmux"
  entry="$entry_dir/tmux.conf"
  mkdir -p "$entry_dir"
  printf 'set -g @preexisting yes\n' > "$entry"
  orig_hash="$(canopy_sha256 "$entry")"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$entry"
  printf '# canopy:entry-point: managed by canopy, do not edit directly.\n' > "$entry"
}

@test "a bare restore reverts an install interrupted before it committed" {
  interrupt_install
  run canopy restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 reverted"* ]]
  [ "$(canopy_sha256 "$entry")" = "$orig_hash" ]
}

@test "restore --all reverts an install interrupted before it committed" {
  interrupt_install
  run canopy restore --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 reverted"* ]]
  [ "$(canopy_sha256 "$entry")" = "$orig_hash" ]
}

@test "restore --to accepts the id --list printed for an interrupted install, and reverts it" {
  interrupt_install
  tx_id="$(basename "$tx")"

  run canopy restore --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$tx_id"* ]]
  [[ "$output" == *"INCOMPLETE"* ]]

  run canopy restore --to "$tx_id"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no such transaction"* ]]
  [[ "$output" == *"1 reverted"* ]]
  [ "$(canopy_sha256 "$entry")" = "$orig_hash" ]
}

@test "a failed transaction stays out of automatic rollback, but --to can still name it" {
  a="$BATS_TEST_TMPDIR/failed-a.conf"
  printf 'orig-a\n' > "$a"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$a"
  printf 'canopy-a\n' > "$a"
  # install's own failure path: it reverted the file itself with
  # $tx/restore.sh, then marked the transaction failed.
  "$tx/restore.sh" >/dev/null
  touch "$tx/.failed"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 reverted, 0 kept"* ]]

  run canopy restore --to "$(basename "$tx")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 reverted"* ]]
  [ "$(cat "$a")" = "orig-a" ]
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

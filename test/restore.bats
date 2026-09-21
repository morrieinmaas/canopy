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

@test "restore never removes a user config dir that still holds something" {
  echo x > "$CANOPY_CONFIG/user.conf"
  canopy restore --all
  [ -f "$CANOPY_CONFIG/user.conf" ]
  [ -d "$CANOPY_CONFIG" ]
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

@test "reverting an uncommitted transaction announces every unguarded path and where the overwritten bytes went" {
  # The reported scenario, reproduced: an install interrupted before it
  # committed, then the user edits both files it had already touched.
  # Those rows carry an empty post column, so there is nothing to compare
  # the current bytes against and restore reverts them unguarded. The
  # revert is right, doing it without saying so is not: the user loses
  # two edits and is told only "2 reverted, 0 kept".
  entry_dir="$XDG_CONFIG_HOME/tmux"
  entry="$entry_dir/tmux.conf"
  user_conf="$CANOPY_CONFIG/user.conf"
  mkdir -p "$entry_dir"
  printf 'set -g @preexisting yes\n' > "$entry"
  printf '# canopy user config\n' > "$user_conf"

  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$entry"
  canopy_tx_record "$tx" own "$user_conf"
  printf '# canopy:entry-point: managed by canopy, do not edit directly.\n' > "$entry"
  printf '# canopy user config: sourced last.\n' > "$user_conf"
  # Interrupted here: no canopy_tx_commit, so no post hashes and no
  # .committed marker.

  printf 'set -g @mine yes\n' > "$entry"
  printf 'set -g @appended yes\n' >> "$user_conf"
  edited_entry="$(canopy_sha256 "$entry")"
  edited_user="$(canopy_sha256 "$user_conf")"

  run canopy restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 reverted, 0 kept"* ]]
  [[ "$output" == *"$entry"* ]]
  [[ "$output" == *"$user_conf"* ]]
  [[ "$output" == *"never committed"* ]]

  restore_id=""
  for d in "$CANOPY_STATE"/backups/*-restore; do restore_id="$(basename "$d")"; done
  [ -n "$restore_id" ]
  [[ "$output" == *"canopy restore --to $restore_id"* ]]

  # The recovery command it printed really does bring both edits back.
  run canopy restore --to "$restore_id"
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$entry")" = "$edited_entry" ]
  [ "$(canopy_sha256 "$user_conf")" = "$edited_user" ]
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

@test "restore warns, and still succeeds, when tmux dislikes the config it restored" {
  # The user's own config is back byte for byte, and tmux rejects a line in
  # it. That is a successful restore of an imperfect config, not a failed
  # restore: plugin-dependent and version-dependent configs routinely carry
  # lines a bare tmux rejects, and exiting 1 here reported a byte-perfect
  # restore as a failure, right below "0 reverted, 0 kept".
  entry_dir="$XDG_CONFIG_HOME/tmux"
  entry="$entry_dir/tmux.conf"
  mkdir -p "$entry_dir"
  printf 'totally-not-a-real-tmux-command\n' > "$entry"
  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$entry"
  printf 'set -g @preexisting yes\n' > "$entry"
  canopy_tx_commit "$tx"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ "$(cat "$entry")" = "totally-not-a-real-tmux-command" ]
  [[ "$output" == *"warning"* ]]
  [[ "$output" == *"totally-not-a-real-tmux-command"* ]]
}

@test "restore --all reverts a rollback set that mixes a committed and an uncommitted transaction" {
  # The only shape in this file where automatic rollback has to replay
  # both kinds of transaction in one run. An uncommitted transaction is
  # not a transaction to skip: it means canopy was interrupted partway
  # through, so its partial changes are sitting on disk and the user's
  # original bytes are sitting in its files/ directory.
  a="$BATS_TEST_TMPDIR/mixed-a.conf"
  b="$BATS_TEST_TMPDIR/mixed-b.conf"
  printf 'orig-a\n' > "$a"; orig_a="$(canopy_sha256 "$a")"
  printf 'orig-b\n' > "$b"; orig_b="$(canopy_sha256 "$b")"

  tx1="$(canopy_tx_begin install)"; touch "$tx1/.pinned"
  canopy_tx_record "$tx1" own "$a"
  printf 'canopy-a\n' > "$a"
  canopy_tx_commit "$tx1"

  # Begun and recorded, never committed. "zinterrupted" sorts after
  # "install", so this stays the newer transaction even when both land in
  # the same wall-clock second.
  tx2="$(canopy_tx_begin zinterrupted)"
  canopy_tx_record "$tx2" own "$b"
  printf 'canopy-b\n' > "$b"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 reverted, 0 kept"* ]]
  [ "$(canopy_sha256 "$a")" = "$orig_a" ]
  [ "$(canopy_sha256 "$b")" = "$orig_b" ]
}

@test "--to selects by position in the sorted list, not by string collation" {
  # --list and --to must agree on which transactions are newer than a
  # given one. --list renders the list the same sort built; --to used to
  # re-derive "newer" by comparing id strings in awk, which only agrees
  # with that sort while awk's collation matches the locale's.
  if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf-*8$'; then
    skip "en_US.UTF-8 is not available on this machine"
  fi
  a="$BATS_TEST_TMPDIR/coll-a.conf"
  b="$BATS_TEST_TMPDIR/coll-b.conf"
  printf 'orig-a\n' > "$a"; orig_a="$(canopy_sha256 "$a")"
  printf 'orig-b\n' > "$b"; orig_b="$(canopy_sha256 "$b")"

  # Labels whose byte order ("Bravo" before "alpha") is the reverse of
  # what a non-C locale collates ("alpha" before "Bravo"), in one epoch
  # second so the label alone decides the order. The epoch is normalised
  # by hand rather than raced: canopy_tx_begin stamps wall-clock seconds,
  # and a test that only usually lands both in the same second only
  # usually covers the collation it exists to cover. A transaction
  # directory holds no absolute reference to itself (manifest.tsv names
  # target paths, backups are relative to the directory), so renaming one
  # is safe.
  tx_a="$(canopy_tx_begin alpha)"
  mv "$tx_a" "$CANOPY_STATE/backups/1700000000-alpha"
  tx_a="$CANOPY_STATE/backups/1700000000-alpha"
  canopy_tx_record "$tx_a" own "$a"
  printf 'canopy-a\n' > "$a"
  canopy_tx_commit "$tx_a"

  tx_b="$(canopy_tx_begin Bravo)"
  mv "$tx_b" "$CANOPY_STATE/backups/1700000000-Bravo"
  tx_b="$CANOPY_STATE/backups/1700000000-Bravo"
  canopy_tx_record "$tx_b" own "$b"
  printf 'canopy-b\n' > "$b"
  canopy_tx_commit "$tx_b"

  run env LC_ALL=en_US.UTF-8 canopy restore --list
  [ "$status" -eq 0 ]
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  if [[ "$first_line" != *"Bravo"* ]]; then
    skip "this machine's en_US.UTF-8 collation does not reorder these ids"
  fi

  # --list just showed Bravo as the newest, so naming alpha must select
  # both, in this locale, whatever awk would have said about the strings.
  run env LC_ALL=en_US.UTF-8 canopy restore --to 1700000000-alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 reverted, 0 kept"* ]]
  [ "$(canopy_sha256 "$a")" = "$orig_a" ]
  [ "$(canopy_sha256 "$b")" = "$orig_b" ]
}

@test "restore --all three times in a row keeps the machine at its original bytes and exits clean each time" {
  # restore --all is the promise canopy is built on, and a promise that
  # only holds the first time is not one. The second run must not read
  # the first run's own work as an edit the user made.
  owned="$BATS_TEST_TMPDIR/idem-own.conf"
  dropped="$BATS_TEST_TMPDIR/idem-drop.conf"
  printf 'original\n' > "$owned"; orig="$(canopy_sha256 "$owned")"

  tx="$(canopy_tx_begin install)"; touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$owned"
  canopy_tx_record "$tx" drop "$dropped"
  printf 'canopy-owned\n' > "$owned"
  printf 'canopy-generated\n' > "$dropped"
  canopy_tx_commit "$tx"

  for run_no in 1 2 3; do
    run canopy restore --all
    printf 'run %s: status=%s output=%s\n' "$run_no" "$status" "$output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 kept"* ]]
    [[ "$output" != *"kept (changed since canopy wrote it)"* ]]
    [ "$(canopy_sha256 "$owned")" = "$orig" ]
    [ ! -e "$dropped" ]
  done
}

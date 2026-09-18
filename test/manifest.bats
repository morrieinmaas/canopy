#!/usr/bin/env bats
load helper
setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"; . "$CANOPY_STORE/lib/manifest.sh"
  canopy_paths
  target="$BATS_TEST_TMPDIR/target.conf"
}

@test "records an existing file with its pre-hash and a byte copy" {
  printf 'original\n' > "$target"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$target"
  printf 'replaced\n' > "$target"
  canopy_tx_commit "$tx"
  grep -q "own	$target	" "$tx/manifest.tsv"
  backup="$(awk -F'\t' -v p="$target" '$2==p {print $4}' "$tx/manifest.tsv")"
  [ "$(cat "$tx/$backup")" = "original" ]
}

@test "records an absent file as absent" {
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" drop "$BATS_TEST_TMPDIR/new.conf"
  printf 'new\n' > "$BATS_TEST_TMPDIR/new.conf"
  canopy_tx_commit "$tx"
  [ "$(awk -F'\t' '{print $3}' "$tx/manifest.tsv" | tail -1)" = "absent" ]
}

@test "restore.sh actually restores when run standalone, canopy store gone" {
  printf 'original\n' > "$target"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$target"
  printf 'changed\n' > "$target"
  canopy_tx_commit "$tx"

  orphan="$BATS_TEST_TMPDIR/orphan-tx"
  cp -R "$tx" "$orphan"

  (
    unset CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
    CANOPY_STORE="$BATS_TEST_TMPDIR/no-such-store"
    export CANOPY_STORE
    "$orphan/restore.sh"
  )
  [ "$(cat "$target")" = "original" ]
}

@test "mangling does not collide a literal % with a path separator" {
  a="$BATS_TEST_TMPDIR/etc/foo/bar"
  b="$BATS_TEST_TMPDIR/etc/foo%bar"
  mkdir -p "$BATS_TEST_TMPDIR/etc/foo"
  printf 'from-a\n' > "$a"
  printf 'from-b\n' > "$b"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$a"
  canopy_tx_record "$tx" own "$b"
  backup_a="$(awk -F'\t' -v p="$a" '$2==p {print $4}' "$tx/manifest.tsv")"
  backup_b="$(awk -F'\t' -v p="$b" '$2==p {print $4}' "$tx/manifest.tsv")"
  [ "$backup_a" != "$backup_b" ]
  [ "$(cat "$tx/$backup_a")" = "from-a" ]
  [ "$(cat "$tx/$backup_b")" = "from-b" ]
}

@test "mangling does not collide a path containing /% with one containing %/" {
  # /a/% vs /a%/ both mangle to the same name under escape-%-then-map-/
  # (round 2): each has one literal "/" and one literal "%", merely in
  # opposite order, and that ordering info is lost once "/" is folded
  # into the same "%" used to escape "%". A trailing "/" can't itself
  # name a regular file, so both examples get a common leaf appended
  # ("x") to stay filesystem-realizable while preserving the collision.
  a="$BATS_TEST_TMPDIR/a/%x"
  b="$BATS_TEST_TMPDIR/a%/x"
  mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/a%"
  printf 'from-a\n' > "$a"
  printf 'from-b\n' > "$b"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$a"
  canopy_tx_record "$tx" own "$b"
  backup_a="$(awk -F'\t' -v p="$a" '$2==p {print $4}' "$tx/manifest.tsv")"
  backup_b="$(awk -F'\t' -v p="$b" '$2==p {print $4}' "$tx/manifest.tsv")"
  [ "$backup_a" != "$backup_b" ]
  [ "$(cat "$tx/$backup_a")" = "from-a" ]
  [ "$(cat "$tx/$backup_b")" = "from-b" ]
}

@test "canopy_tx_record rejects an unknown action" {
  tx="$(canopy_tx_begin install)"
  run canopy_tx_record "$tx" bogus "$target"
  [ "$status" -ne 0 ]
}

@test "canopy_tx_record refuses a path with a literal tab and writes no partial row" {
  tab="$(printf '\t')"
  bad="$BATS_TEST_TMPDIR/bad${tab}path"
  tx="$(canopy_tx_begin install)"
  before="$(cat "$tx/manifest.tsv")"
  run canopy_tx_record "$tx" own "$bad"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF "$bad"
  after="$(cat "$tx/manifest.tsv")"
  [ "$before" = "$after" ]
}

@test "canopy_tx_record does not clobber a caller's own same-named variables" {
  # canopy_tx_record used to write through unscoped globals named
  # tx/action/path/pre/backup_rel; any caller using those same names for
  # its own bookkeeping (e.g. a loop reading manifest rows) would have
  # them silently overwritten mid-call. Regression test for the fix:
  # every one of canopy_tx_record's internals is now `local`.
  tx="sentinel-tx"
  action="sentinel-action"
  path="sentinel-path"
  pre="sentinel-pre"
  backup_rel="sentinel-backup-rel"
  real_tx="$(canopy_tx_begin install)"
  canopy_tx_record "$real_tx" own "$target"
  [ "$tx" = "sentinel-tx" ]
  [ "$action" = "sentinel-action" ]
  [ "$path" = "sentinel-path" ]
  [ "$pre" = "sentinel-pre" ]
  [ "$backup_rel" = "sentinel-backup-rel" ]
}

@test "two transactions with the same label in the same second get distinct dirs" {
  tx1="$(canopy_tx_begin install)"
  tx2="$(canopy_tx_begin install)"
  [ "$tx1" != "$tx2" ]
  [ -d "$tx1" ]
  [ -d "$tx2" ]
  canopy_tx_record "$tx1" own "$target"
  canopy_tx_record "$tx2" drop "$target"
  grep -q "own	$target	" "$tx1/manifest.tsv"
  grep -q "drop	$target	" "$tx2/manifest.tsv"
  ! grep -q "drop" "$tx1/manifest.tsv"
  ! grep -q "own" "$tx2/manifest.tsv"
}

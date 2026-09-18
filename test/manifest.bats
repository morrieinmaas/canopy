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

@test "every transaction ships a self-contained restore.sh" {
  tx="$(canopy_tx_begin install)"
  [ -x "$tx/restore.sh" ]
  grep -qv 'canopy_' "$tx/restore.sh"   # must not call into the store
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

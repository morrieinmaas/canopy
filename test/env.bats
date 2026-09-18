#!/usr/bin/env bats
load helper
setup() { setup_canopy_env; . "$CANOPY_STORE/lib/env.sh"; }

@test "canopy_paths respects CANOPY_* overrides" {
  canopy_paths
  [ "$CANOPY_CONFIG" = "$BATS_TEST_TMPDIR/config" ]
}

@test "canopy_paths falls back to XDG defaults" {
  unset CANOPY_CONFIG CANOPY_STATE
  HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="" canopy_paths
  [ "$CANOPY_CONFIG" = "$BATS_TEST_TMPDIR/home/.config/canopy" ]
}

@test "canopy_have detects present and absent tools" {
  canopy_have sh
  ! canopy_have definitely-not-a-real-binary-xyz
}

@test "canopy_sha256 matches a known digest" {
  printf 'canopy' > "$BATS_TEST_TMPDIR/f"
  run canopy_sha256 "$BATS_TEST_TMPDIR/f"
  [ "$output" = "fee5dfd46b125f371923dfd73b33fa40ecec5025f643991b6be24ad89546cab9" ]

  printf 'different content' > "$BATS_TEST_TMPDIR/g"
  run canopy_sha256 "$BATS_TEST_TMPDIR/g"
  [ "$output" != "fee5dfd46b125f371923dfd73b33fa40ecec5025f643991b6be24ad89546cab9" ]
}

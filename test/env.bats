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

@test "a relative XDG_CONFIG_HOME is rejected by name, not silently resolved" {
  # A relative value would be recorded verbatim into a manifest, and
  # $tx/restore.sh resolves manifest paths against whatever directory it
  # is later run from, so the restore point would name a different file
  # than the one canopy backed up.
  unset CANOPY_CONFIG CANOPY_STATE
  run env HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="relative/config" canopy doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"XDG_CONFIG_HOME"* ]]
  [[ "$output" == *"absolute"* ]]
}

@test "a relative CANOPY_STATE is rejected by name too" {
  run env CANOPY_STATE="relative/state" canopy doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANOPY_STATE"* ]]
  [[ "$output" == *"absolute"* ]]
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

@test "the runtime dir fallback is scoped to the user, because /tmp is not" {
  # /tmp is shared by every account on the machine. A plain /tmp/canopy
  # belonged to whichever user created it first, mode 755, and every
  # other user's `canopy doctor` then could not write its scratch file
  # there: it reported a healthy install as a load-bearing failure and
  # exited 2. Found by the container harness, where more than one uid
  # actually exists.
  unset CANOPY_RUNTIME
  HOME="$BATS_TEST_TMPDIR/home" XDG_RUNTIME_DIR="" canopy_paths
  [ "$CANOPY_RUNTIME" = "/tmp/canopy-$(id -u)" ]
}

@test "the runtime dir uses XDG_RUNTIME_DIR verbatim when the spec gives one" {
  # XDG_RUNTIME_DIR is per-user by spec, so no uid needs adding there.
  unset CANOPY_RUNTIME
  HOME="$BATS_TEST_TMPDIR/home" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" canopy_paths
  [ "$CANOPY_RUNTIME" = "$BATS_TEST_TMPDIR/run/canopy" ]
}

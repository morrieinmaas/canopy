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

@test "the runtime dir is created private to its owner" {
  # The fallback path is /tmp/canopy-<uid>, inside a world-writable
  # directory, so the mode it is created with is the only thing standing
  # between canopy's scratch files and every other account on the machine.
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/fresh-runtime/canopy"
  [ ! -e "$CANOPY_RUNTIME" ]
  canopy_runtime_ensure
  [ -d "$CANOPY_RUNTIME" ]
  [ "$(canopy_stat_field '%a' '%Lp' "$CANOPY_RUNTIME")" = "700" ]
}

@test "an existing private runtime dir is accepted and left alone" {
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/existing-runtime"
  mkdir -p "$CANOPY_RUNTIME"
  chmod 700 "$CANOPY_RUNTIME"
  run canopy_runtime_ensure
  [ "$status" -eq 0 ]
  [ "$(canopy_stat_field '%a' '%Lp' "$CANOPY_RUNTIME")" = "700" ]
}

@test "a world-writable runtime dir is refused, not adopted" {
  # The attack the fallback path invites: another local account creates
  # /tmp/canopy-<uid> first, with a mode that keeps it writable. mkdir -p
  # is silent about a path that already exists, so without this check
  # canopy simply writes its scratch files into someone else's directory.
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/planted-runtime"
  mkdir -p "$CANOPY_RUNTIME"
  chmod 777 "$CANOPY_RUNTIME"
  run canopy_runtime_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
  [[ "$output" == *"$CANOPY_RUNTIME"* ]]
}

@test "a group-writable runtime dir is refused too" {
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/group-runtime"
  mkdir -p "$CANOPY_RUNTIME"
  chmod 770 "$CANOPY_RUNTIME"
  run canopy_runtime_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
}

@test "a runtime path that is a regular file is refused" {
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/runtime-is-a-file"
  printf 'not a directory\n' >"$CANOPY_RUNTIME"
  run canopy_runtime_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "a runtime path that is a symlink is refused, however safe its target looks" {
  # Following it would write canopy's scratch files wherever the link
  # names, and the mode and owner checks below would then be answered by
  # the target rather than by the path canopy was handed.
  elsewhere="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$elsewhere"
  chmod 700 "$elsewhere"
  CANOPY_RUNTIME="$BATS_TEST_TMPDIR/runtime-is-a-link"
  ln -s "$elsewhere" "$CANOPY_RUNTIME"
  run canopy_runtime_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
}

@test "a runtime dir owned by another user is refused even at a safe mode" {
  # /usr is root-owned and mode 755 on every platform this project runs
  # on: safe permissions, wrong owner. The mode check alone would wave it
  # through.
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root, so no directory on this machine has the wrong owner"
  fi
  CANOPY_RUNTIME=/usr
  run canopy_runtime_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by uid"* ]]
}

@test "canopy doctor refuses a runtime dir it does not exclusively own" {
  # The refusal reaches a user through the command that actually writes
  # there, not only through the library.
  planted="$BATS_TEST_TMPDIR/planted-doctor-runtime"
  mkdir -p "$planted"
  chmod 777 "$planted"
  setup_canopy_home
  run env CANOPY_RUNTIME="$planted" canopy doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"writable by group or other"* ]]
}

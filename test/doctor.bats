#!/usr/bin/env bats
load helper

# A minimal PATH that still resolves every tool canopy-doctor itself needs
# (tmux, sh, awk, grep, printf) but excludes the directories that hold every
# one of the six probed capability tools on this development machine, so a
# dormant layer can be asserted deterministically. Mirrors caps.bats'
# restricted_path().
restricted_path() {
  printf '%s' "$CANOPY_STORE/bin:/opt/nanobrew/prefix/opt/coreutils/libexec/gnubin:/opt/nanobrew/prefix/opt/gnu-sed/libexec/gnubin:/opt/nanobrew/prefix/opt/gawk/libexec/gnubin:/opt/nanobrew/prefix/bin:/usr/bin:/bin"
}

setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
}

@test "exits 0 on a healthy tree" {
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 0 ]
}

@test "exits 2 when the shipped config is made invalid" {
  # The real store is read-only by convention; copy it so a broken conf.d
  # fragment can be planted without touching the checked-out tree.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf 'totally-not-a-real-tmux-command\n' >"$store_copy/tmux/conf.d/99-broken.conf"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"totally-not-a-real-tmux-command"* ]]
}

@test "a dormant layer prints a reason string containing 'not found'" {
  PATH="$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-doctor
  [[ "$output" == *"not found"* ]]
}

@test "a command without a summary header is reported" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  cat >"$store_copy/bin/canopy-nosummary" <<'EOF'
#!/bin/sh
# canopy:group=misc
set -eu
printf 'nosummary\n'
EOF
  chmod +x "$store_copy/bin/canopy-nosummary"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [[ "$output" == *"nosummary"* ]]
}

@test "the keybinding cross-check is reported as stubbed, not silently omitted" {
  run canopy-doctor
  [[ "$output" == *"stub"* ]]
}

@test "reports restore point count and whether the pinned point exists" {
  # Built directly from lib/manifest.sh, not via `canopy install`: this test
  # must never touch the real $HOME, and canopy install writes there.
  . "$CANOPY_STORE/lib/manifest.sh"
  target="$BATS_TEST_TMPDIR/target.conf"
  printf 'original\n' >"$target"
  tx="$(canopy_tx_begin install)"
  touch "$tx/.pinned"
  canopy_tx_record "$tx" own "$target"
  canopy_tx_commit "$tx"

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"count: 1"* ]]
  [[ "$output" == *"pinned pre-install point: yes"* ]]
}

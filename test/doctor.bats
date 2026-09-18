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
  # doctor reads $HOME to find the entry point it validates, so every test
  # here gets a scratch one. Never the real $HOME.
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
}

@test "exits 0 on a healthy tree" {
  run canopy install
  [ "$status" -eq 0 ]
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 0 ]
}

@test "exits 2 when the store the entry point points at is made invalid" {
  # The real store is read-only by convention; copy it so a broken conf.d
  # fragment can be planted without touching the checked-out tree. The
  # fragment is planted after install, because install would otherwise
  # refuse to commit a config that does not load, which is its job.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy install
  [ "$status" -eq 0 ]
  printf 'totally-not-a-real-tmux-command\n' >"$store_copy/tmux/conf.d/99-broken.conf"

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
  run canopy install
  [ "$status" -eq 0 ]
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"count: 1"* ]]
  [[ "$output" == *"pinned pre-install point: yes"* ]]
}

@test "warns about an install interrupted before it committed, naming the recovery command" {
  # Same simulated interruption as restore.bats: recorded rows and a byte
  # copy of the original, but no .committed and no .pinned marker. This is
  # the one situation doctor exists for, and it used to report OK.
  run canopy install
  [ "$status" -eq 0 ]
  . "$CANOPY_STORE/lib/manifest.sh"
  target="$BATS_TEST_TMPDIR/target.conf"
  printf 'original\n' >"$target"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$target"
  printf 'canopy-owned\n' >"$target"
  tx_id="$(basename "$tx")"

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INCOMPLETE"* ]]
  [[ "$output" == *"$tx_id"* ]]
  [[ "$output" == *"canopy restore --to $tx_id"* ]]
}

@test "does not warn about a transaction install already reverted itself" {
  run canopy install
  [ "$status" -eq 0 ]
  . "$CANOPY_STORE/lib/manifest.sh"
  target="$BATS_TEST_TMPDIR/target.conf"
  printf 'original\n' >"$target"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$target"
  touch "$tx/.failed"

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"INCOMPLETE"* ]]
}

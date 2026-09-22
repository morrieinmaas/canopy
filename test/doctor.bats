#!/usr/bin/env bats
load helper

# The restricted PATH these tests run under lives in test/helper.bash.

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

# interrupt_install
# The on-disk state canopy-install leaves behind when it is killed between
# migrating the user's files and committing: recorded rows and a byte copy
# of the original, no .committed marker and no .failed marker. Sets $tx,
# $tx_id, $target and $orig_hash.
interrupt_install() {
  . "$CANOPY_STORE/lib/manifest.sh"
  target="$BATS_TEST_TMPDIR/target.conf"
  printf 'original\n' >"$target"
  orig_hash="$(canopy_sha256 "$target")"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$target"
  printf 'canopy-owned\n' >"$target"
  tx_id="$(basename "$tx")"
}

@test "stops warning once the recovery command doctor named has been run" {
  # Doctor's advice has to be worth following. It used to name a recovery
  # command, and then report the same machine as needing attention forever
  # after the user ran it, because nothing in the transaction said it had
  # been reverted.
  run canopy install
  [ "$status" -eq 0 ]
  interrupt_install

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]

  run canopy-doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INCOMPLETE"* ]]
  [[ "$output" == *"canopy restore --to $tx_id"* ]]

  run canopy restore --to "$tx_id"
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$target")" = "$orig_hash" ]

  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"INCOMPLETE"* ]]
  [[ "$output" == *"already reverted"* ]]
}

@test "stops warning after the self-contained restore.sh recovered the transaction" {
  # The escape hatch is deliberately independent of canopy, so it can never
  # write a canopy marker. A doctor that trusted a marker instead of the
  # machine would keep warning about a transaction the documented recovery
  # tool had already undone.
  run canopy install
  [ "$status" -eq 0 ]
  interrupt_install

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]

  run canopy-doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INCOMPLETE"* ]]

  run "$tx/restore.sh"
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$target")" = "$orig_hash" ]

  run canopy-doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"INCOMPLETE"* ]]
}

@test "still warns when only some of the transaction's paths are back" {
  # A partial recovery is not a recovery. The warning must survive one of
  # two recorded paths being put back by hand.
  run canopy install
  [ "$status" -eq 0 ]
  . "$CANOPY_STORE/lib/manifest.sh"
  one="$BATS_TEST_TMPDIR/one.conf"
  two="$BATS_TEST_TMPDIR/two.conf"
  printf 'original one\n' >"$one"
  printf 'original two\n' >"$two"
  tx="$(canopy_tx_begin install)"
  canopy_tx_record "$tx" own "$one"
  canopy_tx_record "$tx" own "$two"
  printf 'canopy-owned\n' >"$one"
  printf 'canopy-owned\n' >"$two"
  printf 'original one\n' >"$one"

  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INCOMPLETE"* ]]
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

@test "exits 2 when the config this machine loads leaves continuum's restore off" {
  # Spec 5.3 assigns @continuum-restore to doctor, and continuum defaults
  # it to off. With it off nothing is restored after a reboot, so every
  # other part of persistence writes save files that nobody reads.
  #
  # Asserted against the config the entry point actually loads, not
  # against the store's own layer: user.conf is sourced last, so it is
  # also the way a setting gets turned off without anyone noticing.
  run canopy install
  [ "$status" -eq 0 ]
  printf 'set -g @continuum-restore off\n' >>"$CANOPY_CONFIG/user.conf"
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy-index
  [ "$status" -eq 0 ]
  run canopy-doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"@continuum-restore"* ]]
  [[ "$output" == *"FAILED"* ]]
}

@test "doctor names ps as what agent panes are recognised through" {
  run canopy install
  [ "$status" -eq 0 ]
  run canopy-doctor
  [[ "$output" == *"ps (agent panes are recognised through it): yes"* ]]
}

@test "doctor says so when this machine's ps cannot answer" {
  # The failure this exists for is silent by nature. An absent bash leaves
  # the plugin layer unloaded and visibly dormant; a ps that cannot report
  # a process's parent leaves every plugin loaded and quietly useless,
  # because canopy recognises an agent pane by asking ps what the pane is
  # running. reboot-check then reports no agent panes on a machine full of
  # them, which is the one answer it must never give.
  #
  # BusyBox ships exactly such a ps, so this is a real machine, not a
  # contrived one: it is what an Alpine box does.
  fake_bin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fake_bin"
  printf '#!/bin/sh\nexit 1\n' >"$fake_bin/ps"
  chmod +x "$fake_bin/ps"

  run canopy install
  [ "$status" -eq 0 ]
  PATH="$fake_bin:$PATH" run canopy-doctor
  [[ "$output" == *"ps (agent panes are recognised through it): dormant"* ]]
  [[ "$output" == *"no pane is recognised as an agent"* ]]
}

#!/usr/bin/env bats
load helper

# A minimal PATH that still resolves every tool canopy install itself needs
# (tmux, sh, awk, sort, date, cp, mkdir, chmod, sha256 tool) but excludes the
# directory that holds mise on this development machine, so "mise absent" can
# be asserted deterministically. Mirrors caps.bats' restricted_path().
restricted_path() {
  printf '%s' "$CANOPY_STORE/bin:/opt/nanobrew/prefix/opt/coreutils/libexec/gnubin:/opt/nanobrew/prefix/opt/gnu-sed/libexec/gnubin:/opt/nanobrew/prefix/opt/gawk/libexec/gnubin:/opt/nanobrew/prefix/bin:/usr/bin:/bin"
}

setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
  # Safety: every test gets its own fake HOME/XDG_CONFIG_HOME under
  # BATS_TEST_TMPDIR. Never the real $HOME.
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  HOME="$home"
  XDG_CONFIG_HOME="$home/.config"
  export HOME XDG_CONFIG_HOME
}

@test "install preserves an existing tmux.conf into user.conf and owns the entry point" {
  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"
  run canopy install --yes
  [ "$status" -eq 0 ]
  grep -q '@preexisting' "$CANOPY_CONFIG/user.conf"
  grep -q 'canopy' "$XDG_CONFIG_HOME/tmux/tmux.conf"
  grep -q 'source-file "\$CANOPY_STORE/tmux/tmux.conf"' "$XDG_CONFIG_HOME/tmux/tmux.conf"
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

@test "dry run changes nothing" {
  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"
  before="$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")"
  state_before="$(find "$CANOPY_STATE" -type f | sort)"
  config_before="$(find "$CANOPY_CONFIG" -type f | sort)"
  run canopy install --dry-run
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")" = "$before" ]
  [ "$(find "$CANOPY_STATE" -type f | sort)" = "$state_before" ]
  [ "$(find "$CANOPY_CONFIG" -type f | sort)" = "$config_before" ]
}

@test "install without --yes refuses when a config already exists" {
  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"
  run canopy install
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]]
  # refusal must not have mutated anything
  grep -q '@preexisting' "$XDG_CONFIG_HOME/tmux/tmux.conf"
  ! [ -e "$CANOPY_STATE/backups" ]
}

@test "the install transaction is pinned" {
  run canopy install --yes
  [ "$status" -eq 0 ]
  ls "$CANOPY_STATE"/backups/*/.pinned
}

@test "install with no pre-existing config proceeds without --yes, creates an entry point and an empty user.conf" {
  run canopy install
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_CONFIG/user.conf" ]
  [ ! -s "$CANOPY_CONFIG/user.conf" ] || grep -q '^#' "$CANOPY_CONFIG/user.conf"
  [ -f "$XDG_CONFIG_HOME/tmux/tmux.conf" ]
  grep -q 'source-file "\$CANOPY_STORE/tmux/tmux.conf"' "$XDG_CONFIG_HOME/tmux/tmux.conf"
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

@test "the fresh entry point is recorded as drop with an absent pre-state" {
  run canopy install
  [ "$status" -eq 0 ]
  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  row="$(awk -F'\t' -v p="$XDG_CONFIG_HOME/tmux/tmux.conf" '$2==p' "${tx_dir}manifest.tsv")"
  [ -n "$row" ]
  [ "$(printf '%s' "$row" | awk -F'\t' '{print $1}')" = "drop" ]
  [ "$(printf '%s' "$row" | awk -F'\t' '{print $3}')" = "absent" ]
}

@test "restore removes the fresh entry point and the parent directory canopy created for it" {
  run canopy install
  [ "$status" -eq 0 ]
  [ -d "$XDG_CONFIG_HOME/tmux" ]
  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  "${tx_dir}restore.sh"
  [ ! -e "$XDG_CONFIG_HOME/tmux/tmux.conf" ]
  [ ! -d "$XDG_CONFIG_HOME/tmux" ]
}

@test "restore keeps a tmux dir that predates canopy, with its other contents" {
  mkdir -p "$XDG_CONFIG_HOME/tmux/plugins"
  touch "$XDG_CONFIG_HOME/tmux/plugins/.keep"
  run canopy install
  [ "$status" -eq 0 ]
  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  "${tx_dir}restore.sh"
  [ ! -e "$XDG_CONFIG_HOME/tmux/tmux.conf" ]
  [ -d "$XDG_CONFIG_HOME/tmux" ]
  [ -f "$XDG_CONFIG_HOME/tmux/plugins/.keep" ]
}

@test "restore --all returns the tree to its exact pre-install state, directories included" {
  # A fake mise on PATH makes write_mise deterministic regardless of
  # whether the real dev/CI machine happens to have mise installed, while
  # leaving ~/.config/mise itself absent, same as ~/.config/tmux.
  fake_bin="$BATS_TEST_TMPDIR/fakebin-mise-fresh"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/mise" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/mise"
  PATH="$fake_bin:$PATH"

  [ ! -d "$XDG_CONFIG_HOME/tmux" ]
  [ ! -d "$XDG_CONFIG_HOME/mise" ]
  before="$(find "$HOME" | sort)"

  run canopy install
  [ "$status" -eq 0 ]
  [ -d "$XDG_CONFIG_HOME/tmux" ]
  [ -d "$XDG_CONFIG_HOME/mise/conf.d" ]

  run canopy restore --all
  [ "$status" -eq 0 ]

  # find (not find -type f): the tree, directories included, must be
  # byte-identical to before install ever ran.
  after="$(find "$HOME" | sort)"
  [ "$before" = "$after" ]
}

@test "restore removes only the mise conf.d it created, keeping a pre-existing mise dir" {
  fake_bin="$BATS_TEST_TMPDIR/fakebin-mise-partial"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/mise" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/mise"
  PATH="$fake_bin:$PATH"

  mkdir -p "$XDG_CONFIG_HOME/mise"
  touch "$XDG_CONFIG_HOME/mise/config.toml"

  run canopy install
  [ "$status" -eq 0 ]
  [ -d "$XDG_CONFIG_HOME/mise/conf.d" ]

  run canopy restore --all
  [ "$status" -eq 0 ]

  [ ! -e "$XDG_CONFIG_HOME/mise/conf.d" ]
  [ -d "$XDG_CONFIG_HOME/mise" ]
  [ -f "$XDG_CONFIG_HOME/mise/config.toml" ]
}

@test "restore keeps a pre-existing mise dir even though removing conf.d leaves it empty" {
  # Unlike the previous test, mise/ holds nothing else: a wrong
  # implementation that tracked the pre-existing parent (not just the
  # conf.d level it actually created) would still successfully rmdir it,
  # since it really is empty by the time cleanup runs. Only "never record a
  # directory that already existed" (not "rmdir happens to fail") can make
  # this test pass.
  fake_bin="$BATS_TEST_TMPDIR/fakebin-mise-empty"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/mise" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/mise"
  PATH="$fake_bin:$PATH"

  mkdir -p "$XDG_CONFIG_HOME/mise"

  run canopy install
  [ "$status" -eq 0 ]
  [ -d "$XDG_CONFIG_HOME/mise/conf.d" ]

  run canopy restore --all
  [ "$status" -eq 0 ]

  [ ! -e "$XDG_CONFIG_HOME/mise/conf.d" ]
  [ -d "$XDG_CONFIG_HOME/mise" ]
}

@test "install tracks the directory it creates for its own config dir, but never that dir itself" {
  # The real default layout, which the rest of this file deliberately
  # avoids by pointing CANOPY_CONFIG outside $HOME: canopy's own config
  # lives inside $XDG_CONFIG_HOME. install used to create $CANOPY_CONFIG
  # with a bare mkdir -p, so the ~/.config it made on the way was the one
  # directory install creates that canopy_mkdir_tracked never saw.
  CANOPY_CONFIG="$XDG_CONFIG_HOME/canopy"
  export CANOPY_CONFIG
  [ ! -d "$XDG_CONFIG_HOME" ]

  run canopy install
  [ "$status" -eq 0 ]

  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  grep -qx "$XDG_CONFIG_HOME" "${tx_dir}dirs-created.txt"
  # $CANOPY_CONFIG is never touched by restore (spec 5.5), so it must not
  # be tracked for removal in the first place, and neither must anything
  # under it.
  ! grep -qx "$CANOPY_CONFIG" "${tx_dir}dirs-created.txt"
}

@test "install writes the mise fragment when mise conf.d already exists" {
  mkdir -p "$XDG_CONFIG_HOME/mise/conf.d"
  PATH="$(restricted_path)"
  run canopy install --yes
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/mise/conf.d/canopy.toml" ]
}

@test "install skips the mise fragment silently when mise is absent and conf.d does not exist" {
  PATH="$(restricted_path)"
  run canopy install --yes
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/mise/conf.d/canopy.toml" ]
}

@test "install rolls back the transaction when the resulting config fails validation" {
  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"
  orig_hash="$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")"

  # The real store is read-only by convention; copy it so we can plant a
  # broken conf.d fragment without touching the checked-out tree.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf 'totally-not-a-real-tmux-command\n' >"$store_copy/tmux/conf.d/99-broken.conf"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy install --yes
  [ "$status" -ne 0 ]
  [ "$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")" = "$orig_hash" ]
  # a failed install must not leave a phantom pinned/committed restore point
  [ -z "$(find "$CANOPY_STATE/backups" -name .pinned)" ]
  [ -z "$(find "$CANOPY_STATE/backups" -name .committed)" ]
  [ -n "$(find "$CANOPY_STATE/backups" -name .failed)" ]
}

@test "a failed install leaves a pre-existing user.conf byte-identical" {
  mkdir -p "$CANOPY_CONFIG"
  printf '# my prior overrides\nset -g @mine 1\n' >"$CANOPY_CONFIG/user.conf"
  orig_hash="$(canopy_sha256 "$CANOPY_CONFIG/user.conf")"

  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"

  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf 'totally-not-a-real-tmux-command\n' >"$store_copy/tmux/conf.d/99-broken.conf"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy install --yes
  [ "$status" -ne 0 ]
  [ "$(canopy_sha256 "$CANOPY_CONFIG/user.conf")" = "$orig_hash" ]
}

@test "a second install recognises its own entry point and refuses without mutating anything" {
  run canopy install
  [ "$status" -eq 0 ]
  tx_count_before="$(find "$CANOPY_STATE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"

  run canopy install
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]

  tx_count_after="$(find "$CANOPY_STATE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "$tx_count_before" = "$tx_count_after" ]
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

@test "a second install over a migrated foreign config also refuses, non-destructively" {
  mkdir -p "$XDG_CONFIG_HOME/tmux"
  printf 'set -g @preexisting yes\n' >"$XDG_CONFIG_HOME/tmux/tmux.conf"
  run canopy install --yes
  [ "$status" -eq 0 ]
  user_conf_hash_before="$(canopy_sha256 "$CANOPY_CONFIG/user.conf")"
  entry_hash_before="$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")"

  run canopy install --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
  [ "$(canopy_sha256 "$CANOPY_CONFIG/user.conf")" = "$user_conf_hash_before" ]
  [ "$(canopy_sha256 "$XDG_CONFIG_HOME/tmux/tmux.conf")" = "$entry_hash_before" ]
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

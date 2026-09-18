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
}

#!/usr/bin/env bats
# A symlinked ~/.config/tmux/tmux.conf is what chezmoi, stow and a bare
# dotfiles repo all produce, so it is the normal case, not an exotic one.
# Install used to write straight through the link and modify its target, a
# path it never recorded, which made the restore guarantee false for every
# dotfiles user.
load helper

setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths

  dotfiles="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$dotfiles" "$XDG_CONFIG_HOME/tmux"
  target="$dotfiles/tmux.conf"
  entry="$XDG_CONFIG_HOME/tmux/tmux.conf"
  printf 'set -g @from_dotfiles yes\n' >"$target"
  target_hash="$(canopy_sha256 "$target")"
}

@test "install never writes through a symlinked entry point" {
  ln -s "$target" "$entry"
  run canopy install --yes
  [ "$status" -eq 0 ]

  [ "$(canopy_sha256 "$target")" = "$target_hash" ]
  [ ! -L "$entry" ]
  [ -f "$entry" ]
  grep -q 'canopy:entry-point' "$entry"
  # The link's content still reached user.conf: owning the entry point is a
  # migration, and the migration must not be what the symlink cost.
  grep -q '@from_dotfiles' "$CANOPY_CONFIG/user.conf"
}

@test "the manifest records the link itself, not the bytes at the other end" {
  ln -s "$target" "$entry"
  run canopy install --yes
  [ "$status" -eq 0 ]

  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  row="$(awk -F'\t' -v p="$entry" '$2==p' "${tx_dir}manifest.tsv")"
  [ "$(printf '%s' "$row" | awk -F'\t' '{print $3}')" = "symlink:$target" ]
  backup="${tx_dir}$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  [ -L "$backup" ]
  [ "$(readlink "$backup")" = "$target" ]
}

@test "restore --all recreates the symlink and leaves its target byte-identical" {
  ln -s "$target" "$entry"
  before="$(find "$HOME" | sort)"
  run canopy install --yes
  [ "$status" -eq 0 ]

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ -L "$entry" ]
  [ "$(readlink "$entry")" = "$target" ]
  [ "$(canopy_sha256 "$target")" = "$target_hash" ]
  [ "$(find "$HOME" | sort)" = "$before" ]
}

@test "a relative symlink is restored as the same relative symlink" {
  rel="../../../dotfiles/tmux.conf"
  ln -s "$rel" "$entry"
  # The link has to resolve for tmux and for install's migration read.
  [ -f "$entry" ]
  run canopy install --yes
  [ "$status" -eq 0 ]

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ -L "$entry" ]
  [ "$(readlink "$entry")" = "$rel" ]
  [ "$(canopy_sha256 "$target")" = "$target_hash" ]
}

@test "the self-contained restore.sh also puts the symlink back" {
  # restore.sh is the escape hatch for when canopy itself is what broke, so
  # it carries its own copy of this logic and needs its own test.
  ln -s "$target" "$entry"
  run canopy install --yes
  [ "$status" -eq 0 ]

  for tx in "$CANOPY_STATE"/backups/*/; do tx_dir="$tx"; done
  "${tx_dir}restore.sh"
  [ -L "$entry" ]
  [ "$(readlink "$entry")" = "$target" ]
  [ "$(canopy_sha256 "$target")" = "$target_hash" ]
}

@test "a symlinked user.conf is replaced, not appended through" {
  # Same hazard one directory over: canopy appends the migrated config to
  # user.conf, and appending through a link modifies a file canopy never
  # recorded.
  user_target="$dotfiles/canopy-user.conf"
  printf '# my overrides\nset -g @mine 1\n' >"$user_target"
  user_target_hash="$(canopy_sha256 "$user_target")"
  mkdir -p "$CANOPY_CONFIG"
  ln -s "$user_target" "$CANOPY_CONFIG/user.conf"
  printf 'set -g @preexisting yes\n' >"$entry"

  run canopy install --yes
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$user_target")" = "$user_target_hash" ]
  [ ! -L "$CANOPY_CONFIG/user.conf" ]
  grep -q '@mine' "$CANOPY_CONFIG/user.conf"
  grep -q '@preexisting' "$CANOPY_CONFIG/user.conf"

  run canopy restore --all
  [ "$status" -eq 0 ]
  [ -L "$CANOPY_CONFIG/user.conf" ]
  [ "$(canopy_sha256 "$user_target")" = "$user_target_hash" ]
}

@test "the installed entry point still loads with no CANOPY_* set" {
  ln -s "$target" "$entry"
  run canopy install --yes
  [ "$status" -eq 0 ]

  sock="canopy-symlink-$$"
  bare_tmux -L "$sock" -f "$entry" new-session -d
  run bare_tmux -L "$sock" show -gv @from_dotfiles
  bare_tmux_cleanup "$sock"
  [ "$output" = "yes" ]
}

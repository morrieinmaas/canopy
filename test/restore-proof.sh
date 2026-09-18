#!/bin/sh
# Proves canopy's headline guarantee: install onto a machine that already has
# real configs, then `restore --all` returns it byte-identical, directories
# included. POSIX sh, runnable locally and in CI. Never touches the real
# $HOME: everything canopy would read or write is pointed at a scratch tree
# for the duration of this script.
set -eu

store="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

home="$scratch/home"
mkdir -p "$home"

# Fake $HOME with pre-existing, distinctive configs. canopy install in M1
# only integrates with tmux; the ghostty and starship files exist purely to
# prove restore never touches anything it doesn't own.
mkdir -p "$home/.config/tmux"
# Must be valid tmux syntax: canopy install migrates this content into
# user.conf and then validates the resulting config chain before
# committing, so an arbitrary line here would fail that validation and
# roll the install back before there is anything to restore. A `@`-prefixed
# user option is real tmux syntax and still carries a distinctive value.
printf 'set -g @restore_proof_marker distinctive-tmux-%s\n' "$$" >"$home/.config/tmux/tmux.conf"
mkdir -p "$home/.config/ghostty/themes"
printf 'distinctive ghostty config %s\n' "$$" >"$home/.config/ghostty/config"
printf 'distinctive ghostty theme %s\n' "$$" >"$home/.config/ghostty/themes/mytheme"
printf 'distinctive starship config %s\n' "$$" >"$home/.config/starship.toml"

# canopy's own state/config are deliberately pointed OUTSIDE $home: per spec
# 5.5, ~/.config/canopy/ is never touched by restore, so if it lived under
# $home it would legitimately survive restore and make the "no new canopy
# artifact under $HOME" check below meaningless. This proof is about the
# pre-existing app configs restore promises to return untouched, not about
# canopy's own persistent state.
export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export CANOPY_STORE="$store"
export CANOPY_CONFIG="$scratch/canopy-config"
export CANOPY_STATE="$scratch/canopy-state"
export CANOPY_RUNTIME="$scratch/canopy-run"
PATH="$store/bin:$PATH"
export PATH

# shellcheck source=../lib/env.sh
# shellcheck disable=SC1091
. "$store/lib/env.sh"
canopy_paths

# canopy_restore_proof_record <listing-file> <hash-file>
# <listing-file> gets `find "$HOME" | sort`, directories included: a
# directory canopy creates and restore leaves behind is a survived
# artifact, and a file-only listing would miss that regression.
canopy_restore_proof_record() {
  find "$home" | sort >"$1"
  : >"$2"
  find "$home" -type f | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(canopy_sha256 "$f")" "$f" >>"$2"
  done
}

before_list="$scratch/before.list"
before_hashes="$scratch/before.hashes"
canopy_restore_proof_record "$before_list" "$before_hashes"

echo "restore-proof: installing..."
canopy install --yes

pinned_dir=""
for f in "$CANOPY_STATE"/backups/*/.pinned; do
  [ -f "$f" ] || continue
  pinned_dir="$(dirname "$f")"
done
if [ -z "$pinned_dir" ]; then
  canopy_die "restore-proof: no pinned pre-install restore point found"
fi
if [ ! -f "$pinned_dir/manifest.tsv" ]; then
  canopy_die "restore-proof: pinned transaction $pinned_dir has no manifest.tsv"
fi
printf 'restore-proof: manifest exists and is pinned (%s)\n' "$pinned_dir"

echo "restore-proof: restoring..."
canopy restore --all

after_list="$scratch/after.list"
after_hashes="$scratch/after.hashes"
canopy_restore_proof_record "$after_list" "$after_hashes"

fail=0

if ! diff -u "$before_list" "$after_list"; then
  echo "restore-proof: FAILED, the file/directory listing under \$HOME changed" >&2
  fail=1
fi

if ! diff -u "$before_hashes" "$after_hashes"; then
  echo "restore-proof: FAILED, one or more file contents changed" >&2
  fail=1
fi

# No path under $HOME may contain the string "canopy" that did not already
# contain it before install ran.
before_canopy="$(grep 'canopy' "$before_list" || :)"
after_canopy="$(grep 'canopy' "$after_list" || :)"
if [ "$before_canopy" != "$after_canopy" ]; then
  echo "restore-proof: FAILED, a canopy artifact survived restore" >&2
  echo "before:" >&2
  printf '%s\n' "$before_canopy" >&2
  echo "after:" >&2
  printf '%s\n' "$after_canopy" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

printf 'restore-proof: OK, %s is byte-identical to its pre-install state\n' "$home"

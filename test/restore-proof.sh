#!/bin/sh
# Proves canopy's headline guarantee: install onto a machine that already has
# real configs, then `restore --all` returns it byte-identical, directories
# included. POSIX sh, runnable locally and in CI. Never touches the real
# $HOME: everything canopy would read or write is pointed at a scratch tree
# for the duration of this script.
#
# Three scenarios, because they cover different leak classes:
#   1. a home that already has configs, with canopy's own config and state
#      outside it, so "no canopy artifact under $HOME" is a meaningful check;
#   2. a genuinely empty home with canopy's own config and state INSIDE it,
#      which is the real default layout and the only way to exercise the
#      directories install has to create from nothing (~/.config and below);
#   3. a symlinked tmux.conf whose target lives outside $HOME, which is what
#      chezmoi, stow and a bare dotfiles repo all produce, and which neither
#      scenario above can see damage because the damaged file is not in any
#      listing they take.
set -eu

store="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

PATH="$store/bin:$PATH"
export PATH
export CANOPY_STORE="$store"

# shellcheck source=../lib/env.sh
# shellcheck disable=SC1091
. "$store/lib/env.sh"

fail=0

# canopy_restore_proof_record <root> <listing-file> <hash-file>
# <listing-file> gets `find <root> | sort`, directories included: a
# directory canopy creates and restore leaves behind is a survived
# artifact, and a file-only listing would miss that regression.
canopy_restore_proof_record() {
  find "$1" | sort >"$2"
  : >"$3"
  find "$1" -type f | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(canopy_sha256 "$f")" "$f" >>"$3"
  done
}

# canopy_restore_proof_outside_state <path|hash>
# Filter: drops canopy's state tree from a listing on stdin, along with the
# ancestor directories that exist only to hold it. $CANOPY_STATE holds the
# restore points themselves, and the guarantee is that they are reachable
# forever, so nothing that contains them can be removed.
#
# $CANOPY_CONFIG used to be filtered out here too, and that is exactly what
# hid a restore leaving ~/.config/canopy and ~/.config standing on a
# machine that had neither before install. An empty canopy config
# directory that install created is an artifact like any other and must
# go; one holding user overrides survives on its own, because restore uses
# rmdir. Either way the proof now watches it.
#
# "path" reads the whole line as a path, "hash" reads it as the hash
# listing's "<sha256><2 spaces><path>".
canopy_restore_proof_outside_state() {
  awk -v s="$CANOPY_STATE" -v mode="$1" '
    function related(p, base) {
      if (p == base) return 1
      if (substr(p, 1, length(base) + 1) == base "/") return 1
      if (substr(base, 1, length(p) + 1) == p "/") return 1
      return 0
    }
    {
      p = $0
      if (mode == "hash") p = substr($0, index($0, "  ") + 2)
      if (!related(p, s)) print
    }
  '
}

# --- Scenario 1: a home that already has configs ---------------------------
echo "restore-proof: scenario 1, a home that already has real configs"

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

# canopy's own state/config are deliberately pointed OUTSIDE $home: the
# restore points under $CANOPY_STATE must survive for the guarantee to be
# forever, so keeping them out of $home is what makes "no new canopy
# artifact under $HOME" a meaningful check here. This scenario is about the
# pre-existing app configs restore promises to return untouched. Scenario 2
# covers the default layout, where both live inside $HOME.
export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export CANOPY_CONFIG="$scratch/canopy-config"
export CANOPY_STATE="$scratch/canopy-state"
export CANOPY_RUNTIME="$scratch/canopy-run"
canopy_paths

before_list="$scratch/before.list"
before_hashes="$scratch/before.hashes"
canopy_restore_proof_record "$home" "$before_list" "$before_hashes"

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
canopy_restore_proof_record "$home" "$after_list" "$after_hashes"

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

if [ "$fail" -eq 0 ]; then
  printf 'restore-proof: scenario 1 OK, %s is byte-identical to its pre-install state\n' "$home"
fi

# --- Scenario 2: a genuinely empty home, canopy's own dirs inside it --------
# Scenario 1 pre-creates $home/.config and keeps canopy's config and state
# outside $HOME, so it structurally cannot observe a directory that install
# creates from nothing under $HOME and restore then fails to remove. This
# scenario starts from an empty home at the real default layout, where
# ~/.config, ~/.config/tmux and ~/.config/mise/conf.d all have to be created
# by install and removed by restore.
echo
echo "restore-proof: scenario 2, an empty home with canopy's own dirs inside it"

home2="$scratch/home2"
mkdir -p "$home2"

export HOME="$home2"
export XDG_CONFIG_HOME="$home2/.config"
export CANOPY_CONFIG="$home2/.config/canopy"
export CANOPY_STATE="$home2/.local/state/canopy"
export CANOPY_RUNTIME="$scratch/canopy-run2"
canopy_paths

before2_list="$scratch/before2.list"
before2_hashes="$scratch/before2.hashes"
canopy_restore_proof_record "$home2" "$before2_list" "$before2_hashes"

echo "restore-proof: installing..."
canopy install --yes

installed2_list="$scratch/installed2.list"
installed2_hashes="$scratch/installed2.hashes"
canopy_restore_proof_record "$home2" "$installed2_list" "$installed2_hashes"

# Guard against a vacuous pass: install must actually have created
# something under $HOME outside canopy's state tree for the comparison
# below to mean anything.
installed2_outside="$(canopy_restore_proof_outside_state path <"$installed2_list")"
if [ -z "$installed2_outside" ]; then
  echo "restore-proof: FAILED, install created nothing under \$HOME outside canopy's state tree" >&2
  fail=1
fi

echo "restore-proof: restoring..."
canopy restore --all

after2_list="$scratch/after2.list"
after2_hashes="$scratch/after2.hashes"
canopy_restore_proof_record "$home2" "$after2_list" "$after2_hashes"

canopy_restore_proof_outside_state path <"$before2_list" >"$before2_list.filtered"
canopy_restore_proof_outside_state path <"$after2_list" >"$after2_list.filtered"
canopy_restore_proof_outside_state hash <"$before2_hashes" >"$before2_hashes.filtered"
canopy_restore_proof_outside_state hash <"$after2_hashes" >"$after2_hashes.filtered"

if ! diff -u "$before2_list.filtered" "$after2_list.filtered"; then
  echo "restore-proof: FAILED, a directory or file outside canopy's state tree survived restore" >&2
  fail=1
fi

if ! diff -u "$before2_hashes.filtered" "$after2_hashes.filtered"; then
  echo "restore-proof: FAILED, one or more file contents changed" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  printf 'restore-proof: scenario 2 OK, nothing outside the canopy state tree survived under %s\n' "$home2"
fi

# --- Scenario 3: a symlinked tmux.conf, the dotfiles case ------------------
# chezmoi, stow and a bare dotfiles repo all leave ~/.config/tmux/tmux.conf
# as a symlink into a directory outside $HOME. Neither scenario above can
# see install writing through such a link, because the file it damages is
# not under $HOME and so appears in no listing either of them takes. The
# link, its target, and the rest of the dotfiles directory are all checked
# here.
echo
echo "restore-proof: scenario 3, a symlinked tmux.conf pointing outside \$HOME"

home3="$scratch/home3"
dotfiles="$scratch/dotfiles"
mkdir -p "$home3/.config/tmux" "$dotfiles"
printf 'set -g @restore_proof_symlink distinctive-dotfiles-%s\n' "$$" >"$dotfiles/tmux.conf"
printf 'unrelated dotfiles content %s\n' "$$" >"$dotfiles/other.conf"
ln -s "$dotfiles/tmux.conf" "$home3/.config/tmux/tmux.conf"

export HOME="$home3"
export XDG_CONFIG_HOME="$home3/.config"
export CANOPY_CONFIG="$scratch/canopy-config3"
export CANOPY_STATE="$scratch/canopy-state3"
export CANOPY_RUNTIME="$scratch/canopy-run3"
canopy_paths

before3_list="$scratch/before3.list"
before3_hashes="$scratch/before3.hashes"
canopy_restore_proof_record "$dotfiles" "$before3_list" "$before3_hashes"
before3_link="$(readlink "$home3/.config/tmux/tmux.conf")"

echo "restore-proof: installing..."
canopy install --yes

# The moment of truth: install has taken ownership of the entry point, and
# the dotfiles directory the link points into must not have moved a byte.
installed3_hashes="$scratch/installed3.hashes"
canopy_restore_proof_record "$dotfiles" "$scratch/installed3.list" "$installed3_hashes"
if ! diff -u "$before3_hashes" "$installed3_hashes"; then
  echo "restore-proof: FAILED, install wrote through the symlink into $dotfiles" >&2
  fail=1
fi
if [ -L "$home3/.config/tmux/tmux.conf" ]; then
  echo "restore-proof: FAILED, install left the entry point as a symlink" >&2
  fail=1
fi

echo "restore-proof: restoring..."
canopy restore --all

after3_list="$scratch/after3.list"
after3_hashes="$scratch/after3.hashes"
canopy_restore_proof_record "$dotfiles" "$after3_list" "$after3_hashes"

if ! diff -u "$before3_list" "$after3_list"; then
  echo "restore-proof: FAILED, the listing under $dotfiles changed" >&2
  fail=1
fi
if ! diff -u "$before3_hashes" "$after3_hashes"; then
  echo "restore-proof: FAILED, a file under $dotfiles changed" >&2
  fail=1
fi
if [ ! -L "$home3/.config/tmux/tmux.conf" ]; then
  echo "restore-proof: FAILED, restore did not put the symlink back" >&2
  fail=1
elif [ "$(readlink "$home3/.config/tmux/tmux.conf")" != "$before3_link" ]; then
  echo "restore-proof: FAILED, the restored symlink points somewhere else" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

printf 'restore-proof: scenario 3 OK, the symlink and %s are exactly as they were\n' "$dotfiles"
printf 'restore-proof: OK, all three scenarios passed\n'

#!/bin/sh
# Re-vendor one plugin at the commit pinned in plugins/VERSIONS.
#
# This is a maintainer tool, not part of the installed product: canopy
# never fetches anything at runtime, and nothing in bin/ calls this. It
# exists so the vendored trees can be produced again from their pins,
# which is the only thing that makes a pin worth writing down.
#
# Usage: plugins/vendor.sh <name>
set -eu

CANOPY_STORE="$(cd "$(dirname "$0")/.." && pwd)"
export CANOPY_STORE
# shellcheck source=../lib/env.sh
# shellcheck disable=SC1091
. "$CANOPY_STORE/lib/env.sh"
# shellcheck source=../lib/plugins.sh
# shellcheck disable=SC1091
. "$CANOPY_STORE/lib/plugins.sh"

if [ $# -ne 1 ]; then
  printf 'usage: plugins/vendor.sh <name>\n' >&2
  printf 'pinned plugins:\n' >&2
  canopy_plugin_names 2>/dev/null | while IFS= read -r n; do
    printf '  %s\n' "$n" >&2
  done
  exit 2
fi

name="$1"
case "$name" in
  */* | .* | '')
    canopy_die "vendor.sh: not a plugin name: $name"
    ;;
  *) ;;
esac

pin="$(canopy_plugin_pin "$name")" ||
  canopy_die "vendor.sh: $name is not pinned in plugins/VERSIONS"
url="${pin% *}"
commit="${pin#* }"
[ -n "$url" ] && [ -n "$commit" ] ||
  canopy_die "vendor.sh: plugins/VERSIONS line for $name is missing a url or a commit"

canopy_have git || canopy_die "vendor.sh: git is required to re-vendor a plugin"

dest="$CANOPY_STORE/plugins/$name"
work="$(mktemp -d "${TMPDIR:-/tmp}/canopy-vendor.XXXXXX")" ||
  canopy_die "vendor.sh: could not create a working directory"
trap 'rm -rf "$work"' EXIT INT TERM

printf 'vendoring %s at %s\n' "$name" "$commit"
git clone --quiet "$url" "$work/src" ||
  canopy_die "vendor.sh: could not clone $url"
git -C "$work/src" checkout --quiet "$commit" ||
  canopy_die "vendor.sh: $url has no commit $commit"

# Copy the tree, never the history: no submodule, no nested repository,
# nothing for a later `git submodule update` to reach for. What lands in
# plugins/<name> is ordinary files that canopy's own commit owns.
rm -rf "$work/src/.git"
rm -rf "$dest"
cp -R "$work/src" "$dest"

# One invariant governs everything below: what this script writes must be
# exactly what `git checkout` of canopy reproduces. CHECKSUMS is worthless
# otherwise, because doctor would report every fresh clone as modified.
# Three things in an upstream tree break that invariant, and all three are
# upstream repository plumbing rather than plugin content:
#
#   .gitignore   git honours a nested one, so canopy's own `git add` would
#                silently drop files this script just wrote. resurrect's
#                ignores three paths it also ships.
#   .gitmodules  describes a submodule canopy deliberately does not
#                vendor, and leaving it invites a later `git submodule`
#                command to reach for the network at the worst moment.
#   dangling symlinks and the empty directories under them
#                resurrect ships three links into that un-vendored
#                submodule's mount point. git stores neither a broken link
#                target's directory nor an empty directory, so a clone
#                would not have them.
#
# A symlink whose target exists is kept: continuum ships one, and it
# resolves inside its own tree.
find "$dest" -type f \( -name .gitignore -o -name .gitmodules \) -exec rm -f {} +
find "$dest" -type l | while IFS= read -r link; do
  [ -e "$link" ] || rm -f "$link"
done
# rmdir refuses a non-empty directory, which is exactly the filter wanted,
# and -depth visits children first so a nest of empties collapses in one
# pass. The failures rmdir reports for the directories that do have
# contents are the normal case, not an error.
find "$dest" -depth -type d -exec rmdir {} + 2>/dev/null || true

digest="$(canopy_plugin_digest "$dest")" ||
  canopy_die "vendor.sh: could not digest the vendored tree at $dest"

checksums="$CANOPY_STORE/plugins/CHECKSUMS"
tmp="$checksums.$$"
{
  printf '# Digest of each vendored tree as shipped: <name> <sha256>\n'
  printf '# Written by plugins/vendor.sh; doctor compares the tree on disk\n'
  printf '# against it. See lib/plugins.sh for how the digest is formed.\n'
  # Sorted, so re-vendoring one plugin moves one line's content and never
  # the order of the rest: a diff that only shows what changed is a diff
  # a reviewer will actually read.
  {
    if [ -f "$checksums" ]; then
      awk -v n="$name" 'NF > 0 && substr($1, 1, 1) != "#" && $1 != n { print }' "$checksums"
    fi
    printf '%s %s\n' "$name" "$digest"
  } | LC_ALL=C sort
} >"$tmp"
mv "$tmp" "$checksums"

printf 'vendored %s -> plugins/%s (%s)\n' "$url" "$name" "$digest"

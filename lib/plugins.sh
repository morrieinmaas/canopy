# shellcheck shell=sh
# shellcheck disable=SC2154  # CANOPY_STORE is exported by lib/env.sh's canopy_paths
# shellcheck disable=SC3043  # `local` is explicitly permitted (plan's Global Constraints): universally supported by dash/ash/bash, used here so callers never see this file's internals

# The vendored plugin store.
#
# Two files describe it, and they answer different questions:
#
#   plugins/VERSIONS   <name> <upstream-url> <commit>
#     Where each tree came from. This is the provenance record, and the
#     input to plugins/vendor.sh when a tree has to be produced again.
#
#   plugins/CHECKSUMS  <name> <digest>
#     What each tree looked like when it was vendored. This is what lets
#     doctor say "modified" rather than only "present", and it is a
#     separate file deliberately: VERSIONS is a three-column contract that
#     other tasks in this milestone read, and widening it to carry a
#     fourth, generated column is how a format drifts away from the thing
#     that documents it.
#
# Neither file is consulted at tmux render time. The layer that loads the
# plugins names their paths directly.

# canopy_plugin_names
# Every plugin named in VERSIONS, one per line, in file order.
canopy_plugin_names() {
  local file
  file="$CANOPY_STORE/plugins/VERSIONS"
  [ -f "$file" ] || return 1
  awk 'NF > 0 && substr($1, 1, 1) != "#" { print $1 }' "$file"
}

# canopy_plugin_pin <name>
# Prints "<url> <commit>" for one plugin, or returns 1 if it is not pinned.
canopy_plugin_pin() {
  local file
  file="$CANOPY_STORE/plugins/VERSIONS"
  [ -f "$file" ] || return 1
  awk -v n="$1" '
    NF > 0 && substr($1, 1, 1) != "#" && $1 == n { print $2, $3; found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# canopy_plugin_recorded_digest <name>
# The digest CHECKSUMS holds for one plugin, or 1 if it holds none.
canopy_plugin_recorded_digest() {
  local file
  file="$CANOPY_STORE/plugins/CHECKSUMS"
  [ -f "$file" ] || return 1
  awk -v n="$1" '
    NF > 0 && substr($1, 1, 1) != "#" && $1 == n { print $2; found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# canopy_plugin_digest <dir>
# One sha256 over the whole tree: every regular file, in C-collated path
# order, contributing its own hash, its path, and whether it is
# executable. The executable bit is in there because a vendored .tmux
# entry point that lost its +x is a tree that no longer works, and a
# digest that only covered content would call that tree unmodified.
#
# Nothing about the enclosing directory's name is hashed, so a tree stays
# comparable after it is copied somewhere else, which is what lets a test
# assert on a copy and doctor assert on the store.
canopy_plugin_digest() {
  local dir
  dir="$1"
  [ -d "$dir" ] || return 1
  (
    cd "$dir" || exit 1
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      # The mode flag goes through %s rather than being written into the
      # format string: a format string of "- " is a leading dash, and
      # bash's printf reads that as an option and fails.
      if [ -x "$f" ]; then
        mode=x
      else
        mode=-
      fi
      printf '%s %s %s\n' "$mode" "$(canopy_sha256 "$f")" "${f#./}"
    done
  ) | canopy_sha256
}

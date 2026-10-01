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

# The plugin loader: what TPM's tpm script does for a plugin, without the
# clone, the update, or anything else that reaches the network. 30-plugins.conf
# (and the grofe plugin fragment) call canopy_load_plugins once, with the
# fixed list in load order, at server start and again on every reload.
#
# It runs as the body of a run-shell, so it talks to whichever server ran it
# through `tmux` on PATH, the same way every plugin's own script does. That is
# also why nothing here is tmux specific: grofe answering to the tmux name
# runs it unchanged.

# Where a load pass records the plugins it could not load. canopy doctor's
# reasons for a dormant plugin come from its own checks; this file says
# which plugins the last load actually skipped, and why.
canopy_plugin_log() {
  printf '%s/plugins.log\n' "${CANOPY_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/canopy}"
}

canopy_plugin_note() {
  printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" \
    >>"$(canopy_plugin_log)" 2>/dev/null || true
}

# canopy_load_plugin <name> [<entry-glob>]
#
# TPM's convention for the entry point: every top-level *.tmux file in the
# plugin's root, run in glob order. Each runs through `tmux run-shell`, as
# 30-plugins.conf ran resurrect and continuum before this loop existed, with
# its output discarded as TPM discards it. A plugin with no bash or no
# executable entry point is dormant: nothing on the status line, one log
# line. A plugin whose entry point fails is logged too, and does not stop
# the plugins after it.
canopy_load_plugin() {
  local name glob dir entry found
  name="$1"
  glob="${2:-*.tmux}"
  dir="$CANOPY_STORE/plugins/$name"
  if ! command -v bash >/dev/null 2>&1; then
    canopy_plugin_note "$name" "dormant, bash not found"
    return 0
  fi
  found=0
  # The glob is the point here: it is expanded, never quoted.
  # shellcheck disable=SC2086
  for entry in "$dir"/$glob; do
    [ -f "$entry" ] && [ -x "$entry" ] || continue
    found=1
    if ! tmux run-shell "'$entry'" >/dev/null 2>&1; then
      canopy_plugin_note "$name" "entry point ${entry##*/} failed"
    fi
  done
  if [ "$found" -eq 0 ]; then
    canopy_plugin_note "$name" "dormant, no executable $glob in $dir"
  fi
  return 0
}

# canopy_load_plugins <name>...
#
# One load pass, in the order given. The log is started afresh, so it
# describes the last load and nothing older.
#
# A server with @canopy_plugins set to off loads none and leaves the log
# alone. canopy's own scratch servers set it (lib/tmux.sh): they exist to
# check that the config loads, and a plugin's load writes outside the
# server, into $HOME and /tmp, which `canopy install` validating its entry
# point must not do to a home it promises to restore exactly.
canopy_load_plugins() {
  local log name
  if [ "$(tmux show-option -gqv @canopy_plugins 2>/dev/null)" = off ]; then
    return 0
  fi
  log="$(canopy_plugin_log)"
  mkdir -p "${log%/*}" 2>/dev/null && : >"$log" 2>/dev/null
  for name in "$@"; do
    canopy_load_plugin "$name"
  done
  return 0
}

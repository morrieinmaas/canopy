# shellcheck shell=sh

# canopy_grofe_validate <dir> [<file>...]
# Loads every fragment in <dir>, in the order grofe reads conf.d, then each
# <file> after them (a user.toml, say), with `grofe show-config --file`, and
# fails if grofe reports any error or skips any file. Prints grofe's own
# errors to stderr.
#
# This is the grofe replacement for canopy_tmux_validate. There is no server
# to start and nothing to kill: show-config resolves the config on its own
# and exits, with an exit status that means what it says, which is exactly
# what the throwaway tmux server (sleep 600, a socket, a grep for "invalid")
# was approximating.
#
# XDG_CONFIG_HOME points at an empty directory for the run, so the tree is
# checked on its own, not merged with whatever this machine has in
# ~/.config/grofe. A skipped file counts as a failure: a fragment grofe
# refused for its `requires` header is a fragment that did not load.
#
# $CANOPY_GROFE names the grofe binary; the default is grofe on PATH.
canopy_grofe_validate() {
  canopy_grofe_dir="$1"
  shift
  canopy_grofe_bin="${CANOPY_GROFE:-grofe}"
  if ! command -v "$canopy_grofe_bin" >/dev/null 2>&1; then
    printf 'canopy_grofe_validate: %s not found on PATH\n' "$canopy_grofe_bin" >&2
    return 1
  fi
  if [ ! -d "$canopy_grofe_dir" ]; then
    printf 'canopy_grofe_validate: no such directory: %s\n' "$canopy_grofe_dir" >&2
    return 1
  fi

  # The extra files come first in "$@"; each fragment is appended, then
  # the extras are rotated round to the end, so they load last.
  canopy_grofe_extras=$#
  canopy_grofe_found=0
  for canopy_grofe_f in "$canopy_grofe_dir"/*.toml; do
    [ -f "$canopy_grofe_f" ] || continue
    set -- "$@" --file "$canopy_grofe_f"
    canopy_grofe_found=1
  done
  if [ "$canopy_grofe_found" -eq 0 ]; then
    printf 'canopy_grofe_validate: no fragments in %s\n' "$canopy_grofe_dir" >&2
    return 1
  fi
  while [ "$canopy_grofe_extras" -gt 0 ]; do
    set -- "$@" --file "$1"
    shift
    canopy_grofe_extras=$((canopy_grofe_extras - 1))
  done

  canopy_grofe_xdg="$(mktemp -d)" || return 1
  canopy_grofe_rc=0
  canopy_grofe_err="$(XDG_CONFIG_HOME="$canopy_grofe_xdg" \
    "$canopy_grofe_bin" show-config "$@" 2>&1 >/dev/null)" || canopy_grofe_rc=$?
  rmdir "$canopy_grofe_xdg" 2>/dev/null || true

  if [ "$canopy_grofe_rc" -ne 0 ] || [ -n "$canopy_grofe_err" ]; then
    [ -n "$canopy_grofe_err" ] && printf '%s\n' "$canopy_grofe_err" >&2
    return 1
  fi
  return 0
}

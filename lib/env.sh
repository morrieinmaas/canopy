# shellcheck shell=sh

# canopy_require_absolute <name> <value>
# Rejects a relative path, rather than absolutising it. canopy records
# these paths verbatim into a transaction manifest that outlives the
# process, and $tx/restore.sh resolves manifest paths against whatever
# directory it is later run from, so a relative value would produce a
# restore point that names a different file than the one canopy backed
# up. Absolutising would have to pick a cwd on the user's behalf, and
# canopy cannot know which one was meant; the XDG base directory spec
# calls a relative value invalid too. An empty value is not relative, it
# means unset, and falls through to the default below.
canopy_require_absolute() {
  case "$2" in
    '' | /*) ;;
    *) canopy_die "$1 must be an absolute path, got: $2" ;;
  esac
}

canopy_paths() {
  canopy_require_absolute XDG_CONFIG_HOME "${XDG_CONFIG_HOME-}"
  canopy_require_absolute XDG_STATE_HOME "${XDG_STATE_HOME-}"
  canopy_require_absolute XDG_RUNTIME_DIR "${XDG_RUNTIME_DIR-}"
  : "${CANOPY_STORE:=$(cd "$(dirname "$0")/.." && pwd)}"
  : "${CANOPY_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/canopy}"
  : "${CANOPY_STATE:=${XDG_STATE_HOME:-$HOME/.local/state}/canopy}"
  : "${CANOPY_RUNTIME:=${XDG_RUNTIME_DIR:-/tmp}/canopy}"
  canopy_require_absolute CANOPY_STORE "$CANOPY_STORE"
  canopy_require_absolute CANOPY_CONFIG "$CANOPY_CONFIG"
  canopy_require_absolute CANOPY_STATE "$CANOPY_STATE"
  canopy_require_absolute CANOPY_RUNTIME "$CANOPY_RUNTIME"
  export CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
}

canopy_have() { command -v "$1" >/dev/null 2>&1; }

canopy_sha256() {
  if canopy_have sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  elif canopy_have shasum; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else canopy_die "no sha256 tool found (need sha256sum or shasum)"; fi
}

canopy_die() {
  printf 'canopy: %s\n' "$1" >&2
  exit 1
}

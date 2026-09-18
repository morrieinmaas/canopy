# shellcheck shell=sh
canopy_paths() {
  : "${CANOPY_STORE:=$(cd "$(dirname "$0")/.." && pwd)}"
  : "${CANOPY_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/canopy}"
  : "${CANOPY_STATE:=${XDG_STATE_HOME:-$HOME/.local/state}/canopy}"
  : "${CANOPY_RUNTIME:=${XDG_RUNTIME_DIR:-/tmp}/canopy}"
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

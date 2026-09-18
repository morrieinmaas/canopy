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
  # XDG_RUNTIME_DIR is per-user by spec, so a directory under it can carry
  # canopy's plain name. /tmp is not: it is shared by every account on the
  # machine, and a plain /tmp/canopy belonged to whichever user created it
  # first, mode 755. Every other user's `canopy doctor` then could not
  # write its scratch file there, reported "entry point loads from a bare
  # environment: FAILED" against a perfectly healthy install, and exited
  # 2. The uid in the fallback path is what keeps one account's runtime
  # directory out of another's way.
  if [ -n "${XDG_RUNTIME_DIR-}" ]; then
    : "${CANOPY_RUNTIME:=$XDG_RUNTIME_DIR/canopy}"
  else
    : "${CANOPY_RUNTIME:=/tmp/canopy-$(id -u)}"
  fi
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

# canopy_file_state <path>
# The state canopy records for a path, and compares a path against later:
# the literal string "absent", "symlink:<target>", or the sha256 of the
# file's contents.
#
# A symlink is never followed here. The artifact at a symlinked path is the
# link itself, and the bytes at the other end belong to whoever put them
# there, which is the whole reason chezmoi, stow and bare dotfiles repos
# produce one. Hashing through the link recorded the target's bytes under
# the link's path, so canopy could not tell a replaced link from a
# rewritten target, and restore could not put the link back.
canopy_file_state() {
  if [ -L "$1" ]; then
    printf 'symlink:%s' "$(readlink "$1")"
  elif [ -e "$1" ]; then
    canopy_sha256 "$1"
  else
    printf 'absent'
  fi
}

# canopy_entry_point
# The tmux entry point on this machine, by tmux's own precedence:
# ~/.tmux.conf wins when it exists, else the XDG path. Prints nothing when
# neither exists, which is what "canopy is not installed" looks like.
# Every check of a shipped artifact goes through this path, because it is
# the one a user's tmux goes through.
canopy_entry_point() {
  if [ -f "$HOME/.tmux.conf" ]; then
    printf '%s\n' "$HOME/.tmux.conf"
  elif [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" ]; then
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
  fi
}

canopy_die() {
  printf 'canopy: %s\n' "$1" >&2
  exit 1
}

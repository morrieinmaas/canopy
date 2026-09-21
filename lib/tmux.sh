# shellcheck shell=sh

# canopy_tmux_version_ok
# True (status 0) if the installed tmux is at least the floor version
# (3.4). `tmux -V` prints e.g. "tmux 3.7b" or "tmux next-3.4"; only the
# leading major.minor digits are compared, any letter suffix or "next-"
# prefix is ignored.
canopy_tmux_version_ok() {
  raw="$(tmux -V 2>/dev/null)" || return 1
  ver="$(printf '%s' "$raw" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [ -n "$ver" ] || return 1
  major=${ver%%.*}
  minor=${ver#*.}
  minor=${minor%%.*}
  if [ "$major" -gt 3 ]; then
    return 0
  fi
  [ "$major" -eq 3 ] && [ "$minor" -ge 4 ]
}

# canopy_tmux_validate <conf>
# Loads <conf> on a throwaway, isolated tmux server and reports whether it
# is valid tmux configuration. Returns non-zero with stderr captured if it
# fails.
#
# tmux only surfaces config parse/execution errors to a client that
# attaches: a detached `tmux -f <conf> new-session -d` exits 0 and prints
# nothing even when <conf> contains an unknown command or a broken
# source-file path (verified empirically: such errors are queued and
# shown only once a client attaches). Running `source-file <conf>` as an
# ordinary command against an already-started server executes the same
# directives but reports failure synchronously, so that is what this
# function relies on instead. The throwaway server is started with
# `-f /dev/null` so it never consults a real default config file
# (~/.tmux.conf or $XDG_CONFIG_HOME/tmux/tmux.conf).
# canopy_tmux_bare <tmux-binary> [arg...]
# Runs tmux holding nothing this process holds: env -i, $HOME, a PATH
# minimal enough to still resolve tmux itself, and a named TMUX_TMPDIR.
#
# The environment is the point. tmux expands a variable reference in a
# source-file path from the tmux SERVER's environment, which on a user's
# machine contains no CANOPY_* at all, so a config chain that resolves
# only because the caller exported CANOPY_STORE is a config chain that
# loads nothing for the person who installed it. That is not a
# hypothetical: it shipped, green, past 93 tests.
#
# TMUX_TMPDIR is named rather than inherited so the socket file's path is
# known and can be removed afterwards.
canopy_tmux_bare() {
  canopy_tmux_bin="$1"
  shift
  env -i \
    HOME="$HOME" \
    PATH="${canopy_tmux_bin%/*}:/usr/bin:/bin" \
    TMUX_TMPDIR=/tmp \
    "$canopy_tmux_bin" "$@"
}

# canopy_tmux_validate <conf>
# True when tmux loads <conf> cleanly on a throwaway server started from a
# bare environment. -f /dev/null plus an explicit source-file, rather than
# -f <conf>: a config loaded at server start reports its errors to the
# client and still leaves new-session exiting 0, while source-file as a
# command returns tmux's own verdict.
#
# The scratch session runs `sleep`, not the user's shell. A bare
# `new-session -d` starts whatever login shell the passwd entry names, and
# that shell writes to $HOME when it is killed: on this machine validation
# left a .zsh_history behind in an otherwise untouched home, so `canopy
# install` followed by `canopy restore --all` no longer returned the home
# to its exact prior state. The bug predates the plugin layer and was only
# hidden by timing; the layer's extra second of work gave the shell long
# enough to get its write in. Nothing validation does needs a shell, so it
# no longer starts one. The 600 seconds are slack, not a wait: the server
# is killed a moment later, on every path.
canopy_tmux_validate() {
  conf="$1"
  if [ ! -f "$conf" ]; then
    printf 'canopy_tmux_validate: no such file: %s\n' "$conf" >&2
    return 1
  fi
  if ! tmux_bin="$(command -v tmux)"; then
    printf 'canopy_tmux_validate: tmux not found on PATH\n' >&2
    return 1
  fi
  sock="canopy-verify-$$"
  err="$(canopy_tmux_bare "$tmux_bin" -L "$sock" -f /dev/null new-session -d 'sleep 600' \; source-file "$conf" 2>&1)"
  rc=$?
  canopy_tmux_bare "$tmux_bin" -L "$sock" kill-server >/dev/null 2>&1
  # kill-server stops the server and leaves its socket file behind, one per
  # call; that is how roughly 900 of them piled up under /tmp/tmux-<uid>/.
  rm -f "/tmp/tmux-$(id -u)/$sock"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  return 0
}

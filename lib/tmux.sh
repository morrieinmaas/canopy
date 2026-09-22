# shellcheck shell=sh
# shellcheck disable=SC2154  # CANOPY_RUNTIME is exported by lib/env.sh's canopy_paths

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
# Runs tmux with the four CANOPY_* roots removed from its environment and
# everything else left alone, plus a named TMUX_TMPDIR.
#
# Those four are the whole point. tmux expands a variable reference in a
# source-file path from the tmux SERVER's environment, which on a user's
# machine contains no CANOPY_* at all, so a config chain that resolves
# only because the caller exported CANOPY_STORE is a config chain that
# loads nothing for the person who installed it. That is not a
# hypothetical: it shipped, green, past 93 tests.
#
# It was `env -i` once, which removed everything rather than those four.
# That is a different and much stronger claim than the one this function
# needs to make, and it is false in a common case: a tmux reached through a
# shim (mise, asdf, a distro wrapper) is a program that needs its own
# environment to find the binary it forwards to, and env -i took that away.
# It is how milestone 1's macOS CI broke.
#
# TMUX_TMPDIR is named rather than inherited so the socket file's path is
# known and can be removed afterwards.
canopy_tmux_bare() {
  canopy_tmux_bin="$1"
  shift
  (
    unset CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
    TMUX_TMPDIR=/tmp
    export TMUX_TMPDIR
    exec "$canopy_tmux_bin" "$@"
  )
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
#
# @continuum-restore-max-delay is zeroed before the config is sourced, and
# that line is load bearing. canopy's plugin layer turns continuum's
# restore on, and continuum arms it for any server that started in the
# last few seconds, which every scratch server here did. Left armed, a
# validation run on a machine with no other tmux server would restore the
# user's saved session onto a throwaway socket and start every agent in it
# for the second before the socket is killed. Zero means continuum does
# not consider this server freshly booted, which is the truth.
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
  err="$(canopy_tmux_bare "$tmux_bin" -L "$sock" -f /dev/null new-session -d 'sleep 600' \; set -g @continuum-restore-max-delay 0 \; source-file "$conf" 2>&1)"
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

# canopy_tmux_loaded_option <conf> <option>
# The value <option> holds once tmux has loaded <conf>, read off a
# throwaway server started the same bare way canopy_tmux_validate starts
# one, including the same reason for zeroing @continuum-restore-max-delay.
# Prints nothing and returns non-zero when the server cannot be started.
#
# Asked of the config the machine actually loads, never of the store's own
# layer files. A setting the shipped layer makes can be unmade by
# $CANOPY_CONFIG/user.conf, which the entry point sources last precisely so
# the user's file wins, and a check that only read the store would report
# OK on the one machine where the setting is off.
#
# Sourcing and asking are two invocations, not one chain, and the output
# of each goes to a file rather than into a command substitution. Both are
# load bearing, for the same reason as the note above canopy_tmux_validate:
# a chain that ends in `show` leaves the client waiting when an earlier
# `source-file` fails, and because the scratch session is still holding the
# reader's pipe, the kill-server on the next line cannot run until the
# session's own `sleep 600` expires. That deadlock is not theoretical: it
# hung a CI run for ten minutes after every test had already passed.
#
# Split this way, the risky half is exactly the shape canopy_tmux_validate
# has always used, and `show` only ever runs against a server whose config
# already loaded, where it answers and exits.
canopy_tmux_loaded_option() {
  conf="$1"
  option="$2"
  [ -f "$conf" ] || return 1
  tmux_bin="$(command -v tmux)" || return 1
  canopy_runtime_ensure || return 1
  sock="canopy-option-$$"
  out="$CANOPY_RUNTIME/loaded-option.$$"
  rm -f "$out"

  rc=0
  canopy_tmux_bare "$tmux_bin" -L "$sock" -f /dev/null \
    new-session -d 'sleep 600' \; \
    set -g @continuum-restore-max-delay 0 \; \
    source-file "$conf" >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    canopy_tmux_bare "$tmux_bin" -L "$sock" \
      show -gqv "$option" >"$out" 2>/dev/null || rc=$?
  fi
  canopy_tmux_bare "$tmux_bin" -L "$sock" kill-server >/dev/null 2>&1
  rm -f "/tmp/tmux-$(id -u)/$sock"
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    return 1
  fi
  value="$(cat "$out" 2>/dev/null)" || value=""
  rm -f "$out"
  printf '%s\n' "$value"
}

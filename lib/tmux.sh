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
canopy_tmux_validate() {
  conf="$1"
  if [ ! -f "$conf" ]; then
    printf 'canopy_tmux_validate: no such file: %s\n' "$conf" >&2
    return 1
  fi
  sock="canopy-verify-$$"
  err="$(tmux -L "$sock" -f /dev/null new-session -d \; source-file "$conf" 2>&1)"
  rc=$?
  tmux -L "$sock" kill-server >/dev/null 2>&1
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  return 0
}

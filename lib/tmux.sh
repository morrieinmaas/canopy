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
# canopy_tmux_bare <scratch-dir> <tmux-binary> [arg...]
# Runs tmux with the four CANOPY_* roots removed from its environment and
# everything else left alone, except that every directory a server keeps
# files in is pointed into <scratch-dir>, made by canopy_tmux_scratch_dir.
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
# Every caller is a throwaway server, and a throwaway server must leave
# nothing behind. kill-server leaves the socket file, which is how roughly
# 900 of them piled up under /tmp/tmux-<uid>/. grofe, answering to tmux,
# also keeps a .lock beside the socket under XDG_RUNTIME_DIR and an
# instance directory and a log under XDG_STATE_HOME, deliberately, as a
# real server should. So TMUX_TMPDIR, XDG_RUNTIME_DIR and XDG_STATE_HOME
# all point into the scratch directory, the caller names the socket inside
# it with -S, and removing that one directory removes everything either
# multiplexer wrote.
#
# The directory is made under $CANOPY_SCRATCH_TMPDIR, /tmp unless something
# names another. The test suite names one inside its own root (test/helper.bash)
# because its tmux shim refuses any call naming a socket outside it: a scratch
# server under /tmp would be refused, and the config validation it exists to
# perform would fail for a reason that has nothing to do with the config.
canopy_tmux_bare() {
  canopy_tmux_scratch="$1"
  canopy_tmux_bin="$2"
  shift 2
  (
    unset CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
    TMUX_TMPDIR="$canopy_tmux_scratch"
    XDG_RUNTIME_DIR="$canopy_tmux_scratch/run"
    XDG_STATE_HOME="$canopy_tmux_scratch/state"
    export TMUX_TMPDIR XDG_RUNTIME_DIR XDG_STATE_HOME
    exec "$canopy_tmux_bin" "$@"
  )
}

# canopy_tmux_scratch_dir
# Makes and prints a private directory for one throwaway server, with the
# run and state directories canopy_tmux_bare points it at. Under /tmp
# rather than $TMPDIR because the socket lives in it, and a socket path
# has a length limit (104 bytes on macOS) that macOS's $TMPDIR alone
# takes half of.
canopy_tmux_scratch_dir() {
  canopy_tmux_dir="$(mktemp -d "${CANOPY_SCRATCH_TMPDIR:-/tmp}/canopy-tmux.XXXXXX")" || return 1
  (umask 077 && mkdir "$canopy_tmux_dir/run" "$canopy_tmux_dir/state") || {
    rm -rf "$canopy_tmux_dir"
    return 1
  }
  printf '%s' "$canopy_tmux_dir"
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
#
# @canopy_plugins off keeps the plugin loader from running any plugin on
# the scratch server, for the same kind of reason: their loads write to
# $HOME and /tmp, and validating must leave the home as it found it.
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
  if ! scratch="$(canopy_tmux_scratch_dir)"; then
    printf 'canopy_tmux_validate: cannot make a scratch directory under %s\n' "${CANOPY_SCRATCH_TMPDIR:-/tmp}" >&2
    return 1
  fi
  sock="$scratch/socket"
  # @canopy_skip_server_path, for the same class of reason as the
  # @continuum-restore-max-delay above it: a throwaway server exists to
  # parse a config, not to run jobs in. 00-core's PATH correction would
  # otherwise fire here, and `new-session -d` returns before the queued
  # run-shell finishes, so the kill-server two lines down lands first and
  # the job's next `tmux` call auto-starts a FRESH server on the socket
  # just removed. The socket that leaves behind is short-lived and so was
  # the test for it: intermittent, and blamed on everything but this.
  err="$(canopy_tmux_bare "$scratch" "$tmux_bin" -S "$sock" -f /dev/null new-session -d 'sleep 600' \; set -g @continuum-restore-max-delay 0 \; set -g @canopy_plugins off \; set -g @canopy_skip_server_path 1 \; source-file "$conf" 2>&1)"
  rc=$?
  canopy_tmux_bare "$scratch" "$tmux_bin" -S "$sock" kill-server >/dev/null 2>&1
  rm -rf "$scratch"
  # Anything tmux said counts as a failure, even when it exited 0.
  #
  # tmux does not report a sourced file's errors through the exit status
  # as reliably as it looks. A glob source-file returns success as long as
  # something matched, whatever the matched files contained, and a
  # `run-shell` anywhere in a layer passes through the command queue and
  # resets the status of the source-file running it, so every error in
  # every later layer stops being counted. Both were found here: a status
  # layer with one `run-shell` in it made `canopy install` accept a config
  # holding a syntax error, which is the exact failure this function is
  # the only guard against.
  #
  # What tmux does do reliably is PRINT the error. So the output is the
  # other half of the verdict, but only the part of it that looks like an
  # error: source-file also prints the ordinary output of every command it
  # runs, on the same stream. Treating any output as failure rejected a
  # user.conf holding `run-shell "echo hi"`, which is how people load a
  # plugin by hand, and refused to install a config that loads perfectly.
  # Splitting the streams does not help; tmux writes both to stdout.
  #
  # The shapes below are all of tmux's own, confirmed by producing each:
  #
  #   conf:12: unknown command: nonsense     a file and line, for syntax
  #   invalid option: not-an-option          no file or line
  #   unknown value: bogus                   no file or line
  #
  # The middle one is why matching only "file:line:" is not enough: that
  # is precisely the shape tmux 3.4 produced for extended-keys-format, the
  # error that would have shipped an unusable config to every 3.4 machine.
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  if printf '%s\n' "$err" |
    grep -qE '(^|[^[:alnum:]])(invalid|unknown|ambiguous) (option|value|command|key)|:[0-9]+: '; then
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
  scratch="$(canopy_tmux_scratch_dir)" || return 1
  sock="$scratch/socket"
  out="$CANOPY_RUNTIME/loaded-option.$$"
  rm -f "$out"

  rc=0
  canopy_tmux_bare "$scratch" "$tmux_bin" -S "$sock" -f /dev/null \
    new-session -d 'sleep 600' \; \
    set -g @continuum-restore-max-delay 0 \; set -g @canopy_plugins off \; \
    set -g @canopy_skip_server_path 1 \; \
    source-file "$conf" >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    canopy_tmux_bare "$scratch" "$tmux_bin" -S "$sock" \
      show -gqv "$option" >"$out" 2>/dev/null || rc=$?
  fi
  canopy_tmux_bare "$scratch" "$tmux_bin" -S "$sock" kill-server >/dev/null 2>&1
  rm -rf "$scratch"
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    return 1
  fi
  value="$(cat "$out" 2>/dev/null)" || value=""
  rm -f "$out"
  printf '%s\n' "$value"
}

# canopy_tmux_server_binary
# Prints the absolute path of the binary the RUNNING server was started
# from, or nothing (status 1) when it cannot be determined.
#
# Asked of the process rather than of $PATH, because the whole point of
# every caller is that $PATH may be lying. Whichever tmux a job resolves
# can be a version-manager shim, a wrapper, or a second installation at a
# different version; the server's own executable is the only authority on
# what this server is.
#
# Three sources, cheapest first, because none of them answers everywhere:
# /proc/<pid>/exe is the kernel's own answer and does not exist on macOS;
# `ps -o comm=` is 3ms and prints a full path on macOS, but only when the
# server was exec'd with one (a server started as bare `tmux` reports just
# "tmux", and on Linux that field is the truncated command name either
# way); lsof's text-segment entry is 29ms and reports the executable
# actually mapped, whatever argv[0] claimed.
canopy_tmux_server_binary() {
  canopy_server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null)" || return 1
  case "$canopy_server_pid" in
    '' | *[!0-9]*) return 1 ;;
    *) ;;
  esac

  canopy_server_bin=''

  if [ -r "/proc/$canopy_server_pid/exe" ]; then
    canopy_server_bin="$(readlink -f "/proc/$canopy_server_pid/exe" 2>/dev/null || true)"
  fi

  # Taken only when it is absolute, rather than trusted on sight.
  if [ -z "$canopy_server_bin" ]; then
    canopy_server_bin="$(ps -o comm= -p "$canopy_server_pid" 2>/dev/null || true)"
    case "$canopy_server_bin" in
      /*) ;;
      *) canopy_server_bin='' ;;
    esac
  fi

  if [ -z "$canopy_server_bin" ] && command -v lsof >/dev/null 2>&1; then
    canopy_server_bin="$(lsof -p "$canopy_server_pid" -a -d txt -Fn 2>/dev/null |
      sed -n 's/^n//p' | head -n 1)"
  fi

  case "$canopy_server_bin" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -x "$canopy_server_bin" ] || return 1
  printf '%s' "$canopy_server_bin"
}

# canopy_tmux_grofe_version
# Prints grofe's own version and returns 0 when the server a bare `tmux`
# reaches is grofe, the multiplexer that answers to the name tmux. Returns 1
# for a real tmux server, and for no server at all.
#
# Not from `tmux -V`. grofe run under the tmux name gives tmux's identity
# all the way down: `-V` prints tmux's compat level (`tmux 3.7b`), and so do
# #{version} and TERM_PROGRAM_VERSION. What it keeps is #{grofe_version},
# which grofe expands under either identity, and which real tmux, like every
# variable it does not know, expands to the empty string. So the question is
# asked of the running server, and the answer is exact on both.
canopy_tmux_grofe_version() {
  canopy_grofe_version="$(tmux display-message -p '#{grofe_version}' 2>/dev/null)" || return 1
  [ -n "$canopy_grofe_version" ] || return 1
  printf '%s' "$canopy_grofe_version"
}

# canopy_grofe_binary
# Prints the path of a grofe binary to run grofe's own verbs with, or
# returns 1 when there is none.
#
# Needed because grofe's own verbs, `reboot-check` among them, exist only
# under the name grofe: under the tmux name grofe is tmux's CLI, and tmux
# has no such command. So the `tmux` canopy calls everywhere else cannot
# be used, and the binary has to be reached by its real name.
#
# $CANOPY_GROFE wins when it is set, and is then the only candidate: an
# override that quietly fell back to something else would be no override.
# Otherwise the running server's own executable, resolved through any
# symlink, because the server is the authority on which grofe it is; taken
# only when its name is grofe, since on macOS the process table can report
# the `tmux` symlink the server was started through. Then grofe on PATH.
canopy_grofe_binary() {
  if [ -n "${CANOPY_GROFE:-}" ]; then
    [ -x "$CANOPY_GROFE" ] || return 1
    printf '%s' "$CANOPY_GROFE"
    return 0
  fi
  # shellcheck disable=SC2310  # a question, so a non-zero return is the answer and not a failure to abort on
  if canopy_grofe_candidate="$(canopy_tmux_server_binary)"; then
    canopy_grofe_resolved="$(readlink -f "$canopy_grofe_candidate" 2>/dev/null || true)"
    [ -n "$canopy_grofe_resolved" ] || canopy_grofe_resolved="$canopy_grofe_candidate"
    case "${canopy_grofe_resolved##*/}" in
      grofe)
        printf '%s' "$canopy_grofe_resolved"
        return 0
        ;;
      *) ;;
    esac
  fi
  canopy_grofe_candidate="$(command -v grofe 2>/dev/null)" || return 1
  printf '%s' "$canopy_grofe_candidate"
}

# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` is explicitly permitted (plan's Global Constraints): universally supported by dash/ash/bash, used here so callers never see this file's internals

# The stagger wrapper that canopy puts in front of a saved resume command.
#
# Ten agent panes restored at once launch ten agents at once, and an agent
# is not a cheap process. The command resurrect saves therefore carries a
# small wait in front of it, so the launches spread out instead of landing
# together on a machine that has just finished booting.
#
# The wrapper ends up in the command line a human may later read in the
# save file, or type again by hand. That is why it is a plain `sleep` and
# an `&&`: whoever reads it should need no explanation and no lookup.
#
# The functions here are written together because they have to agree about
# that shape. One emits the wrapper, the other takes it back off.

# canopy_resume_stagger_prefix <pane pid> <@canopy_resume_stagger_ms>
# Prints the wrapper for that pane, or nothing at all when the option is
# exactly 0, which is how the feature is turned off rather than left
# emitting a wrapper that waits for nothing. An unset option, or one
# holding something that is not a number, takes the shipped default: there
# is nobody to report a bad value to from inside a save.
canopy_resume_stagger_prefix() {
  local bound delay
  # Long enough that ten panes come up about a tenth of a second apart,
  # short enough that a single restored pane is not noticeably late.
  bound=1000
  case "${2-}" in
    '' | *[!0-9]*) ;;
    *) bound="$2" ;;
  esac
  [ "$bound" -gt 0 ] || return 0
  case "${1-}" in
    '' | *[!0-9]*) return 0 ;;
    *) ;;
  esac

  # The pid is multiplied by a prime before the modulo because panes opened
  # together get consecutive pids: taking the pid modulo the bound directly
  # would hand ten panes ten waits within a few milliseconds of each other,
  # which is the herd this exists to break up. The pid is reduced first so
  # the product cannot overflow a 32 bit shell's arithmetic.
  delay=$(((($1 % 100000) * 7919) % bound + 1))
  printf 'sleep %d.%03d && ' "$((delay / 1000))" "$((delay % 1000))"
}

# canopy_resume_stagger_strip <command>
# The command without its wrapper, for a caller comparing a saved command
# against the resume command it should hold.
canopy_resume_stagger_strip() {
  case "$1" in
    'sleep '*' && '*) printf '%s\n' "${1#*' && '}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

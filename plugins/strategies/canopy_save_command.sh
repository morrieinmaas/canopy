#!/bin/sh
# canopy's save-command strategy for tmux-resurrect.
#
# resurrect asks a save-command strategy one question, once per pane, every
# time it saves: "what command should I record for this pane?" It hands over
# the pane's pid and reads one line from stdout. Upstream's own answer, the
# `ps` strategy, is whatever child the pane's shell has, recorded verbatim.
#
# Verbatim is wrong for exactly one kind of pane. `claude --session-id
# <uuid>` replayed after a reboot does not continue that conversation: it
# asks for a NEW one under an id that is already taken. The pane comes back
# and the work in it does not, which is the single failure this milestone
# exists to prevent. So for a pane canopy knows is holding an agent session,
# this strategy answers with that adapter's resume command instead, built
# from the session id the agent itself reported.
#
# The id comes off the pane's own options rather than out of the command
# line the agent was launched with. That is the whole reason this design was
# chosen over pinning an id at launch: an agent that cannot be handed an id
# when it starts is still resumable, because canopy learns the id from the
# agent's report and never needs it to have been on the command line.
#
# EVERYTHING ELSE MUST COME OUT UNCHANGED. This runs inside resurrect's save
# path, on every pane of every session, every time continuum fires. A line
# this script gets wrong is a pane that comes back as a bare shell, and a
# line it fails to print at all is the same thing. So every path that is not
# a recognised agent pane, including every error path, ends in
# canopy_save_default: resurrect's own strategy, run on the same pid, its
# output passed through untouched. A missing adapter, a malformed manifest,
# a tmux that will not answer, a store that has moved: all of them are a
# fallback, never a partial command and never an empty one.
set -u

pane_pid="${1-}"

# Where this file is, not where the environment says canopy is. A strategy
# runs as a plain child of resurrect's save script, which the tmux server
# runs, and the server's environment is whatever it was started with:
# $CANOPY_STORE may be in it, may be stale, may be missing. This file's own
# location is none of those things.
store="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" || store=""

canopy_save_default() {
  [ -n "$store" ] || exit 0
  default="$store/plugins/tmux-resurrect/save_command_strategies/ps.sh"
  [ -x "$default" ] || exit 0
  exec "$default" "$pane_pid"
}

# Prints the resume command for the pane holding $pane_pid, or fails. Run
# inside a command substitution, so a canopy_die in any library it loads,
# or an unset variable under set -u, ends this lookup and not the save.
canopy_save_resume_command() {
  [ -n "$pane_pid" ] || return 1
  [ -n "$store" ] || return 1

  for lib in env.sh adapter.sh pane.sh; do
    [ -r "$store/lib/$lib" ] || return 1
  done
  # shellcheck source=../../lib/env.sh
  # shellcheck disable=SC1091
  . "$store/lib/env.sh"
  # shellcheck source=../../lib/adapter.sh
  # shellcheck disable=SC1091
  . "$store/lib/adapter.sh"
  # shellcheck source=../../lib/pane.sh
  # shellcheck disable=SC1091
  . "$store/lib/pane.sh"
  # Set before canopy_paths rather than left to it: canopy_paths derives an
  # unset store from its caller's own directory, and this caller lives two
  # levels down from one.
  CANOPY_STORE="$store"
  export CANOPY_STORE
  canopy_paths

  # One tmux call for the whole server: the pid resurrect named, the pane it
  # belongs to, and what that pane has reported about itself. The separator
  # is the one `canopy agent report` already refuses to accept inside either
  # value, and the session id is last so that a value carrying one anyway
  # cannot shift the fields before it.
  panes="$(tmux list-panes -a -F \
    '#{pane_pid}|#{pane_id}|#{@canopy_agent_source}|#{@canopy_agent_session}' \
    2>/dev/null)" || return 1

  pane=""
  adapter=""
  session=""
  while IFS='|' read -r line_pid line_pane line_source line_session; do
    [ "$line_pid" = "$pane_pid" ] || continue
    pane="$line_pane"
    adapter="$line_source"
    session="$line_session"
    break
  done <<EOF
$panes
EOF

  # No session id means no conversation to resume, whatever else the pane
  # may be running. That is most panes, and they all end up here.
  [ -n "$session" ] || return 1

  # A session id with no source beside it: the three options are written by
  # more than one caller, and a hook that reports only a state leaves the
  # source empty. The pane is still resumable, so ask the same lookup every
  # other canopy command uses which agent it is running. It reads the pane's
  # start command and falls back to the running process, because a restored
  # pane has the second and not the first.
  if [ -z "$adapter" ]; then
    adapter="$(canopy_pane_adapter "$pane" 2>/dev/null)" || return 1
  fi
  [ -n "$adapter" ] || return 1

  out="$(canopy_adapter_resume_command "$adapter" "$session" 2>/dev/null)" || return 1

  # resurrect's save file is tab delimited and one line per pane. A command
  # carrying a control character would not come back as itself; it would
  # take the rest of the file's shape with it.
  case "$out" in
    '' | *[[:cntrl:]]*) return 1 ;;
    *) ;;
  esac

  printf '%s\n' "$out"
}

if resumed="$(canopy_save_resume_command 2>/dev/null)" && [ -n "$resumed" ]; then
  printf '%s\n' "$resumed"
else
  canopy_save_default
fi

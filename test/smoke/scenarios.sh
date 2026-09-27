#!/bin/sh
# canopy acceptance scenarios, run INSIDE a smoke container.
#
# Every scenario acts exactly as a user does: no CANOPY_* anywhere in the
# environment, no test helper sourced, the shipped canopy on PATH, and a
# $HOME that starts as the machine the scenario is meant to represent.
# Milestone 1 reached 93 green tests and a passing restore proof while the
# configuration it installed loaded nothing on a real machine, because
# every test exported CANOPY_STORE before invoking anything. The rule this
# file enforces is that a verification runs the shipped artifact through
# the same entry path a user does, from a bare environment.
#
# Output contract, consumed by run.sh:
#   RESULT<TAB><id><TAB>PASS|FAIL<TAB><name>   one line per scenario
#   SCENARIOS-COMPLETE <count>                 last line, only on a full run
# Everything else is free-form detail. A failing assertion prints what it
# expected and what it observed; a harness that says FAIL without saying
# what it wanted is not worth having.
set -eu

store=/canopy
root=/smoke

overall_failed=0
scenario_failed=0
scenario_id=""
scenario_name=""
scenario_count=0
work=""
home=""
tmux_seq=0
last_status=0
last_output=""

# --- the bare environment this whole file is about -------------------------

unset CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME || :
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_RUNTIME_DIR || :

leaked="$(env | grep '^CANOPY_' || :)"
if [ -n "${leaked}" ]; then
  printf 'scenarios.sh: refusing to run, CANOPY_* is set in the environment:\n%s\n' "${leaked}" >&2
  exit 1
fi

# --- assertions ------------------------------------------------------------

# capture <command> [arg...]
# Runs a command the way a user runs it, keeping its exit status in
# $last_status and its combined output in $last_output instead of letting
# set -e abort the scenario. Works on shell functions as well as binaries.
capture() {
  last_status=0
  last_output="$("$@" 2>&1)" || last_status=$?
}

# fail <assertion> <expected> <observed>
fail() {
  scenario_failed=1
  printf '  FAIL  %s\n' "$1"
  printf '        expected: %s\n' "$2"
  printf '        observed: %s\n' "$3"
}

# check <assertion> <expected> <observed>
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    fail "$1" "$2" "$3"
  fi
  return 0
}

# check_contains <assertion> <needle> <haystack>
check_contains() {
  case "$3" in
    *"$2"*) printf '  ok    %s\n' "$1" ;;
    *) fail "$1" "text containing: $2" "$3" ;;
  esac
  return 0
}

# check_files <assertion> <expected-file> <observed-file>
# Reports the unified diff on failure, indented, so the exact rows that
# moved are in the report rather than a bare "they differ".
check_files() {
  if diff_out="$(diff -u "$2" "$3")"; then
    printf '  ok    %s\n' "$1"
    return 0
  fi
  scenario_failed=1
  printf '  FAIL  %s\n' "$1"
  printf '        expected: the recorded snapshot, line for line\n'
  printf '        observed: differences (- expected, + observed)\n'
  printf '%s\n' "${diff_out}" | while IFS= read -r diff_line; do
    printf '          %s\n' "${diff_line}"
  done
  return 0
}

# yesno <test> [arg...]
# "yes" or "no" for a condition, so a check() can name it and print what
# it observed. Called as: yesno test -L "${path}"
yesno() {
  if "$@"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# --- snapshots -------------------------------------------------------------

# snapshot <root> <out>
# One tab-separated line per path under <root>, sorted:
#   d<TAB><path>              a directory
#   f<TAB><path><TAB><sha>    a regular file, and the sha256 of its bytes
#   l<TAB><path><TAB><target> a symlink, and the target it names
#   ?<TAB><path>              anything else
#
# -L is asked first, so a symlink is recorded as the link it is and never
# followed: a symlink to a directory is not a directory here, and a
# dangling one is still a row rather than a gap. Directories are in the
# listing on purpose; a directory canopy creates and restore leaves behind
# is a survived artifact, and a file-only listing would miss it.
snapshot() {
  find "$1" | sort | while IFS= read -r snap_path; do
    if [ -L "${snap_path}" ]; then
      printf 'l\t%s\t%s\n' "${snap_path}" "$(readlink "${snap_path}")"
    elif [ -d "${snap_path}" ]; then
      printf 'd\t%s\n' "${snap_path}"
    elif [ -f "${snap_path}" ]; then
      printf 'f\t%s\t%s\n' "${snap_path}" "$(sha256sum "${snap_path}" | cut -d' ' -f1)"
    else
      printf '?\t%s\n' "${snap_path}"
    fi
  done >"$2"
}

# without_state <snapshot-in> <home> <snapshot-out>
# Drops canopy's own state tree, and the ancestor directories that exist
# only to hold it, from a snapshot.
#
# This is not a convenience, it is the one honest exception. $CANOPY_STATE
# holds the restore points, and canopy's headline promise is that the
# pre-install restore point stays reachable forever, so restore must not
# remove the tree holding it. On the default layout that tree sits at
# ~/.local/state/canopy, INSIDE $HOME, so a literal `find "$HOME" | sort`
# can never match its pre-install self after a restore, by design. What
# the scenarios assert instead is stricter than it sounds: everything
# outside that single tree must match exactly, which makes the state tree
# the only thing allowed to survive, and assert_home_restored separately
# asserts it really is there rather than letting the filter hide an empty
# pass.
without_state() {
  awk -F'\t' -v s="$2/.local/state/canopy" '
    function related(p, base) {
      if (p == base) return 1
      if (substr(p, 1, length(base) + 1) == base "/") return 1
      if (substr(base, 1, length(p) + 1) == p "/") return 1
      return 0
    }
    !related($2, s) { print }
  ' "$1" >"$3"
}

# --- tmux, from an environment holding nothing this script holds -----------

# Exactly the four CANOPY_* roots are removed and nothing else, matching
# canopy_tmux_bare in lib/tmux.sh. `env -i` used to empty the environment
# outright, which is a stronger claim than this needs and a false one for a
# tmux reached through a version-manager shim: such a wrapper needs its own
# environment to find the binary it forwards to.
# shellcheck disable=SC2317,SC2329  # reached only through capture(), which invokes it by name
bare_tmux() {
  bare_bin="$1"
  shift
  (
    unset CANOPY_STORE CANOPY_CONFIG CANOPY_STATE CANOPY_RUNTIME
    TMUX_TMPDIR=/tmp
    export TMUX_TMPDIR
    exec "${bare_bin}" "$@"
  )
}

# tmux_option <entry-point> <option>
# Starts tmux on a throwaway socket, loads <entry-point> the way a user's
# tmux loads it, and prints the value of <option>. The environment is the
# point: nothing puts CANOPY_* into a tmux server on a real machine, so a
# config chain that resolves only because the caller exported CANOPY_STORE
# is a config chain that loads nothing for the person who installed it.
# shellcheck disable=SC2317,SC2329  # reached only through capture(), which invokes it by name
# shellcheck disable=SC2310  # every failure here is the answer this function reports, not a reason to abort
tmux_option() {
  tmux_bin="$(command -v tmux)"
  tmux_seq=$((tmux_seq + 1))
  tmux_sock="canopy-smoke-$$-${tmux_seq}"
  tmux_rc=0
  bare_tmux "${tmux_bin}" -L "${tmux_sock}" -f "$1" new-session -d || tmux_rc=$?
  if [ "${tmux_rc}" -eq 0 ]; then
    bare_tmux "${tmux_bin}" -L "${tmux_sock}" show -gv "$2" || tmux_rc=$?
  fi
  bare_tmux "${tmux_bin}" -L "${tmux_sock}" kill-server >/dev/null 2>&1 || :
  rm -f "/tmp/tmux-$(id -u)/${tmux_sock}"
  return "${tmux_rc}"
}

# --- compound assertions shared by the scenarios ---------------------------

# assert_config_loads <entry-point> <option> <expected-value>
# The assertion this whole harness exists for. Everything else can pass
# while the installed configuration loads nothing at all.
assert_config_loads() {
  capture tmux_option "$1" "$2"
  check "tmux loads $2 from ${1} with no CANOPY_* in its environment" "$3" "${last_output}"
}

# assert_doctor <expected-exit-status>
assert_doctor() {
  capture canopy doctor
  check "canopy doctor exits $1" "$1" "${last_status}"
  if [ "${last_status}" != "$1" ]; then
    printf '        doctor said:\n'
    printf '%s\n' "${last_output}" | while IFS= read -r doctor_line; do
      printf '          %s\n' "${doctor_line}"
    done
  fi
  return 0
}

# assert_home_restored <before-snapshot>
# Everything under $HOME outside canopy's restore-point tree is back to
# the bytes, links and directories it had before install, and the
# restore-point tree is the only survivor.
assert_home_restored() {
  snapshot "${home}" "${work}/after.snap"
  without_state "$1" "${home}" "${work}/before.filtered"
  without_state "${work}/after.snap" "${home}" "${work}/after.filtered"
  check_files "every path under \$HOME outside canopy's restore-point tree is exactly as it was before install" \
    "${work}/before.filtered" "${work}/after.filtered"
  check "canopy's restore points survived, so the filter above is not hiding an empty \$HOME" \
    yes "$(yesno test -d "${home}/.local/state/canopy/backups")"
}

# fabricate_interrupted_install <path>
# Reproduces the on-disk state canopy-install leaves behind when it is
# killed between migrating the user's files and reaching
# canopy_tx_commit: recorded rows and a byte copy of the original, no
# .committed marker and no .failed marker. Built rather than raced, so the
# window is deterministic, exactly as test/restore.bats does it. Prints
# the transaction id.
#
# canopy's own libraries are sourced to build it, inside a subshell, so
# the CANOPY_* they export cannot reach the scenario. Fabricating damage
# is setup; every canopy command the scenario then runs still runs from
# the same bare environment a user has.
fabricate_interrupted_install() {
  (
    CANOPY_STORE="${store}"
    export CANOPY_STORE
    # shellcheck source=../../lib/env.sh
    # shellcheck disable=SC1091
    . "${store}/lib/env.sh"
    # shellcheck source=../../lib/manifest.sh
    # shellcheck disable=SC1091
    . "${store}/lib/manifest.sh"
    canopy_paths
    interrupted_tx="$(canopy_tx_begin install)"
    canopy_tx_record "${interrupted_tx}" own "$1"
    printf 'written by an install that never committed\n' >"$1"
    printf '%s\n' "${interrupted_tx##*/}"
  )
}

# --- scenario plumbing -----------------------------------------------------

begin_scenario() {
  scenario_id="$1"
  scenario_name="$2"
  scenario_failed=0
  work="${root}/s$1"
  home="${work}/home"
  rm -rf "${work}"
  mkdir -p "${home}"
  HOME="${home}"
  export HOME
  printf '\n== scenario %s: %s ==\n' "$1" "$2"
}

end_scenario() {
  scenario_count=$((scenario_count + 1))
  if [ "${scenario_failed}" -eq 0 ]; then
    printf 'RESULT\t%s\tPASS\t%s\n' "${scenario_id}" "${scenario_name}"
  else
    overall_failed=1
    printf 'RESULT\t%s\tFAIL\t%s\n' "${scenario_id}" "${scenario_name}"
  fi
}

printf 'canopy smoke scenarios\n'
printf '  shell:  %s\n' "$(readlink -f /bin/sh 2>/dev/null || printf '/bin/sh')"
printf '  tmux:   %s\n' "$(tmux -V 2>/dev/null || printf 'not found')"
printf '  canopy: %s\n' "$(command -v canopy)"

# --- scenario 1: a virgin machine ------------------------------------------

begin_scenario 1 "virgin machine"
xdg_entry="${home}/.config/tmux/tmux.conf"

snapshot "${home}" "${work}/before.snap"

capture canopy install
check "canopy install exits 0 on an empty \$HOME" 0 "${last_status}"
check "install created an entry point at the XDG path" yes "$(yesno test -f "${xdg_entry}")"
check "install created user.conf" yes "$(yesno test -f "${home}/.config/canopy/user.conf")"

assert_config_loads "${xdg_entry}" @canopy_test_marker shipped-default
assert_doctor 0

capture canopy restore --all
check "canopy restore --all exits 0" 0 "${last_status}"
assert_home_restored "${work}/before.snap"
end_scenario

# --- scenario 2: a machine that already has configs ------------------------

begin_scenario 2 "machine with existing configs"
xdg_entry="${home}/.config/tmux/tmux.conf"
ghostty="${home}/.config/ghostty/config"
starship="${home}/.config/starship.toml"

mkdir -p "${home}/.config/tmux" "${home}/.config/ghostty"
# Valid tmux syntax, because install migrates this into user.conf and then
# validates the resulting chain before committing. A @-prefixed user
# option is real tmux syntax and still carries a recognisable value.
printf 'set -g @smoke_user_marker my-own-tmux-config\n' >"${xdg_entry}"
printf 'distinctive ghostty config, owned by nobody but the user\n' >"${ghostty}"
printf 'distinctive starship config, owned by nobody but the user\n' >"${starship}"

snapshot "${home}" "${work}/before.snap"
ghostty_before="$(sha256sum "${ghostty}" | cut -d' ' -f1)"
starship_before="$(sha256sum "${starship}" | cut -d' ' -f1)"
tmux_conf_before="$(sha256sum "${xdg_entry}" | cut -d' ' -f1)"

capture canopy install
check "canopy install refuses to migrate an existing config without --yes" 1 "${last_status}"
check_contains "the refusal names --yes" "--yes" "${last_output}"

capture canopy install --yes
check "canopy install --yes exits 0" 0 "${last_status}"

capture grep -c '@smoke_user_marker' "${home}/.config/canopy/user.conf"
check "the user's original tmux config survives inside canopy's user.conf" 1 "${last_output}"

# The migrated config is not merely present in a file, it is loaded, and
# it wins: user.conf is sourced last.
assert_config_loads "${xdg_entry}" @smoke_user_marker my-own-tmux-config
assert_config_loads "${xdg_entry}" @canopy_test_marker shipped-default

check "install left .config/ghostty/config untouched" \
  "${ghostty_before}" "$(sha256sum "${ghostty}" | cut -d' ' -f1)"
check "install left .config/starship.toml untouched" \
  "${starship_before}" "$(sha256sum "${starship}" | cut -d' ' -f1)"

assert_doctor 0

capture canopy restore --all
check "canopy restore --all exits 0" 0 "${last_status}"

check "the user's own .config/tmux/tmux.conf is byte-identical after restore" \
  "${tmux_conf_before}" "$(sha256sum "${xdg_entry}" | cut -d' ' -f1)"
check "the user's own .config/ghostty/config is byte-identical after restore" \
  "${ghostty_before}" "$(sha256sum "${ghostty}" | cut -d' ' -f1)"
check "the user's own .config/starship.toml is byte-identical after restore" \
  "${starship_before}" "$(sha256sum "${starship}" | cut -d' ' -f1)"
assert_home_restored "${work}/before.snap"
end_scenario

# --- scenario 3: a machine whose tmux config is a symlink ------------------
# What chezmoi, stow and a bare dotfiles repo all produce. canopy used to
# write straight through such a link, modifying a file it never recorded
# and could not promise to restore.

begin_scenario 3 "symlinked tmux config"
xdg_entry="${home}/.config/tmux/tmux.conf"
link_target="${home}/dotfiles/tmux.conf"

mkdir -p "${home}/.config/tmux" "${home}/dotfiles"
printf 'set -g @smoke_dotfiles_marker from-my-dotfiles-repo\n' >"${link_target}"
ln -s "${link_target}" "${xdg_entry}"

snapshot "${home}" "${work}/before.snap"
target_before="$(sha256sum "${link_target}" | cut -d' ' -f1)"

capture canopy install --yes
check "canopy install --yes exits 0" 0 "${last_status}"

check "install did not write through the link into the dotfiles repo" \
  "${target_before}" "$(sha256sum "${link_target}" | cut -d' ' -f1)"
check "install replaced the link with a regular file of its own" \
  no "$(yesno test -L "${xdg_entry}")"
assert_config_loads "${xdg_entry}" @smoke_dotfiles_marker from-my-dotfiles-repo
assert_doctor 0

capture canopy restore --all
check "canopy restore --all exits 0" 0 "${last_status}"

check "the entry point is a symlink again after restore" \
  yes "$(yesno test -L "${xdg_entry}")"
check "the restored symlink points where it pointed before" \
  "${link_target}" "$(readlink "${xdg_entry}")"
check "the link's target never changed a byte, at any point" \
  "${target_before}" "$(sha256sum "${link_target}" | cut -d' ' -f1)"
assert_home_restored "${work}/before.snap"
end_scenario

# --- scenario 4: idempotence and recovery ----------------------------------

begin_scenario 4 "idempotence and recovery"
decoy="${home}/tmux-notes.conf"
# A plain user file nothing sources. The interrupted transaction below has
# to touch something that is NOT the entry point: an entry point left in
# pieces makes doctor exit 2 for a load-bearing failure, and the check
# here is that an interrupted transaction alone makes it exit 1.
printf 'notes I keep next to my tmux config\n' >"${decoy}"
decoy_before="$(sha256sum "${decoy}" | cut -d' ' -f1)"

snapshot "${home}" "${work}/before.snap"

capture canopy install
check "the first canopy install exits 0" 0 "${last_status}"
snapshot "${home}" "${work}/installed.snap"

capture canopy install
check "the second canopy install refuses" 1 "${last_status}"
check_contains "the refusal says canopy is already installed" "already installed" "${last_output}"
snapshot "${home}" "${work}/installed-again.snap"
check_files "the refused second install changed nothing on disk" \
  "${work}/installed.snap" "${work}/installed-again.snap"

interrupted_id="$(fabricate_interrupted_install "${decoy}")"

capture canopy doctor
check "canopy doctor exits 1 on an interrupted install" 1 "${last_status}"
check_contains "doctor names the interrupted transaction" "${interrupted_id}" "${last_output}"
check_contains "doctor names the recovery command" \
  "canopy restore --to ${interrupted_id}" "${last_output}"

capture canopy restore --to "${interrupted_id}"
check "the recovery command doctor named exits 0" 0 "${last_status}"
check "the recovery command returned the interrupted file to its original bytes" \
  "${decoy_before}" "$(sha256sum "${decoy}" | cut -d' ' -f1)"

capture canopy restore --all
check "canopy restore --all exits 0" 0 "${last_status}"
assert_home_restored "${work}/before.snap"
end_scenario

# --- scenario 5: a DANGLING symlink at the entry point ---------------------
# chezmoi and stow leave one behind whenever the source tree they point
# into is not checked out yet. tmux skips such a link, and install's
# entry-point detection used to as well, so it replaced a path a dotfiles
# manager owns without ever asking.

begin_scenario 5 "dangling symlink at the entry point"
xdg_entry="${home}/.config/tmux/tmux.conf"
missing_target="${home}/dotfiles/tmux.conf"

mkdir -p "${home}/.config/tmux" "${home}/dotfiles"
ln -s "${missing_target}" "${xdg_entry}"
check "the entry point starts out as a dangling symlink" \
  "yes no" "$(yesno test -L "${xdg_entry}") $(yesno test -e "${xdg_entry}")"

snapshot "${home}" "${work}/before.snap"

capture canopy install
check "canopy install refuses a dangling entry-point symlink without --yes" 1 "${last_status}"
check_contains "the refusal names --yes" "--yes" "${last_output}"
check "the refused install left the link alone" \
  "${missing_target}" "$(readlink "${xdg_entry}")"

capture canopy install --yes
check "canopy install --yes exits 0" 0 "${last_status}"
check "install replaced the dangling link with a regular file of its own" \
  "no yes" "$(yesno test -L "${xdg_entry}") $(yesno test -f "${xdg_entry}")"
check "install did not create the file the link pointed at" \
  no "$(yesno test -e "${missing_target}")"
assert_config_loads "${xdg_entry}" @canopy_test_marker shipped-default
assert_doctor 0

capture canopy restore --all
check "canopy restore --all exits 0" 0 "${last_status}"
check "the entry point is a dangling symlink again after restore" \
  "yes no" "$(yesno test -L "${xdg_entry}") $(yesno test -e "${xdg_entry}")"
check "the restored symlink names the same target" \
  "${missing_target}" "$(readlink "${xdg_entry}")"
assert_home_restored "${work}/before.snap"
end_scenario

# --- scenario 6: two user accounts on one machine --------------------------
# The scenario a single-user laptop cannot express, and the one the
# containers found a real bug in: canopy's runtime directory fell back to
# a plain /tmp/canopy when XDG_RUNTIME_DIR was unset. /tmp is shared by
# every account, so that directory belonged to whichever user created it
# first, mode 755, and the next user's `canopy doctor` could not write its
# scratch file there. It reported "entry point loads from a bare
# environment: FAILED" against a perfectly healthy install and exited 2.

begin_scenario 6 "two user accounts on one machine"
second_home="${work}/home-second"

# as_second_user <command-line>
# Runs a command as uid 65534 (nobody, present with the same uid on both
# images) with its own $HOME. Nothing about canopy is passed in beyond
# the PATH a user would have.
# shellcheck disable=SC2317,SC2329  # reached only through capture(), which invokes it by name
as_second_user() {
  su -s /bin/sh -c "HOME='${second_home}' PATH='${PATH}' $1" nobody
}

if [ "$(id -u)" -ne 0 ]; then
  fail "acting as a second user needs to start from root" "uid 0" "uid $(id -u)"
else
  mkdir -p "${second_home}"
  chown 65534 "${second_home}"

  capture canopy install
  check "the first user's install exits 0" 0 "${last_status}"
  assert_doctor 0

  capture as_second_user "canopy install"
  check "the second user's install exits 0" 0 "${last_status}"

  capture as_second_user "canopy doctor"
  check "the second user's doctor exits 0 on their own healthy install" 0 "${last_status}"
  check_contains "the second user's doctor validated their entry point rather than failing to write a scratch file" \
    "entry point loads from a bare environment: ok" "${last_output}"
fi
end_scenario

# --- the reboot scenarios' shared plumbing -------------------------------

# The three conversations scenario 7 opens. Written out rather than
# generated: a failure names the id, and an id that is the same on every
# run is one that can be grepped for in a log from CI.
reboot_ids='11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222 33333333-3333-3333-3333-333333333333'

# agent_setup
# The fake agent on PATH, its transcripts under this scenario's own tree,
# and its adapter where canopy looks for one. The transcripts are the
# evidence: the agent writes "launch <id>" when it is started with an id
# and "resume <id>" when it is resumed with one, so a transcript holding
# both lines is a conversation that was continued rather than replaced.
agent_setup() {
  agent_home="${work}/agent-home"
  agent_map="${work}/panes.tsv"
  mkdir -p "${agent_home}"
  : >"${agent_map}"
  # The agent goes on the login shell's PATH, not on this script's. A tmux
  # pane runs the shell as a login shell, and /etc/profile resets PATH, so
  # an agent reachable only through the environment this script exports is
  # an agent no pane can start and no restored pane can resume. That is
  # not an artefact of the harness: /usr/local/bin is where a user's agent
  # actually lives.
  ln -sf "${store}/test/fixtures/fake-agent" /usr/local/bin/fake-agent
  FAKE_AGENT_HOME="${agent_home}"
  export FAKE_AGENT_HOME
  mkdir -p "${home}/.config/canopy/adapters"
  cp -R "${store}/test/fixtures/fake-agent-adapter" \
    "${home}/.config/canopy/adapters/fake-agent"
}

# rb <arg...>
# tmux against this scenario's server, from the same bare environment a
# user's tmux runs in.
# shellcheck disable=SC2317,SC2329  # called directly and through capture()
rb() {
  bare_tmux "${tmux_bin}" -L "${reboot_sock}" "$@"
}

# in_pane <pane> <arg...>
# Runs a canopy command the way an agent's hook runs it: from inside the
# pane's world, with $TMUX_PANE naming the pane and $TMUX naming the
# server, and nothing else borrowed from this script.
# shellcheck disable=SC2317,SC2329  # called through capture()
in_pane() {
  ip_pane="$1"
  shift
  env TMUX="${sock_path},0,0" TMUX_TMPDIR=/tmp TMUX_PANE="${ip_pane}" "$@"
}

# wait_for <seconds> <command...>
# Polls until the command succeeds. Everything this scenario waits on is
# asynchronous by design: the agent starts when the shell gets round to
# it, and continuum restores a second after the server starts.
wait_for() {
  wf_limit="$1"
  shift
  wf_i=0
  while [ "${wf_i}" -lt "${wf_limit}" ]; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    wf_i=$((wf_i + 1))
  done
  return 1
}

# open_anonymous_agent_pane
# A pane running the agent with no id anywhere: not on its command line, and
# never reported. This is the only shape canopy genuinely cannot bring back,
# and it is the shape a real agent has when its launch form takes no id, so
# it is worth a helper of its own rather than a variation of the one below.
#
# Prints the window index, because there is no id to look it up by later.
# shellcheck disable=SC2317,SC2329  # called through capture()
# shellcheck disable=SC2310  # a wait is a question, so its non-zero return is the answer and not a reason to abort
open_anonymous_agent_pane() {
  oaap_pane="$(rb new-window -t main -P -F '#{pane_id}')"
  [ -n "${oaap_pane}" ] || return 1
  oaap_window="$(rb display-message -p -t "${oaap_pane}" '#{window_index}')"
  [ -n "${oaap_window}" ] || return 1
  rb send-keys -t "${oaap_pane}" "fake-agent --anonymous" Enter
  wait_for 20 test -f "${agent_home}/anonymous.transcript" || return 1
  printf '%s\n' "${oaap_window}"
}

# open_agent_pane <session-id>
# A pane running the fake agent, started the way a person starts one: by
# typing it at a shell. The pane's own command is therefore the shell, so
# nothing about the pane records which conversation it holds until the
# agent reports it.
#
# The window it lands in is asked for, never assumed. canopy sets
# base-index 1, so the first window of a session is main:1, and a scenario
# that counted from zero looked for windows that do not exist and reported
# three healthy agents as missing.
#
# Records "<id><TAB><window index>" so the assertions after the reboot can
# look for each conversation in the window it actually had.
# shellcheck disable=SC2317,SC2329  # called through capture()
# shellcheck disable=SC2310  # a wait is a question, so its non-zero return is the answer and not a reason to abort
open_agent_pane() {
  oap_id="$1"
  if [ -s "${agent_map}" ]; then
    oap_pane="$(rb new-window -t main -P -F '#{pane_id}')"
  else
    oap_pane="$(rb list-panes -t main -F '#{pane_id}' | head -1)"
  fi
  [ -n "${oap_pane}" ] || return 1
  oap_window="$(rb display-message -p -t "${oap_pane}" '#{window_index}')"
  [ -n "${oap_window}" ] || return 1
  rb send-keys -t "${oap_pane}" "fake-agent --session-id ${oap_id}" Enter
  wait_for 20 test -f "${agent_home}/${oap_id}.transcript" || return 1
  printf '%s\t%s\n' "${oap_id}" "${oap_window}" >>"${agent_map}"
  printf '%s\n' "${oap_pane}"
}

# window_of <session-id>
window_of() {
  awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "${agent_map}"
}

# force_save
# resurrect's own save, run as continuum runs it. The scenario does not
# wait out continuum's interval: what is being proven is that the save
# holds the right command, not that a timer fires.
# shellcheck disable=SC2317,SC2329  # called through capture()
# shellcheck disable=SC2310  # the wait reports whether the save landed, which is the answer this returns
force_save() {
  rb run-shell "${store}/plugins/tmux-resurrect/scripts/save.sh quiet"
  wait_for 20 test -f "${home}/.local/state/canopy/resurrect/last"
}

# simulate_reboot
# Kill the server, then start one again from the installed entry point.
# What a real reboot adds is a cold machine, and nothing in this chain
# reads state that a reboot clears and a kill-server does not: the save
# file is on disk, and the replay is driven by the config the new server
# loads. The new server gets a session of its own name so that the
# restored sessions are recreated rather than merged into it.
# shellcheck disable=SC2310  # killing a server that is already gone is success here, not a reason to abort
simulate_reboot() {
  rb kill-server >/dev/null 2>&1 || :
  rm -f "/tmp/tmux-$(id -u)/${reboot_sock}"
  sleep 1
  bare_tmux "${tmux_bin}" -L "${reboot_sock}" \
    -f "${home}/.config/tmux/tmux.conf" new-session -d -s boot
  sock_path="$(rb display-message -p '#{socket_path}')"
}

# pane_running_command <pane>
# What the pane is actually running, as canopy's own pane library asks it:
# the command whose parent is the pane's process. Not
# #{pane_start_command}, which is empty for a restored pane, because
# resurrect brings a pane back by handing its command to a shell rather
# than by respawning it. Asserting the start command would therefore have
# asserted nothing at all after a reboot, which is the only moment that
# matters here.
# shellcheck disable=SC2317,SC2329  # called through capture() and command substitution
# shellcheck disable=SC2310  # asking a pane what it runs is a question, so a non-zero return is the answer
pane_running_command() {
  prc_pid="$(rb display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)" || return 1
  [ -n "${prc_pid}" ] || return 1
  ps -ao ppid,args 2>/dev/null |
    awk -v p="${prc_pid}" '$1 == p { $1 = ""; sub(/^ */, ""); print; exit }'
}

# assert_resumed <session-id>
# The claim the milestone is made of, for one pane: the conversation was
# continued, and it was continued in the window that held it.
# shellcheck disable=SC2310  # every branch here asks a question, so a non-zero return is the answer
assert_resumed() {
  ar_id="$1"
  ar_window="$(window_of "${ar_id}")"
  ar_transcript="${agent_home}/${ar_id}.transcript"
  if wait_for 45 grep -q "^resume ${ar_id}\$" "${ar_transcript}"; then
    check "the conversation ${ar_id} was resumed, not restarted" \
      "launch ${ar_id}
resume ${ar_id}" "$(cat "${ar_transcript}")"
  else
    fail "the conversation ${ar_id} was resumed, not restarted" \
      "a transcript holding launch then resume" \
      "$(cat "${ar_transcript}" 2>/dev/null || printf 'no transcript at all')"
  fi
  ar_pane="$(rb list-panes -t "main:${ar_window}" -F '#{pane_id}' 2>/dev/null | head -1)" || ar_pane=""
  if [ -z "${ar_pane}" ]; then
    fail "main:${ar_window} came back" "a pane in main:${ar_window}" "no such window"
    return 0
  fi
  check_contains "main:${ar_window} came back running its own resume command" \
    "fake-agent --resume ${ar_id}" "$(pane_running_command "${ar_pane}" || printf '')"
}

# --- scenario 7: a reboot returns each pane to its own conversation --------
#
# The milestone's acceptance. Every link in the chain has unit tests, and
# none of them can prove the chain: the adapter naming a resume command,
# the save strategy writing that command instead of the shell's, continuum
# replaying the file when a server starts, and the stagger wrapper
# surviving both the write and the replay.

begin_scenario 7 "a reboot returns each agent pane to its own conversation"

tmux_bin="$(command -v tmux)"
reboot_sock="canopy-smoke-reboot-$$"
agent_setup

capture canopy install
check "install exits 0" 0 "${last_status}"

bare_tmux "${tmux_bin}" -L "${reboot_sock}" \
  -f "${home}/.config/tmux/tmux.conf" new-session -d -s main
sock_path="$(rb display-message -p '#{socket_path}')"

first_pane=""
for reboot_id in ${reboot_ids}; do
  capture open_agent_pane "${reboot_id}"
  check "an agent pane holding ${reboot_id} is running" 0 "${last_status}"
  reboot_pane="${last_output}"
  [ -n "${first_pane}" ] || first_pane="${reboot_pane}"
  capture in_pane "${reboot_pane}" canopy agent report idle \
    --source fake-agent --session-id "${reboot_id}"
  check "the agent reported ${reboot_id} into its pane" 0 "${last_status}"
  check "the pane carries the id the agent reported" "${reboot_id}" \
    "$(rb display-message -p -t "${reboot_pane}" '#{@canopy_agent_session}')"
done

# A save has to exist before the pre-flight is asked anything, because
# reboot-check answers out of the save file rather than out of intentions.
# On a real machine continuum's autosave has long since run by the time
# anybody asks; here the interval is skipped and the save is forced,
# because what is being proven is that the save holds the right command,
# not that a timer fires.
capture force_save
check "a save was written" 0 "${last_status}"
check_contains "the save holds a resume command rather than a shell" \
  "fake-agent --resume" "$(cat "${home}/.local/state/canopy/resurrect/last")"

# Before the reboot, the pre-flight has to say this will work. A command
# that only tells the truth afterwards is worth nothing: the whole point
# of reboot-check is to be trusted before the machine goes down.
capture in_pane "${first_pane}" canopy reboot-check
check "reboot-check exits 0 with every agent pane resumable" 0 "${last_status}"
for reboot_id in ${reboot_ids}; do
  check_contains "reboot-check says ${reboot_id} will resume" \
    "${reboot_id}" "${last_output}"
done
check_contains "reboot-check reports the restore path as on" \
  "continuum restore at server start: on" "${last_output}"

simulate_reboot

for reboot_id in ${reboot_ids}; do
  assert_resumed "${reboot_id}"
done

# shellcheck disable=SC2310  # killing a server that is already gone is success here
rb kill-server >/dev/null 2>&1 || :
rm -f "/tmp/tmux-$(id -u)/${reboot_sock}"
end_scenario

# --- scenario 8: honest failure --------------------------------------------
#
# The other half of the promise, and the half that makes the first half
# worth anything. A pane whose agent never reported an id cannot come
# back, and what canopy must do about that is say so beforehand, name the
# pane, and still bring back every pane that can be brought back.

begin_scenario 8 "a pane with no id at all is called out, and costs no other pane"

tmux_bin="$(command -v tmux)"
reboot_sock="canopy-smoke-noid-$$"
agent_setup

kept_id=44444444-4444-4444-4444-444444444444
silent_id=55555555-5555-5555-5555-555555555555

capture canopy install
check "install exits 0" 0 "${last_status}"

bare_tmux "${tmux_bin}" -L "${reboot_sock}" \
  -f "${home}/.config/tmux/tmux.conf" new-session -d -s main
sock_path="$(rb display-message -p '#{socket_path}')"

capture open_agent_pane "${kept_id}"
check "the reporting agent pane is running" 0 "${last_status}"
kept_pane="${last_output}"
capture in_pane "${kept_pane}" canopy agent report idle \
  --source fake-agent --session-id "${kept_id}"
check "the reporting agent reported its id" 0 "${last_status}"

# The second pane runs the agent with an id on its command line and never
# reports. That used to be the unrecoverable case; it is not any more,
# because canopy reads the id back out of the command the pane is running
# when the adapter's launch form carries one. Asserted here so the
# capability cannot quietly regress: it is what makes a pane resumable from
# the moment it starts, rather than from its first report.
capture open_agent_pane "${silent_id}"
check "the silent agent pane is running" 0 "${last_status}"

# The third pane is the one nothing can save: the agent is running, and
# there is no id on its command line and none reported. Nothing anywhere
# knows which conversation it holds.
capture open_anonymous_agent_pane
check "the anonymous agent pane is running" 0 "${last_status}"
anon_window="${last_output}"

# Saved before the pre-flight is asked, for the same reason as scenario 7:
# reboot-check answers out of the save file, so asking it first would have
# it report every pane as unsaved and exit 1 for a reason that has nothing
# to do with the one this scenario is about.
capture force_save
check "a save was written" 0 "${last_status}"

capture in_pane "${kept_pane}" canopy reboot-check
check "reboot-check exits 1 when a pane cannot be brought back" 1 "${last_status}"
check_contains "reboot-check names the pane that will lose its conversation" \
  "main:${anon_window}." "${last_output}"
check_contains "reboot-check says why that pane is at risk" \
  "no session id" "${last_output}"
# The failing pane must not drag the healthy ones down with it: one pane
# that cannot be brought back is not a reason to stop promising the others.
check_contains "reboot-check still says the reporting pane will resume" \
  "${kept_id}" "${last_output}"
check_contains "reboot-check promises the silent pane too, from its command line" \
  "${silent_id}" "${last_output}"

simulate_reboot

assert_resumed "${kept_id}"
assert_resumed "${silent_id}"

# The anonymous pane comes back as a pane, and comes back without its
# conversation. Both halves are asserted: a reboot that dropped the window
# entirely would pass a check that only looked for the absent resume.
check "the anonymous agent's window came back" yes \
  "$(yesno test -n "$(rb list-panes -t "main:${anon_window}" -F '#{pane_id}' 2>/dev/null | head -1)")"
check "the anonymous pane did not come back resumed into a conversation" no \
  "$(yesno grep -q "^resume anonymous$" "${agent_home}/anonymous.transcript")"

# shellcheck disable=SC2310  # killing a server that is already gone is success here
rb kill-server >/dev/null 2>&1 || :
rm -f "/tmp/tmux-$(id -u)/${reboot_sock}"
end_scenario

printf '\nSCENARIOS-COMPLETE %s\n' "${scenario_count}"
exit "${overall_failed}"

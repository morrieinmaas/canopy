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

# shellcheck disable=SC2317,SC2329  # reached only through capture(), which invokes it by name
bare_tmux() {
  bare_bin="$1"
  shift
  env -i \
    HOME="${HOME}" \
    PATH="${bare_bin%/*}:/usr/bin:/bin" \
    TMUX_TMPDIR=/tmp \
    "${bare_bin}" "$@"
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

printf '\nSCENARIOS-COMPLETE %s\n' "${scenario_count}"
exit "${overall_failed}"

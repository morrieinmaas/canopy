# Once per bats run, around every test file.
#
# Sockets: every test's tmux runs under a private socket directory made
# here, short enough for a socket path, and removed at the end, so no test
# server sits beside anyone's real ones in /tmp/tmux-<uid>/.
#
# The guard: what the suite must never touch on the machine running it. It
# snapshots the shared places a test could reach by mistake, the real tmux
# socket directory and the files opensessions keeps under /tmp, and fails
# the run if a name appears there or one of opensessions' files changes.
# The owner's own servers write these too, so only what a test could cause
# is compared: new socket names, new opensessions files, and a changed
# install log, pid or version file.

canopy_guard_snapshot() {
  local uid
  uid="$(id -u)"
  {
    ls -1 "/tmp/tmux-$uid" 2>/dev/null | sed 's/^/socket /'
    for f in /tmp/opensessions*; do
      [ -e "$f" ] || continue
      case "$f" in
        /tmp/opensessions-install.log | /tmp/opensessions.*.pid | /tmp/opensessions.*.version)
          printf 'file %s %s\n' "$f" "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
          ;;
        *) printf 'file %s\n' "$f" ;;
      esac
    done
  } | LC_ALL=C sort
}

setup_suite() {
  CANOPY_TEST_SOCKS="$(mktemp -d /tmp/cnp.XXXXXX)"
  chmod 700 "$CANOPY_TEST_SOCKS"
  export CANOPY_TEST_SOCKS
  canopy_guard_snapshot >"$BATS_SUITE_TMPDIR/guard-before"
}

teardown_suite() {
  rm -rf "$CANOPY_TEST_SOCKS"
  canopy_guard_snapshot >"$BATS_SUITE_TMPDIR/guard-after"
  if ! diff "$BATS_SUITE_TMPDIR/guard-before" "$BATS_SUITE_TMPDIR/guard-after" >"$BATS_SUITE_TMPDIR/guard-diff"; then
    printf 'the suite touched shared tmux or opensessions state:\n' >&2
    cat "$BATS_SUITE_TMPDIR/guard-diff" >&2
    return 1
  fi
}

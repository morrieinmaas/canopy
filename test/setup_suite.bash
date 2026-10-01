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

# The tmux every test finds first on PATH. It works out the socket the call
# would reach, the way tmux does (-S, else -L under $TMUX_TMPDIR, else
# $TMUX's socket, else default under $TMUX_TMPDIR), and refuses with exit
# 97, before anything connects, unless that socket is under the suite's
# own directory. A refusal is logged with its argv, and teardown_suite
# fails the run on any. `tmux -V` reaches no server and is let through.
canopy_write_tmux_shim() {
  mkdir -p "$CANOPY_TEST_SOCKS/bin"
  cat >"$CANOPY_TEST_SOCKS/bin/tmux" <<EOF
#!/bin/sh
real='$1'
root='$CANOPY_TEST_SOCKS'
refusals="\${CANOPY_SHIM_REFUSALS:-\$root/refused}"
dir="\${TMUX_TMPDIR:-/tmp}/tmux-\$(id -u)"
sock=""
named=""
version=0
for a in "\$@"; do
  if [ -n "\$named" ]; then
    case "\$named" in
      -S) sock="\$a" ;;
      -L) sock="\$dir/\$a" ;;
      *) ;;
    esac
    named=""
    continue
  fi
  case "\$a" in
    -S | -L | -f | -c | -T) named="\$a" ;;
    -V) version=1 ;;
    -*) ;;
    *) break ;;
  esac
done
if [ -z "\$sock" ]; then
  if [ -n "\${TMUX:-}" ]; then
    sock="\${TMUX%%,*}"
  else
    sock="\$dir/default"
  fi
fi
case "\$sock" in
  "\$root"/*) exec "\$real" "\$@" ;;
  *) ;;
esac
[ "\$version" -eq 1 ] && exec "\$real" "\$@"
printf '%s\\n' "\$*" >>"\$refusals"
exit 97
EOF
  chmod +x "$CANOPY_TEST_SOCKS/bin/tmux"
}

setup_suite() {
  # Resolved, because tmux names its sockets by the real path (/private/tmp
  # on macOS), and the shim compares against this.
  CANOPY_TEST_SOCKS="$(cd "$(mktemp -d /tmp/cnp.XXXXXX)" && pwd -P)"
  chmod 700 "$CANOPY_TEST_SOCKS"
  export CANOPY_TEST_SOCKS
  local real
  real="$(command -v tmux)" || return 1
  canopy_write_tmux_shim "$real"
  PATH="$CANOPY_TEST_SOCKS/bin:$PATH"
  export PATH
  canopy_guard_snapshot >"$BATS_SUITE_TMPDIR/guard-before"
}

teardown_suite() {
  local refused=""
  [ -s "$CANOPY_TEST_SOCKS/refused" ] && refused="$(cat "$CANOPY_TEST_SOCKS/refused")"
  rm -rf "$CANOPY_TEST_SOCKS"
  if [ -n "$refused" ]; then
    printf 'the tmux shim refused calls that named no socket of the suite:\n%s\n' "$refused" >&2
    return 1
  fi
  canopy_guard_snapshot >"$BATS_SUITE_TMPDIR/guard-after"
  if ! diff "$BATS_SUITE_TMPDIR/guard-before" "$BATS_SUITE_TMPDIR/guard-after" >"$BATS_SUITE_TMPDIR/guard-diff"; then
    printf 'the suite touched shared tmux or opensessions state:\n' >&2
    cat "$BATS_SUITE_TMPDIR/guard-diff" >&2
    return 1
  fi
}

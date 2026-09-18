#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

# A minimal PATH that still resolves every tool canopy-caps itself needs
# (mkdir, sed, cat, printf, dirname, tmux, sh) but excludes the directories
# that hold every one of the six probed tools on this development machine,
# so "absent" can be asserted deterministically instead of depending on
# what happens to be installed on the host running the tests.
restricted_path() {
  printf '%s' "$CANOPY_STORE/bin:/opt/nanobrew/prefix/opt/coreutils/libexec/gnubin:/opt/nanobrew/prefix/opt/gnu-sed/libexec/gnubin:/opt/nanobrew/prefix/bin:/usr/bin:/bin"
}

@test "generates 05-caps.conf under CANOPY_STATE" {
  run canopy-caps
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_STATE/05-caps.conf" ]
}

@test "a tool that is absent yields 0" {
  PATH="$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -qx 'set -g @canopy_has_wt 0' "$CANOPY_STATE/05-caps.conf"
  grep -qx 'set -g @canopy_has_fzf 0' "$CANOPY_STATE/05-caps.conf"
}

@test "a tool that is present yields 1" {
  fake_bin="$BATS_TEST_TMPDIR/fakebin-present"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/fzf" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/fzf"
  PATH="$fake_bin:$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -qx 'set -g @canopy_has_fzf 1' "$CANOPY_STATE/05-caps.conf"
}

@test "sets the tmux version option" {
  run canopy-caps
  [ "$status" -eq 0 ]
  grep -q '^set -g @canopy_tmux_version ' "$CANOPY_STATE/05-caps.conf"
}

@test "running twice produces byte-identical output" {
  run canopy-caps
  [ "$status" -eq 0 ]
  first="$(cat "$CANOPY_STATE/05-caps.conf")"
  run canopy-caps
  [ "$status" -eq 0 ]
  second="$(cat "$CANOPY_STATE/05-caps.conf")"
  [ "$first" = "$second" ]
}

@test "running twice under restricted PATH is also byte-identical" {
  PATH="$(restricted_path)"
  run canopy-caps
  [ "$status" -eq 0 ]
  first="$(cat "$CANOPY_STATE/05-caps.conf")"
  run canopy-caps
  [ "$status" -eq 0 ]
  second="$(cat "$CANOPY_STATE/05-caps.conf")"
  [ "$first" = "$second" ]
}

@test "--print writes a human summary to stdout without changing the file" {
  run canopy-caps --print
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux"* ]]
  [ -f "$CANOPY_STATE/05-caps.conf" ]
}

@test "plain run (no --print) writes no stdout" {
  run canopy-caps
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the generated file loads under the tmux loader" {
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
  run canopy-caps
  [ "$status" -eq 0 ]
  run canopy_tmux_validate "$CANOPY_STORE/tmux/tmux.conf"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

@test "dispatches to a subcommand" {
  run canopy version
  [ "$status" -eq 0 ]
}

@test "help lists commands grouped, using summary metadata" {
  run canopy help
  [ "$status" -eq 0 ]
  [[ "$output" == *"core"* ]]
  [[ "$output" == *"Print the canopy version"* ]]
}

@test "unknown command exits 2 and suggests" {
  run canopy verzion
  [ "$status" -eq 2 ]
  [[ "$output" == *"version"* ]]
}

@test "help output order is not affected by the caller's locale" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/bin" "$store_copy/lib"
  cp "$CANOPY_STORE/lib/env.sh" "$store_copy/lib/env.sh"
  for n in Zeta apple; do
    cat >"$store_copy/bin/canopy-$n" <<EOF
#!/bin/sh
# canopy:summary=fixture $n
set -eu
printf '$n\n'
EOF
    chmod +x "$store_copy/bin/canopy-$n"
  done

  CANOPY_STORE="$store_copy"
  LC_ALL=en_US.UTF-8
  export CANOPY_STORE LC_ALL
  run canopy help
  [ "$status" -eq 0 ]
  # Under LC_ALL=C (what canopy must pin internally), "Zeta" sorts before
  # "apple"; under the caller's en_US.UTF-8 it would sort the other way.
  case "$output" in
  *Zeta*apple*) ;;
  *) false ;;
  esac
}

@test "a non-executable canopy-* is hidden from help and suggestions, and explained on dispatch" {
  # Enumeration used [ -f ] while dispatch used [ -x ], so a file that
  # could never run still appeared in help and was still offered as a
  # spelling suggestion, sending the user at a command that then failed.
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/bin" "$store_copy/lib"
  cp "$CANOPY_STORE/lib/env.sh" "$store_copy/lib/env.sh"
  cat >"$store_copy/bin/canopy-broken" <<'EOF'
#!/bin/sh
# canopy:summary=Cannot be dispatched
set -eu
EOF
  chmod -x "$store_copy/bin/canopy-broken"
  cat >"$store_copy/bin/canopy-fine" <<'EOF'
#!/bin/sh
# canopy:summary=Can be dispatched
set -eu
printf 'fine\n'
EOF
  chmod +x "$store_copy/bin/canopy-fine"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE

  run canopy help
  [ "$status" -eq 0 ]
  [[ "$output" == *"fine"* ]]
  [[ "$output" != *"broken"* ]]

  # a near-miss must not be steered towards something that cannot run
  run canopy brokn
  [ "$status" -eq 2 ]
  [[ "$output" != *"broken"* ]]

  # asked for directly, it is still named and explained rather than
  # reported as unknown
  run canopy broken
  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
}

@test "help and index agree on the default group for a command without a group header" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/bin" "$store_copy/lib"
  cp "$CANOPY_STORE/lib/env.sh" "$store_copy/lib/env.sh"
  cat >"$store_copy/bin/canopy-nogroup" <<'EOF'
#!/bin/sh
# canopy:summary=No group header here
set -eu
printf 'nogroup\n'
EOF
  chmod +x "$store_copy/bin/canopy-nogroup"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE

  run canopy help
  [ "$status" -eq 0 ]
  case "$output" in
  *"misc:"*) ;;
  *) false ;;
  esac

  run canopy-index
  [ "$status" -eq 0 ]
  group_field="$(awk -F'\t' '$1 == "nogroup" {print $2}' "$CANOPY_STATE/commands.tsv")"
  [ "$group_field" = "misc" ]
}

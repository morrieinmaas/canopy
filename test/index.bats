#!/usr/bin/env bats
load helper

setup() { setup_canopy_env; }

@test "generates commands.tsv with a row for version" {
  run canopy-index
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_STATE/commands.tsv" ]
  row="$(awk -F'\t' '$1 == "version"' "$CANOPY_STATE/commands.tsv")"
  [ -n "$row" ]
}

@test "a command with no summary header still produces a row with an empty summary field" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/bin" "$store_copy/lib"
  cp "$CANOPY_STORE/lib/env.sh" "$store_copy/lib/env.sh"
  cat >"$store_copy/bin/canopy-nosummary" <<'EOF'
#!/bin/sh
# canopy:group=misc
set -eu
printf 'nosummary\n'
EOF
  chmod +x "$store_copy/bin/canopy-nosummary"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-index
  [ "$status" -eq 0 ]

  row="$(awk -F'\t' '$1 == "nosummary"' "$CANOPY_STATE/commands.tsv")"
  [ -n "$row" ]
  printf '%s' "$row" | awk -F'\t' '{ if ($3 != "") exit 1 }'
}

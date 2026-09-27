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

@test "rejects a header value containing a literal tab" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy/bin" "$store_copy/lib"
  cp "$CANOPY_STORE/lib/env.sh" "$store_copy/lib/env.sh"
  printf '#!/bin/sh\n# canopy:summary=Foo\tBar\n# canopy:group=misc\nset -eu\nprintf "x\\n"\n' \
    >"$store_copy/bin/canopy-badtab"
  chmod +x "$store_copy/bin/canopy-badtab"

  CANOPY_STORE="$store_copy"
  export CANOPY_STORE
  run canopy-index
  [ "$status" -ne 0 ]
  [[ "$output" == *"canopy-badtab"* ]]
  [ ! -f "$CANOPY_STATE/commands.tsv" ]
}

@test "sort order is not affected by the caller's locale" {
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
  run canopy-index
  [ "$status" -eq 0 ]
  # Under LC_ALL=C (what canopy-index must pin internally), "Zeta" sorts
  # before "apple"; under the caller's en_US.UTF-8 it would sort the other
  # way.
  first="$(awk -F'\t' 'NR==1{print $1}' "$CANOPY_STATE/commands.tsv")"
  [ "$first" = "Zeta" ]
}

@test "rejects an unknown argument instead of silently ignoring it" {
  run canopy-index --print
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-index: unknown argument: --print" ]
  [ ! -f "$CANOPY_STATE/commands.tsv" ]
}

@test "every command has a section in docs/02-commands.md" {
  # This drifted once: `keys` and `status` shipped with no entry, and the
  # README still said no keys were bound at all. A command nobody documented
  # is a command nobody can use, so the doc is part of shipping one.
  doc="$CANOPY_STORE/docs/02-commands.md"
  [ -f "$doc" ]

  missing=""
  for cmd in "$CANOPY_STORE"/bin/canopy-*; do
    name="${cmd##*/canopy-}"
    grep -qF "## \`canopy $name\`" "$doc" || missing="$missing $name"
  done
  # The dispatcher itself, documented as plain `canopy`.
  grep -qF '## `canopy`' "$doc" || missing="$missing canopy"

  [ -z "$missing" ] || {
    printf 'undocumented commands:%s\n' "$missing"
    false
  }
}

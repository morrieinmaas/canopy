#!/usr/bin/env bats
load helper

# `canopy keys`: the generator that turns the key table into the one layer
# that binds anything.
#
# What is being protected is the claim in spec 4.4, that keys are data.
# The moment a binding exists as a hand-written `bind` line somewhere, it
# has no description and no group, cannot appear in a palette or a
# cheatsheet, and the table stops being the truth. So the tests below care
# about the table being the only source as much as about the bindings
# working.
setup() {
  setup_canopy_env
  . "$CANOPY_STORE/lib/env.sh"
  canopy_paths
  sock=""
}

teardown() {
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  return 0
}

@test "generates the layer into CANOPY_STATE, not into the read-only store" {
  run canopy-keys
  [ "$status" -eq 0 ]
  [ -f "$CANOPY_STATE/10-keys.conf" ]
  [ ! -e "$CANOPY_STORE/tmux/conf.d/10-keys.conf" ]
}

@test "every row of the table becomes a binding, and nothing else does" {
  canopy-keys
  # Counted as the generator counts: blank rows are skipped, so counting
  # them here would report drift that does not exist.
  table_rows="$(awk '!/^#/ && NF { n++ } END { print n + 0 }' "$CANOPY_STORE/tmux/keys.tsv")"
  bind_lines="$(awk '/^bind / { n++ } END { print n + 0 }' "$CANOPY_STATE/10-keys.conf")"
  [ "$table_rows" = "$bind_lines" ]
}

@test "a repeatable key is emitted repeatable, and a plain one is not" {
  canopy-keys
  grep -q '^bind -r H resize-pane -L 5$' "$CANOPY_STATE/10-keys.conf"
  grep -q '^bind h select-pane -L$' "$CANOPY_STATE/10-keys.conf"
  ! grep -q '^bind -r h ' "$CANOPY_STATE/10-keys.conf"
}

@test "the generated layer loads, and the keys are really bound" {
  canopy-keys
  sock="canopy-keys-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$CANOPY_STATE/10-keys.conf"
  run tmux -L "$sock" list-keys -T prefix
  [ "$status" -eq 0 ]
  [[ "$output" == *"select-pane -L"* ]]
  [[ "$output" == *"resize-pane -L 5"* ]]
  [[ "$output" == *"switch-client -p"* ]]
}

@test "a semicolon in the table reaches tmux as a command separator" {
  # The cockpit binding is four commands in one. Written naively the
  # semicolons arrive as literal arguments to new-window, which tmux
  # rejects, so a generator that only quotes is a generator that silently
  # emits one broken binding.
  canopy-keys
  sock="canopy-keys-semi-$$"
  tmux -L "$sock" -f /dev/null new-session -d
  run tmux -L "$sock" source-file "$CANOPY_STATE/10-keys.conf"
  [ "$status" -eq 0 ]
  run tmux -L "$sock" list-keys -T prefix
  [[ "$output" == *"select-layout main-vertical"* ]]
}

@test "generating twice produces the same bytes" {
  canopy-keys
  first="$(canopy_sha256 "$CANOPY_STATE/10-keys.conf")"
  canopy-keys
  [ "$(canopy_sha256 "$CANOPY_STATE/10-keys.conf")" = "$first" ]
}

@test "--print shows the table as a human reads it, and writes nothing" {
  canopy-keys
  before="$(canopy_sha256 "$CANOPY_STATE/10-keys.conf")"
  run canopy-keys --print
  [ "$status" -eq 0 ]
  [[ "$output" == *"pane"* ]]
  [[ "$output" == *"Focus the pane to the left"* ]]
  [ "$(canopy_sha256 "$CANOPY_STATE/10-keys.conf")" = "$before" ]
}

@test "no key is declared twice" {
  # Two rows claiming one key means the later silently wins and one
  # description in the palette is a lie.
  run sh -c "grep -v '^#' '$CANOPY_STORE/tmux/keys.tsv' | cut -f2 | sort | uniq -d"
  [ "$output" = "" ]
}

@test "no name is used twice" {
  run sh -c "grep -v '^#' '$CANOPY_STORE/tmux/keys.tsv' | cut -f1 | sort | uniq -d"
  [ "$output" = "" ]
}

@test "every row carries all six columns, filled" {
  run sh -c "grep -v '^#' '$CANOPY_STORE/tmux/keys.tsv' | awk -F'\t' 'NF != 6 || \$1 == \"\" || \$2 == \"\" || \$3 == \"\" || \$4 == \"\" || \$5 == \"\" || \$6 == \"\" { print NR }'"
  [ "$output" = "" ]
}

@test "rejects an unknown argument the same way every other command does" {
  run canopy-keys --definitely-not-a-flag
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-keys: unknown argument: --definitely-not-a-flag" ]
}

#!/usr/bin/env bats
load helper

# `canopy config` answers "what can I change, and what is it now?" from one
# declared table, tmux/options.tsv, rather than from a list kept inside the
# command. The cross-check at the bottom of this file is what makes that
# worth trusting: a layer that sets an option the table does not know about,
# or knows with a different default, fails here rather than misleading a
# reader later.
setup() {
  setup_canopy_env
  setup_canopy_home
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/tmux.sh"
  canopy_paths
}

@test "lists options grouped, with a default for each" {
  run canopy config --defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:"* ]]
  [[ "$output" == *"theme:"* ]]
  [[ "$output" == *"persistence:"* ]]
  [[ "$output" == *"@canopy_status_battery"* ]]
  [[ "$output" == *"#fbf1c7"* ]]
}

@test "the internal group is hidden until it is asked for" {
  run canopy config --defaults
  [ "$status" -eq 0 ]
  [[ "$output" != *"@canopy_test_marker"* ]]

  run canopy config --defaults --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"internal:"* ]]
  [[ "$output" == *"@canopy_test_marker"* ]]
}

@test "with no server answering, every live value reads as unknown rather than as a failure" {
  # The common case: you ran this to find out what to put in user.conf
  # before starting tmux at all.
  #
  # The empty socket directory has to be one tmux can actually create and
  # then find nothing in. Point TMUX_TMPDIR at a path tmux cannot create,
  # such as /nonexistent, and it falls back to the default socket directory
  # instead, where a real server may well be listening: the test then passes
  # or fails depending on whether the person running it has tmux open.
  empty_sockets="$BATS_TEST_TMPDIR/no-server-here"
  mkdir -p "$empty_sockets"
  run env -u TMUX TMUX_TMPDIR="$empty_sockets" canopy config
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tmux server answered"* ]]
}

@test "an option a user overrode is marked, and one left alone is not" {
  printf 'set -g @theme_red "#ff0000"\n' >>"$CANOPY_CONFIG/user.conf"
  run canopy install
  [ "$status" -eq 0 ]

  sock="canopy-config-$$"
  bare_tmux -L "$sock" -f "$(canopy_entry_point)" new-session -d
  run env TMUX= tmux -L "$sock" run-shell "canopy config"
  kill_tmux_server "$sock"

  # run-shell prints the command's stdout into the client, so the table
  # arrives here the same way a person sees it.
  [[ "$output" == *"@theme_red"* ]]
  [[ "$output" == *"#ff0000"* ]]
  [[ "$output" == *"hold something other than the shipped default"* ]]
}

@test "rejects an unknown argument instead of silently ignoring it" {
  run canopy config --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "a table row with the wrong column count is reported, not skipped" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf '@broken\tvalue\tlayer\n' >>"$store_copy/tmux/options.tsv"

  CANOPY_STORE="$store_copy" run canopy-config --defaults
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 5 tab separated columns"* ]]
}

@test "a table row with an unknown source is reported" {
  store_copy="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store_copy"
  cp -R "$CANOPY_STORE/bin" "$store_copy/bin"
  cp -R "$CANOPY_STORE/lib" "$store_copy/lib"
  cp -R "$CANOPY_STORE/tmux" "$store_copy/tmux"
  printf '@broken\tvalue\tsomewhere\tstatus\tno such source\n' >>"$store_copy/tmux/options.tsv"

  CANOPY_STORE="$store_copy" run canopy-config --defaults
  [ "$status" -ne 0 ]
  [[ "$output" == *"source must be layer, code or generated"* ]]
}

@test "every option a shipped layer sets is in the table, with the same default" {
  # The cross-check. Without it, options.tsv is a second copy of the truth
  # that nothing keeps honest, and a stale row in it is worse than no table
  # at all: it tells a reader a default that is not what their tmux holds.
  run awk -F'\t' '
    FILENAME ~ /options\.tsv$/ {
      if ($0 ~ /^#/ || NF != 5) next
      default_of[$1] = ($2 == "-") ? "" : $2
      source_of[$1] = $3
      known[$1] = 1
      next
    }
    # A layer line that sets a user option. tmux spells it `set -g @name
    # value`, and `setw`/`set-option` are the same command; the value may be
    # quoted either way, or not at all.
    /^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@/ {
      n = split($0, f, /[ \t]+/)
      i = 1
      while (f[i] == "") i++
      name = f[i + 2]
      value = ""
      for (j = i + 3; j <= n; j++) value = (value == "" ? f[j] : value " " f[j])
      # Strip one layer of matching quotes, which is all a layer ever uses.
      if (value ~ /^".*"$/ || value ~ /^'"'"'.*'"'"'$/) value = substr(value, 2, length(value) - 2)

      if (!known[name]) {
        printf "%s sets %s, which tmux/options.tsv does not list\n", FILENAME, name
        bad = 1
        next
      }
      if (source_of[name] != "layer") {
        printf "%s sets %s, but the table calls its source %s\n", FILENAME, name, source_of[name]
        bad = 1
        next
      }
      if (default_of[name] != value) {
        printf "%s sets %s to [%s], the table says [%s]\n", FILENAME, name, value, default_of[name]
        bad = 1
      }
    }
    END { if (bad) exit 1 }
  ' "$CANOPY_STORE/tmux/options.tsv" "$CANOPY_STORE"/tmux/conf.d/*.conf
  [ "$status" -eq 0 ] || printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

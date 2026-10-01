#!/usr/bin/env bats
load helper

# canopy's save wrapper (plugins/strategies/canopy_save.sh): continuum runs
# a save every interval whether or not the last one has ended, so the
# wrapper lets one run at a time per server, and a save started while
# another runs exits at once with one log line.
setup() {
  setup_canopy_env
  wrapper="$CANOPY_STORE/plugins/strategies/canopy_save.sh"
  runs="$BATS_TEST_TMPDIR/runs"
  # A save that takes a while and says when it starts and ends.
  CANOPY_RESURRECT_SAVE="$BATS_TEST_TMPDIR/slow-save"
  cat >"$CANOPY_RESURRECT_SAVE" <<SAVE
#!/bin/sh
echo "start \$1" >>"$runs"
sleep "\${SLOW_SAVE_SECONDS:-2}"
echo "end \$1" >>"$runs"
SAVE
  chmod +x "$CANOPY_RESURRECT_SAVE"
  # The server a save belongs to, as continuum's job sees it in $TMUX.
  TMUX="$BATS_TEST_TMPDIR/sock,4242,0"
  export CANOPY_RESURRECT_SAVE TMUX
  log="$CANOPY_STATE/resurrect-save.log"
}

@test "a save started while another runs exits at once, with one log line" {
  "$wrapper" one &
  first=$!
  # The first has the lock once it has started its save.
  for _ in $(seq 1 50); do [ -s "$runs" ] && break; sleep 0.1; done
  started="$(date +%s)"
  run "$wrapper" two
  [ "$status" -eq 0 ]
  [ "$(($(date +%s) - started))" -le 1 ]
  wait "$first"
  [ "$(cat "$runs")" = "start one
end one" ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]
  grep -q "skipped: a save is already running (pid $first)" "$log"
}

@test "two saves started together: exactly one runs" {
  SLOW_SAVE_SECONDS=1 "$wrapper" a &
  a=$!
  SLOW_SAVE_SECONDS=1 "$wrapper" b &
  b=$!
  wait "$a" "$b"
  [ "$(grep -c '^start' "$runs")" -eq 1 ]
  [ "$(grep -c '^end' "$runs")" -eq 1 ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]
}

@test "the lock is let go: a save after the last one ended runs" {
  SLOW_SAVE_SECONDS=0 "$wrapper" one
  SLOW_SAVE_SECONDS=0 "$wrapper" two
  [ "$(grep -c '^start' "$runs")" -eq 2 ]
  [ ! -e "$log" ]
  [ -z "$(ls "$CANOPY_STATE" | grep '\.lock$')" ]
}

@test "a lock whose save was killed is taken over" {
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  mkdir -p "$CANOPY_STATE/resurrect-save.4242.lock"
  echo "$dead" >"$CANOPY_STATE/resurrect-save.4242.lock/pid"
  SLOW_SAVE_SECONDS=0 run "$wrapper" one
  [ "$status" -eq 0 ]
  [ "$(cat "$runs")" = "start one
end one" ]
}

@test "saves on two servers do not wait for each other" {
  "$wrapper" one &
  first=$!
  for _ in $(seq 1 50); do [ -s "$runs" ] && break; sleep 0.1; done
  TMUX="$BATS_TEST_TMPDIR/other,5151,0" SLOW_SAVE_SECONDS=0 "$wrapper" two
  wait "$first"
  [ "$(grep -c '^start' "$runs")" -eq 2 ]
}

@test "tmux.conf and the grofe fragment point continuum at the wrapper, after the loader" {
  # resurrect sets @resurrect-save-script-path to its own save.sh as it
  # loads, so the wrapper's line must come after the loader's.
  conf="$CANOPY_STORE/tmux/tmux.conf"
  loader="$(grep -n 'canopy_load_plugins' "$conf" | head -1 | cut -d: -f1)"
  wrap="$(grep -n '@resurrect-save-script-path "$CANOPY_STORE/plugins/strategies/canopy_save.sh"' "$conf" | cut -d: -f1)"
  [ -n "$wrap" ] && [ "$wrap" -gt "$loader" ]
  for f in grofe/templates/30-canopy-plugins.toml grofe/conf.d/30-canopy-plugins.toml; do
    f="$CANOPY_STORE/$f"
    loader="$(grep -n 'canopy_load_plugins' "$f" | head -1 | cut -d: -f1)"
    wrap="$(grep -n "@resurrect-save-script-path \"\$CANOPY_STORE/plugins/strategies/canopy_save.sh\"" "$f" | cut -d: -f1)"
    [ -n "$wrap" ] && [ "$wrap" -gt "$loader" ]
  done
}

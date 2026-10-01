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
  # The server a save belongs to, as continuum's job sees it in $TMUX: a
  # socket inside the suite's own directory, with no server on it.
  TMUX="$TMUX_TMPDIR/sock,4242,0"
  export CANOPY_RESURRECT_SAVE TMUX
  log="$CANOPY_STATE/resurrect-save.log"
  lock="$CANOPY_STATE/resurrect-save.4242.lock"
}

# A tmux first on PATH that records what the wrapper asks of it.
fake_tmux() {
  mkdir -p "$BATS_TEST_TMPDIR/faketmux"
  cat >"$BATS_TEST_TMPDIR/faketmux/tmux" <<FAKE
#!/bin/sh
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/tmux-calls"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/faketmux/tmux"
  PATH="$BATS_TEST_TMPDIR/faketmux:$PATH"
  export PATH
}

# A lock directory held by <pid>, last modified <touch -t stamp> ago or now.
hold_lock() {
  mkdir -p "$lock"
  [ -n "$1" ] && printf '%s\n' "$1" >"$lock/pid"
  if [ -n "${2-}" ]; then
    touch -t "$2" "$lock/pid" 2>/dev/null || true
    touch -t "$2" "$lock"
  fi
  return 0
}

# A long-running process whose command line names canopy_save, as a
# running wrapper's does.
canopy_save_lookalike() {
  cp "$(command -v sleep)" "$BATS_TEST_TMPDIR/canopy_save-sleeper"
  "$BATS_TEST_TMPDIR/canopy_save-sleeper" 30 &
  lookalike=$!
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
  hold_lock "$dead"
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

@test "a lock whose pid now belongs to something else is taken over" {
  # A reused pid: alive, and not a save.
  sleep 30 &
  other=$!
  hold_lock "$other"
  SLOW_SAVE_SECONDS=0 run "$wrapper" one
  kill "$other"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^start' "$runs")" -eq 1 ]
  [ ! -e "$log" ]
}

@test "a running save's lock is honoured, and taken over once older than ten minutes" {
  canopy_save_lookalike
  hold_lock "$lookalike"
  SLOW_SAVE_SECONDS=0 run "$wrapper" quiet
  [ ! -e "$runs" ]
  grep -q "pid $lookalike" "$log"
  # No @continuum-save-interval to read here, so the bound is ten minutes.
  hold_lock "$lookalike" "$(date -v-11M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-11 minutes' +%Y%m%d%H%M.%S)"
  SLOW_SAVE_SECONDS=0 run "$wrapper" quiet
  kill "$lookalike"
  [ "$(grep -c '^start' "$runs")" -eq 1 ]
}

@test "a lock being taken (no pid yet) is honoured while new, taken over once not" {
  hold_lock ""
  SLOW_SAVE_SECONDS=0 run "$wrapper" quiet
  [ ! -e "$runs" ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]
  hold_lock "" "$(date -v-1M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-1 minute' +%Y%m%d%H%M.%S)"
  SLOW_SAVE_SECONDS=0 run "$wrapper" quiet
  [ "$(grep -c '^start' "$runs")" -eq 1 ]
}

@test "two savers finding the same stale lock: exactly one takes it over" {
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  hold_lock "$dead"
  SLOW_SAVE_SECONDS=1 "$wrapper" a &
  a=$!
  SLOW_SAVE_SECONDS=1 "$wrapper" b &
  b=$!
  wait "$a" "$b"
  [ "$(grep -c '^start' "$runs")" -eq 1 ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]
  [ -z "$(ls "$CANOPY_STATE" | grep 'stale')" ]
}

@test "a save leaves a lock that is no longer its own in place" {
  # The save finds its lock taken over (say, judged too old) part way.
  cat >"$CANOPY_RESURRECT_SAVE" <<SAVE
#!/bin/sh
echo "start \$1" >>"$runs"
echo 99999 >"$lock/pid"
SAVE
  run "$wrapper" one
  [ "$status" -eq 0 ]
  [ "$(cat "$lock/pid")" = 99999 ]
}

@test "M-s while an autosave runs is skipped and says so; an autosave during M-s is skipped quietly" {
  fake_tmux
  # An autosave holds the lock; then M-s (no quiet) arrives.
  "$wrapper" quiet &
  auto=$!
  for _ in $(seq 1 50); do [ -s "$runs" ] && break; sleep 0.1; done
  run "$wrapper"
  [ "$status" -eq 0 ]
  grep -q '^display-message canopy: a save is already running, this one was skipped$' "$BATS_TEST_TMPDIR/tmux-calls"
  wait "$auto"
  : >"$BATS_TEST_TMPDIR/tmux-calls"
  # M-s holds the lock; continuum's autosave starts during it.
  "$wrapper" &
  manual=$!
  for _ in $(seq 1 50); do [ "$(grep -c '^start' "$runs")" -eq 2 ] && break; sleep 0.1; done
  run "$wrapper" quiet
  [ "$status" -eq 0 ]
  wait "$manual"
  [ "$(grep -c '^start' "$runs")" -eq 2 ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 2 ]
  ! grep -q '^display-message' "$BATS_TEST_TMPDIR/tmux-calls"
}

@test "M-s runs the wrapper: the key table, tmux.conf after the loader, and the grofe fragment" {
  grep -q $'^save-now\tM-s\t-\trun-shell "$CANOPY_STORE/plugins/strategies/canopy_save.sh"' "$CANOPY_STORE/tmux/keys.tsv"
  conf="$CANOPY_STORE/tmux/tmux.conf"
  loader="$(grep -n 'canopy_load_plugins' "$conf" | head -1 | cut -d: -f1)"
  bind="$(grep -n '^bind-key M-s run-shell "$CANOPY_STORE/plugins/strategies/canopy_save.sh"$' "$conf" | cut -d: -f1)"
  [ -n "$bind" ] && [ "$bind" -gt "$loader" ]
  for f in grofe/templates/30-canopy-plugins.toml grofe/conf.d/30-canopy-plugins.toml; do
    f="$CANOPY_STORE/$f"
    loader="$(grep -n 'canopy_load_plugins' "$f" | head -1 | cut -d: -f1)"
    bind="$(grep -n 'bind-key M-s run-shell .*plugins/strategies/canopy_save.sh' "$f" | cut -d: -f1)"
    [ -n "$bind" ] && [ "$bind" -gt "$loader" ]
  done
  grep -q 'M-s = { cmd = .run-shell "$CANOPY_STORE/plugins/strategies/canopy_save.sh"' "$CANOPY_STORE/grofe/conf.d/10-canopy-keys.toml"
}

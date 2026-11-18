#!/usr/bin/env bats
load helper

# `canopy remote`: where this machine lives, and the laptop's theme on attach.
#
# What is being protected: that a box says which machine and scope it is, on
# both backends, and that a laptop (where `canopy remote set` never ran) looks
# exactly as it did before; that the laptop's athome theme name, carried in
# the client's environment, is applied on the box through athome's own
# `theme`, and nothing else is; and that the per-machine files stay out of
# the shipped layers and out of `canopy grofe generate`'s way.
#
# athome's `theme` is never the real one here. It recolours the user's live
# terminal and writes their ~/.config, so every directory on PATH that holds
# a `theme` is dropped, HOME is a scratch directory, and a fake stands in.

setup() {
  setup_canopy_env
  setup_canopy_home
  unset CANOPY_THEME

  local d kept=""
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] && [ -e "$d/theme" ] && continue
    kept="${kept:+$kept:}$d"
  done
  PATH="$kept"
  unset IFS
  export PATH

  fake_dir="$BATS_TEST_TMPDIR/fake-theme"
  theme_log="$BATS_TEST_TMPDIR/theme.log"
  theme_state="$BATS_TEST_TMPDIR/theme.active"
  mkdir -p "$fake_dir"
  # The interface canopy uses, and no more: --list, --current, and a name.
  cat >"$fake_dir/theme" <<EOF
#!/bin/sh
case "\$1" in
  --list) printf 'gruvbox\neverforest\n' ;;
  --current) cat '$theme_state' 2>/dev/null || echo gruvbox ;;
  *) printf '%s\n' "\$1" >'$theme_state'; printf 'applied %s\n' "\$1" >>'$theme_log' ;;
esac
EOF
  chmod +x "$fake_dir/theme"

  tmux_file="$CANOPY_STATE/25-remote.conf"
  grofe_file="$XDG_CONFIG_HOME/grofe/conf.d/25-remote.toml"
  sock="cnp-remote-$$-${BATS_TEST_NUMBER}"
  # The suite's guarded tmux, kept for the outer terminal server: the grofe
  # tests put a `tmux` that is grofe in front of it.
  shim_tmux="$(command -v tmux)"
  outer=""
  gsock=""
}

teardown() {
  [ -n "${outer:-}" ] && kill_tmux_server "$outer"
  [ -n "${sock:-}" ] && kill_tmux_server "$sock"
  [ -n "${gsock:-}" ] && "$grofe_bin" -L "$gsock" kill-server >/dev/null 2>&1
  return 0
}

remote_set() {
  canopy-remote set --machine acme-dev --scope work/acme --color yellow
}

# A server on this test's socket, loading canopy's whole entry point, with
# the fake theme first on the PATH its jobs inherit.
start_tmux() {
  PATH="$fake_dir:$PATH" tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d -s boot
  sock_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
}

# wait_for_log <line>: up to ten seconds for the fake theme to log <line>.
wait_for_log() {
  local i
  for i in $(seq 1 50); do
    grep -qxF "$1" "$theme_log" 2>/dev/null && return 0
    sleep 0.2
  done
  printf 'theme log never said [%s]; it holds:\n' "$1"
  cat "$theme_log" 2>/dev/null || printf '(nothing)\n'
  return 1
}

# A client needs a terminal. A pane of a second scratch server is one.
in_terminal() {
  outer="cnp-remote-outer-$$-${BATS_TEST_NUMBER}"
  "$shim_tmux" -L "$outer" -f /dev/null new-session -d -x 100 -y 30 "$1; sleep 30"
}

# A grofe server on this test's socket with every shipped fragment and
# whatever 25-remote.toml holds. Bare `tmux` in its jobs is grofe, as on a
# machine that switched, and the fake theme is on their PATH.
start_grofe() {
  mkdir -p "$XDG_CONFIG_HOME/grofe/conf.d"
  cp "$CANOPY_STORE"/grofe/conf.d/*.toml "$XDG_CONFIG_HOME/grofe/conf.d/"
  mkdir -p "$BATS_TEST_TMPDIR/grofe-path"
  ln -sf "$grofe_bin" "$BATS_TEST_TMPDIR/grofe-path/tmux"
  PATH="$BATS_TEST_TMPDIR/grofe-path:$fake_dir:$PATH" SHELL=/bin/sh \
    "$grofe_bin" -L "$gsock" new-session -d -s boot
}

segment_of() {
  local line seg
  line="$(grep -F '#{?@canopy_machine,' "$1")"
  [ -n "$line" ] || return 1
  seg="${line#*'#{?@canopy_machine,'}"
  printf '%s\n' "${seg%%',}'*}"
}

need_grofe() {
  grofe_bin="$(command -v "${CANOPY_GROFE:-grofe}" 2>/dev/null || true)"
  if [ -z "$grofe_bin" ] || [ ! -x "$grofe_bin" ]; then
    skip "no grofe binary: set CANOPY_GROFE to one"
  fi
  # A short runtime directory: grofe's socket lives there, and a socket path
  # is capped at about 104 bytes.
  XDG_RUNTIME_DIR="$CANOPY_SCRATCH_TMPDIR/run-xdg"
  XDG_STATE_HOME="$CANOPY_SCRATCH_TMPDIR/state-xdg"
  export XDG_RUNTIME_DIR XDG_STATE_HOME
  (umask 077 && mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME")
  gsock="cnpg-$$-${BATS_TEST_NUMBER}"
}

# --- the command -------------------------------------------------------------

@test "set writes the tmux and grofe files and prints nothing" {
  run remote_set
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qxF 'set -g @canopy_machine "acme-dev"' "$tmux_file"
  grep -qxF 'set -g @canopy_scope "work/acme"' "$tmux_file"
  grep -qxF 'set -g @canopy_context_color "yellow"' "$tmux_file"
  grep -qxF 'set -g status-left-length 80' "$tmux_file"
  grep -qxF 'set -g set-titles on' "$tmux_file"
  grep -qxF 'canopy_machine = "acme-dev"' "$grofe_file"
  grep -qxF 'canopy_scope = "work/acme"' "$grofe_file"
  grep -qxF 'canopy_context_color = "yellow"' "$grofe_file"
  grep -qxF 'left-length = 80' "$grofe_file"
  grep -qxF 'set-titles = true' "$grofe_file"
}

@test "set twice writes byte-identical files" {
  remote_set
  first_t="$(cat "$tmux_file")"
  first_g="$(cat "$grofe_file")"
  remote_set
  [ "$first_t" = "$(cat "$tmux_file")" ]
  [ "$first_g" = "$(cat "$grofe_file")" ]
}

@test "set again replaces the values" {
  remote_set
  canopy-remote set --machine beta-dev --scope work/acme --color yellow
  grep -qF 'beta-dev' "$tmux_file"
  grep -qF 'beta-dev' "$grofe_file"
  run grep -lF 'acme-dev' "$tmux_file" "$grofe_file"
  [ "$status" -eq 1 ]
}

@test "set without a colour is refused with the usage, and writes nothing" {
  run canopy-remote set --machine acme-dev --scope work/acme
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: usage: canopy remote set --machine <name> --scope <scope> --color <colour> | clear" ]
  [ ! -e "$tmux_file" ]
  [ ! -e "$grofe_file" ]
}

@test "values that could break the files are refused, by flag, and nothing is written" {
  run canopy-remote set --machine 'a"b' --scope work/acme --color yellow
  [ "$status" -eq 1 ]
  [[ "$output" == *"--machine"* ]]
  run canopy-remote set --machine acme-dev --scope 'work/$x' --color yellow
  [ "$status" -eq 1 ]
  [[ "$output" == *"--scope"* ]]
  run canopy-remote set --machine acme-dev --scope work/acme --color purple
  [ "$status" -eq 1 ]
  [[ "$output" == *"--color"* ]]
  run canopy-remote set --machine acme-dev --scope work/acme --color '#ff0000'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--color"* ]]
  [ ! -e "$tmux_file" ]
  [ ! -e "$grofe_file" ]
}

@test "an unknown argument is refused the way every command refuses one" {
  run canopy-remote set --bogus x
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: canopy-remote: unknown argument: --bogus" ]
}

@test "no subcommand, or an unknown one, prints the usage" {
  run canopy-remote
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: usage: canopy remote set --machine <name> --scope <scope> --color <colour> | clear" ]
  run canopy-remote frob
  [ "$status" -eq 1 ]
  [ "$output" = "canopy: usage: canopy remote set --machine <name> --scope <scope> --color <colour> | clear" ]
}

@test "clear removes both files, is quiet when they are gone, and leaves the rest of conf.d" {
  remote_set
  printf 'mouse = true\n' >"$XDG_CONFIG_HOME/grofe/conf.d/99-mine.toml"
  run canopy-remote clear
  [ "$status" -eq 0 ]
  [ ! -e "$tmux_file" ]
  [ ! -e "$grofe_file" ]
  run canopy-remote clear
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/grofe/conf.d/99-mine.toml" ]
}

# --- tmux --------------------------------------------------------------------

@test "tmux: after set, the indicator, the length and the title are on" {
  remote_set
  start_tmux
  [ "$(tmux -L "$sock" show -gv @canopy_machine)" = "acme-dev" ]
  [ "$(tmux -L "$sock" show -gv @canopy_scope)" = "work/acme" ]
  [ "$(tmux -L "$sock" show -gv @canopy_context_color)" = "yellow" ]
  [ "$(tmux -L "$sock" show -gv status-left-length)" = "80" ]
  [ "$(tmux -L "$sock" show -gv set-titles)" = "on" ]
  [ "$(tmux -L "$sock" show -gv set-titles-string)" = '#{@canopy_machine} · #S' ]
  left="$(tmux -L "$sock" display-message -p '#{T:status-left}')"
  [[ "$left" == '#[fg=yellow]#[bg=default]#[bold]acme-dev · work/acme #[nobold]#[fg=#458588'* ]]
}

@test "tmux: where set never ran, nothing changes" {
  start_tmux
  [ -z "$(tmux -L "$sock" show -gv @canopy_machine 2>/dev/null)" ]
  [ "$(tmux -L "$sock" show -gv status-left-length)" = "40" ]
  [ "$(tmux -L "$sock" show -gv set-titles)" = "off" ]
  left="$(tmux -L "$sock" display-message -p '#{T:status-left}')"
  [[ "$left" == '#[fg=#458588'* ]]
}

@test "tmux: after set then clear, nothing changes" {
  remote_set
  canopy-remote clear
  start_tmux
  [ -z "$(tmux -L "$sock" show -gv @canopy_machine 2>/dev/null)" ]
  [ "$(tmux -L "$sock" show -gv status-left-length)" = "40" ]
  [ "$(tmux -L "$sock" show -gv set-titles)" = "off" ]
  left="$(tmux -L "$sock" display-message -p '#{T:status-left}')"
  [[ "$left" == '#[fg=#458588'* ]]
}

@test "tmux: set carries CANOPY_THEME once however often the config loads, and hooks the attach" {
  start_tmux
  [[ "$(tmux -L "$sock" show -g update-environment)" != *CANOPY_THEME* ]]
  [[ "$(tmux -L "$sock" show-hooks -g)" != *canopy-remote* ]]
  kill_tmux_server "$sock"

  remote_set
  start_tmux
  tmux -L "$sock" source-file "$CANOPY_STORE/tmux/tmux.conf"
  [ "$(tmux -L "$sock" show -g update-environment | grep -c CANOPY_THEME)" = "1" ]
  tmux -L "$sock" show -gv 'update-environment[90]' | grep -qx CANOPY_THEME
  hooks="$(tmux -L "$sock" show-hooks -g)"
  [[ "$hooks" == *'client-attached[90] '*canopy-remote*follow-theme* ]]
  [[ "$hooks" == *'after-new-session[90] '*canopy-remote*follow-theme* ]]
}

@test "the segment is text on the default background in both status layers" {
  for f in "$CANOPY_STORE/tmux/conf.d/20-status.conf" "$CANOPY_STORE/grofe/templates/20-canopy-status.toml"; do
    seg="$(segment_of "$f")"
    [ -n "$seg" ]
    [[ "$seg" != *theme_bg* ]]
    [[ "$seg" != *'bg=#{'* ]]
  done
}

@test "tmux: a client creating its session applies the laptop's theme" {
  remote_set
  start_tmux
  in_terminal "env -u TMUX -u TMUX_PANE CANOPY_THEME=everforest tmux -L $sock new-session -s main"
  wait_for_log "applied everforest"
}

@test "tmux: a client attaching to an existing session applies the laptop's theme" {
  remote_set
  start_tmux
  tmux -L "$sock" new-session -d -s main
  in_terminal "env -u TMUX -u TMUX_PANE CANOPY_THEME=everforest tmux -L $sock attach-session -t main"
  wait_for_log "applied everforest"
  [ "$(grep -c . "$theme_log")" = "1" ]
}

# --- follow-theme ------------------------------------------------------------

# A server holding session main, and follow-theme run against it the way a
# hook's job runs: TMUX names the server, the fake theme is on PATH.
follow() {
  TMUX="$sock_path,0,0" PATH="$fake_dir:$PATH" canopy-remote follow-theme main
}

@test "follow-theme reads the session's value, not the server's" {
  start_tmux
  tmux -L "$sock" new-session -d -s main
  tmux -L "$sock" set-environment -t main CANOPY_THEME everforest
  tmux -L "$sock" set-environment -g CANOPY_THEME nosuch
  run follow
  [ "$status" -eq 0 ]
  [ "$(cat "$theme_log")" = "applied everforest" ]
}

@test "follow-theme leaves the theme alone for an unknown, current, unsafe or missing name" {
  start_tmux
  tmux -L "$sock" new-session -d -s main
  for v in nosuch gruvbox 'a;b' '../x'; do
    tmux -L "$sock" set-environment -t main CANOPY_THEME "$v"
    run follow
    [ "$status" -eq 0 ]
  done
  tmux -L "$sock" set-environment -t main -u CANOPY_THEME
  run follow
  [ "$status" -eq 0 ]
  [ ! -e "$theme_log" ]
}

@test "follow-theme without athome's theme does nothing; it finds one in ~/.local/bin" {
  start_tmux
  tmux -L "$sock" new-session -d -s main
  tmux -L "$sock" set-environment -t main CANOPY_THEME everforest
  run env TMUX="$sock_path,0,0" canopy-remote follow-theme main
  [ "$status" -eq 0 ]
  [ ! -e "$theme_log" ]

  mkdir -p "$HOME/.local/bin"
  cp "$fake_dir/theme" "$HOME/.local/bin/theme"
  run env TMUX="$sock_path,0,0" canopy-remote follow-theme main
  [ "$status" -eq 0 ]
  [ "$(cat "$theme_log")" = "applied everforest" ]
}

@test "follow-theme needs a session" {
  run canopy-remote follow-theme
  [ "$status" -eq 1 ]
  [[ "$output" == "canopy: usage: "* ]]
}

# --- grofe -------------------------------------------------------------------

@test "grofe: the fragments with 25-remote.toml load, and set the length and keep the plugin layer" {
  need_grofe
  remote_set
  cp "$CANOPY_STORE"/grofe/conf.d/*.toml "$XDG_CONFIG_HOME/grofe/conf.d/"
  run canopy-grofe validate "$XDG_CONFIG_HOME/grofe/conf.d"
  [ "$status" -eq 0 ]
  run "$grofe_bin" show-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"status.left-length = 80"* ]]
  [[ "$output" == *"canopy_load_plugins"* ]]
  [[ "$output" == *"set-titles = true"* ]]
  [[ "$output" == *'set-titles-string = "#{@canopy_machine} · #{session_name}"'* ]]
}

@test "grofe: where set never ran, or after clear, nothing changes" {
  need_grofe
  mkdir -p "$XDG_CONFIG_HOME/grofe/conf.d"
  cp "$CANOPY_STORE"/grofe/conf.d/*.toml "$XDG_CONFIG_HOME/grofe/conf.d/"
  for step in never cleared; do
    if [ "$step" = cleared ]; then
      remote_set
      canopy-remote clear
    fi
    run "$grofe_bin" show-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"status.left-length = 40"* ]]
    [[ "$output" == *"set-titles = false"* ]]
    [[ "$output" != *CANOPY_THEME* ]]
    [[ "$output" != *canopy-remote* ]]
  done
}

@test "grofe: generate leaves 25-remote.toml alone, and writes the same with or without it" {
  remote_set
  before="$(cat "$grofe_file")"
  run canopy-grofe generate
  [ "$status" -eq 0 ]
  [ "$before" = "$(cat "$grofe_file")" ]
  canopy-grofe generate --out "$BATS_TEST_TMPDIR/gen"
  run diff -ru "$CANOPY_STORE/grofe/conf.d" "$BATS_TEST_TMPDIR/gen"
  [ "$status" -eq 0 ]
}

@test "grofe: a client creating its session applies the laptop's theme, and the bar says where" {
  need_grofe
  remote_set
  start_grofe
  in_terminal "env -u TMUX -u TMUX_PANE CANOPY_THEME=everforest SHELL=/bin/sh '$grofe_bin' -L $gsock new-session -s main"
  wait_for_log "applied everforest"
  left="$("$grofe_bin" -L "$gsock" display-message -p -t main '#{T:status-left}')"
  [[ "$left" == *'#[fg=yellow]#[bg=default]#[bold]acme-dev · work/acme #[nobold]'* ]]
}

@test "grofe: a client attaching to an existing session applies the laptop's theme" {
  need_grofe
  remote_set
  start_grofe
  SHELL=/bin/sh "$grofe_bin" -L "$gsock" new-session -d -s main
  in_terminal "env -u TMUX -u TMUX_PANE CANOPY_THEME=everforest '$grofe_bin' -L $gsock attach-session -t main"
  wait_for_log "applied everforest"
  [ "$(grep -c . "$theme_log")" = "1" ]
}

# --- edge cases --------------------------------------------------------------

@test "tmux: a session name with a space and a quote reaches follow-theme as one argument" {
  remote_set
  start_tmux
  in_terminal "env -u TMUX -u TMUX_PANE CANOPY_THEME=everforest tmux -L $sock new-session -s \"a b'c\""
  wait_for_log "applied everforest"
}

@test "follow-theme exits 0 when theme itself fails" {
  start_tmux
  tmux -L "$sock" new-session -d -s main
  tmux -L "$sock" set-environment -t main CANOPY_THEME everforest
  printf '#!/bin/sh\ncase "$1" in --list) echo everforest ;; --current) echo gruvbox ;; *) exit 3 ;; esac\n' >"$fake_dir/theme"
  run follow
  [ "$status" -eq 0 ]
}

@test "the same flag twice: the last one wins" {
  canopy-remote set --machine one --machine acme-dev --scope work/acme --color yellow
  grep -qxF 'set -g @canopy_machine "acme-dev"' "$tmux_file"
}

@test "with XDG_CONFIG_HOME unset the grofe file goes under ~/.config" {
  unset XDG_CONFIG_HOME
  remote_set
  [ -f "$HOME/.config/grofe/conf.d/25-remote.toml" ]
  canopy-remote clear
  [ ! -e "$HOME/.config/grofe/conf.d/25-remote.toml" ]
}

@test "a set that cannot write the grofe file leaves the tmux file unwritten too" {
  mkdir -p "$XDG_CONFIG_HOME/grofe"
  : >"$XDG_CONFIG_HOME/grofe/conf.d"
  run remote_set
  [ "$status" -ne 0 ]
  [ ! -e "$tmux_file" ]
  ls "$CANOPY_STATE" | grep -q tmp && false
  return 0
}

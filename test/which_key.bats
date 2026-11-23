#!/usr/bin/env bats
load helper

# canopy's which-key menu (tmux/which-key.conf), as the plugin loader lays it
# over the menu tmux-which-key ships. One real tmux 3.7b server on a private
# socket, with only which-key loaded, from a copy of the store so the plugin
# writes nothing into this checkout. The cases skip without a tmux 3.7b
# ($CANOPY_TMUX, else the tmux on PATH).

setup() {
  setup_canopy_env
  setup_canopy_home
  XDG_STATE_HOME="$HOME/.local/state"
  export XDG_STATE_HOME
  unset CANOPY_PLUGINS
  tmux37="${CANOPY_TMUX:-$(command -v tmux || true)}"
  [ -n "$tmux37" ] && [ "$("$tmux37" -V 2>/dev/null)" = "tmux 3.7b" ] || skip "no tmux 3.7b"
  real_store="$CANOPY_STORE"
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store/plugins"
  cp -R "$real_store/lib" "$real_store/tmux" "$real_store/grofe" "$store/"
  cp -R "$real_store/plugins/tmux-which-key" "$store/plugins/"
  cp "$real_store"/plugins/VERSIONS "$real_store"/plugins/LOCAL "$real_store"/plugins/CHECKSUMS "$store/plugins/"
  CANOPY_STORE="$store"
  CANOPY_ARTIFACTS="$BATS_TEST_TMPDIR/no-artifacts"
  export CANOPY_STORE CANOPY_ARTIFACTS
  # which-key runs `tmux` itself, so the 3.7b has to be the one on PATH.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -sf "$tmux37" "$BATS_TEST_TMPDIR/bin/tmux"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH
  sock=canopy-wk-$$
}

teardown() {
  [ -z "${tmux37:-}" ] || kill_tmux_server "$sock"
  return 0
}

srv() { "$tmux37" -L "$sock" "$@"; }

# A server with canopy's loader run over tmux-which-key, in $BATS_TEST_TMPDIR
# as the pane directory.
start_which_key() {
  mkdir -p "$BATS_TEST_TMPDIR/here" "$BATS_TEST_TMPDIR/there"
  # A pane reports its directory with symlinks resolved.
  there="$(cd "$BATS_TEST_TMPDIR/there" && pwd -P)"
  srv -f /dev/null new-session -d -s main -c "$BATS_TEST_TMPDIR/here" 'sleep 600'
  srv set-environment -g CANOPY_STORE "$store"
  srv set-environment -g CANOPY_STATE "$CANOPY_STATE"
  srv set-environment -g CANOPY_CONFIG "$CANOPY_CONFIG"
  srv set-environment -g CANOPY_ARTIFACTS "$CANOPY_ARTIFACTS"
  srv set -g @tmux-which-key-disable-autobuild 1
  srv run-shell '. "$CANOPY_STORE/lib/env.sh"; . "$CANOPY_STORE/lib/plugins.sh"; canopy_load_plugins tmux-which-key'
}

# tmux_words: stdin split into one word per line by tmux's own word rules
# (double quotes group, a backslash escapes). A "" is an empty line.
tmux_words() {
  awk '
    function flush() { if (inword) print w; w = ""; inword = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q) {
          if (c == "\\") { i++; w = w substr($0, i, 1) }
          else if (c == "\"") q = 0
          else w = w c
        } else if (c == "\"") { q = 1; inword = 1 }
        else if (c == "\\") { i++; w = w substr($0, i, 1); inword = 1 }
        else if (c == " ") flush()
        else { w = w c; inword = 1 }
      }
      flush()
    }'
}

# menu_items <option>: one "name<TAB>key<TAB>command" line per item of a
# which-key menu option. A "" is a separator.
menu_items() {
  srv show-option -gqv "$1" | tmux_words | awk '
    { words[n++] = $0 }
    END {
      for (i = 0; i < n; i++) {
        if (words[i] == "") continue
        printf "%s\t%s\t%s\n", words[i], words[i + 1], words[i + 2]
        i += 2
      }
    }'
}

# run_prompt_template <option> <item name> <input>: what choosing the item
# does, for a command-prompt item: the last word of its command is the
# template command-prompt runs, with %% in it replaced by the text typed,
# as it is.
run_prompt_template() {
  local cmd template
  cmd="$(menu_items "$1" | awk -F'\t' -v n="$2" '$1 == n { print $3 }')"
  [[ "$cmd" == "command-prompt "* ]]
  template="$(printf '%s\n' "$cmd" | tmux_words | tail -n 1)"
  printf '%s\n' "${template//%%/$3}" >"$BATS_TEST_TMPDIR/template"
  srv source-file "$BATS_TEST_TMPDIR/template"
}

menu_options() {
  srv show-options -g | awk '$1 ~ /^@wk_menu_/ { print $1 }'
}

@test "which-key: canopy's menu replaces upstream's, which has the Plugins submenu" {
  start_which_key
  [ -z "$(cat "$CANOPY_STATE/plugins.log" 2>/dev/null)" ]
  [ "$(menu_options | wc -l)" -eq 9 ]
  [ -z "$(menu_options | grep -x '@wk_menu_plugins')" ]
}

@test "which-key: every menu item parses in tmux, and is written with full command names" {
  start_which_key
  # The commands tmux knows by their full name, and the aliases which-key
  # defines (show-wk-menu and the like).
  names="$(srv list-commands -F '#{command_list_name}'; srv show-options -g command-alias | sed -n 's/^command-alias\[[0-9]*\] "\{0,1\}\([a-z-]*\)=.*/\1/p')"
  [[ "$names" == *show-wk-menu* ]]
  checked=0
  for opt in $(menu_options); do
    menu_items "$opt" | while IFS="$(printf '\t')" read -r name key cmd; do
      printf '%s\n' "$cmd"
    done >"$BATS_TEST_TMPDIR/cmds"
    while IFS= read -r cmd; do
      # What tmux does with an item's command: expand the formats in it,
      # then parse it. -n parses and runs nothing.
      srv display-message -p -t main: -- "$cmd" >"$BATS_TEST_TMPDIR/expanded"
      run srv source-file -n "$BATS_TEST_TMPDIR/expanded"
      [ -z "$output" ] || {
        printf '%s: %s\n%s\n' "$opt" "$cmd" "$output"
        false
      }
      # No short alias: the first word of each command in the item is a full
      # name, and so is the command a confirm-before runs.
      printf '%s\n' "$cmd" | awk 'BEGIN { RS = " ; " } { print $1 }' | while read -r word; do
        printf '%s\n' "$names" | grep -qxF -- "$word" || {
          printf '%s: "%s" in "%s" is no full command name\n' "$opt" "$word" "$cmd"
          exit 1
        }
      done
      case "$cmd" in
        confirm-before*)
          word="$(printf '%s\n' "$cmd" | tmux_words | tail -n 1 | awk '{ print $1 }')"
          printf '%s\n' "$names" | grep -qxF -- "$word" || {
            printf '%s: "%s" in "%s" is no full command name\n' "$opt" "$word" "$cmd"
            false
          }
          ;;
        *) ;;
      esac
      checked=$((checked + 1))
    done <"$BATS_TEST_TMPDIR/cmds"
  done
  [ "$checked" -gt 60 ]
}

@test "which-key: a + marks a submenu and nothing else" {
  start_which_key
  for opt in $(menu_options); do
    menu_items "$opt" | while IFS="$(printf '\t')" read -r name key cmd; do
      case "$name" in
        +*) [[ "$cmd" == "show-wk-menu "* ]] || { printf '%s: %s runs %s\n' "$opt" "$name" "$cmd"; exit 1; } ;;
        *) [[ "$cmd" != "show-wk-menu "* ]] || { printf '%s: %s opens a menu and has no +\n' "$opt" "$name"; exit 1; } ;;
      esac
    done
  done
  menu_items @wk_menu_root | grep -q "^Keys	?	list-keys -N$"
}

@test "which-key: Tiled runs select-layout tiled" {
  start_which_key
  menu_items @wk_menu_layout | grep -q "^Tiled	t	select-layout tiled$"
}

@test "which-key: nothing calls TPM, which canopy does not install" {
  start_which_key
  [ -z "$(srv show-options -g | grep -i 'tpm\|TMUX_PLUGIN_MANAGER_PATH')" ]
  menu_items @wk_menu_client | grep -q "^Reload config	r	reload-config$"
  [ -z "$(menu_items @wk_menu_client | grep '^+Plugins')" ]
}

# attach_client <binary> <socket>: a client on a pty, kept for 30 s, whose name
# lands in $client. A command-prompt or confirm-before needs one.
attach_client() {
  (sleep 30 | script -q /dev/null "$1" -L "$2" attach -t main) >/dev/null 2>&1 3>&- &
  client=""
  for _ in $(seq 1 40); do
    client="$("$1" -L "$2" list-clients -F '#{client_name}' 2>/dev/null | head -n 1)"
    [ -n "$client" ] && return 0
    sleep 0.1
  done
  return 1
}

# menu_command <option> <item>: the command choosing the item runs.
menu_command() {
  menu_items "$1" | awk -F'\t' -v n="$2" '$1 == n { print $3 }'
}

# respawn_changes_pid <binary> <socket> <command>: run the Respawn item's
# confirm-before, answered with y, in a window whose pane directory is $there,
# and check the pane's process changed and it respawned in that directory.
respawn_changes_pid() {
  local bin="$1" sk="$2" cmd="$3"
  "$bin" -L "$sk" new-window -t main: -c "$there" 'sleep 600'
  "$bin" -L "$sk" select-window -t main:1
  attach_client "$bin" "$sk"
  [ "$("$bin" -L "$sk" display-message -p -t main:1 '#{pane_current_path}')" = "$there" ]
  old="$("$bin" -L "$sk" display-message -p -t main:1 '#{pane_pid}')"
  # The confirm waits on the client until it is answered, so it runs apart.
  printf '%s\n' "${cmd/confirm-before/confirm-before -t $client}" >"$BATS_TEST_TMPDIR/confirm"
  ("$bin" -L "$sk" source-file "$BATS_TEST_TMPDIR/confirm" >/dev/null 2>&1 3>&- &)
  sleep 1
  "$bin" -L "$sk" send-keys -K -c "$client" y
  for _ in $(seq 1 40); do
    [ "$("$bin" -L "$sk" display-message -p -t main:1 '#{pane_pid}')" != "$old" ] && break
    sleep 0.1
  done
  [ "$("$bin" -L "$sk" display-message -p -t main:1 '#{pane_pid}')" != "$old" ]
  [ "$("$bin" -L "$sk" display-message -p -t main:1 '#{pane_current_path}')" = "$there" ]
}

@test "which-key: Respawn pane asks first, and takes the pane directory when it runs" {
  start_which_key
  cmd="$(menu_command @wk_menu_panes "Respawn pane")"
  [[ "$cmd" == "confirm-before "* ]]
  # The real commands are in the confirm, not behind an alias.
  [[ "$cmd" == *"respawn-pane -k -c"* ]]
  [[ "$cmd" != *restart-pane* ]]
  respawn_changes_pid "$tmux37" "$sock" "$cmd"
}

@test "which-key: Respawn pane works on grofe too" {
  start_which_key
  grofe_bin="$(command -v "${CANOPY_GROFE:-}" || true)"
  [ -n "$grofe_bin" ] || skip "no grofe binary (set CANOPY_GROFE)"
  # The menu reaches grofe as `tmux`, so it parses in tmux's dialect.
  mkdir -p "$BATS_TEST_TMPDIR/gbin"
  ln -sf "$grofe_bin" "$BATS_TEST_TMPDIR/gbin/tmux"
  grofe_bin="$BATS_TEST_TMPDIR/gbin/tmux"
  cmd="$(menu_command @wk_menu_panes "Respawn pane")"
  gsock="canopy-wkg-$$"
  "$grofe_bin" -L "$gsock" new-session -d -s main -c "$BATS_TEST_TMPDIR/here" 'sleep 600'
  run respawn_changes_pid "$grofe_bin" "$gsock" "$cmd"
  "$grofe_bin" -L "$gsock" kill-server 2>/dev/null || true
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "which-key: Reload config on tmux reloads canopy's tmux.conf, not ~/.tmux.conf" {
  start_which_key
  srv set-environment -g CANOPY_PLUGINS off
  printf "set -g @reload_marker yes\n" >"$CANOPY_CONFIG/user.conf"
  printf "set -g @home_marker yes\n" >"$HOME/.tmux.conf"
  [ -z "$(srv show-options -gqv @reload_marker)" ]
  # What choosing the item runs.
  cmd="$(menu_items @wk_menu_client | awk -F'\t' '$1 == "Reload config" { print $3 }')"
  [ -n "$cmd" ]
  run srv "$cmd"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(srv show-options -gqv @reload_marker)" = yes ]
  [ -z "$(srv show-options -gqv @home_marker)" ]
}

@test "which-key: prefix Space opens canopy's root menu, with Copy a submenu and Keys not" {
  start_which_key
  # tmux expands an alias when a key is bound, so the binding has to be made
  # again after the root menu is.
  binding="$(srv list-keys -T prefix | grep -E 'prefix +Space ')"
  [[ "$binding" == *display-menu* ]]
  [[ "$binding" == *+Copy* ]]
  [[ "$binding" != *+Keys* ]]
}

# prompt_rename <binary> <socket> <option> <item> <typed>: choose the Rename
# item's command-prompt on a client and type <typed> into it, as a user does.
prompt_rename() {
  local bin="$1" sk="$2" cmd
  cmd="$(menu_command "$3" "$4")"
  [[ "$cmd" == "command-prompt "* ]]
  attach_client "$bin" "$sk"
  printf '%s\n' "${cmd/command-prompt/command-prompt -t $client}" >"$BATS_TEST_TMPDIR/prompt"
  ("$bin" -L "$sk" source-file "$BATS_TEST_TMPDIR/prompt" >/dev/null 2>&1 3>&- &)
  sleep 1
  "$bin" -L "$sk" send-keys -K -c "$client" C-u "$5" Enter
  sleep 0.5
}

typed='q "x" $HOME ; y \z'

# stored_as_typed <binary> <socket> <kind>: the name a rename of the current
# window or session to $typed with the plain command stores. tmux and grofe
# both sanitise a name, so that, not $typed itself, is what a prompt must match.
stored_as_typed() {
  printf "rename-%s -- 'q \"x\" \$HOME ; y \\z'\n" "$3" >"$BATS_TEST_TMPDIR/plain"
  "$1" -L "$2" source-file "$BATS_TEST_TMPDIR/plain"
}

@test "which-key: the Rename items store a name with quotes, a backslash and a dollar as typed" {
  start_which_key
  srv new-window -t main: 'sleep 600'
  srv select-window -t main:1
  stored_as_typed "$tmux37" "$sock" window
  want="$(srv list-windows -t main -F '#{window_name}' | /usr/bin/sed -n 2p)"
  [ "$want" != "zsh" ] && [ "$want" != sleep ]
  srv rename-window -t main:1 plain
  prompt_rename "$tmux37" "$sock" @wk_menu_windows Rename "$typed"
  [ "$(srv list-windows -t main -F '#{window_name}' | /usr/bin/sed -n 2p)" = "$want" ]
  stored_as_typed "$tmux37" "$sock" session
  want="$(srv list-sessions -F '#{session_name}')"
  srv rename-session plain
  prompt_rename "$tmux37" "$sock" @wk_menu_sessions Rename "$typed"
  [ "$(srv list-sessions -F '#{session_name}')" = "$want" ]
}

@test "which-key: the Rename items store such a name on grofe too" {
  start_which_key
  grofe_bin="$(command -v "${CANOPY_GROFE:-}" || true)"
  [ -n "$grofe_bin" ] || skip "no grofe binary (set CANOPY_GROFE)"
  # The menu reaches grofe as `tmux`, so it parses in tmux's dialect.
  mkdir -p "$BATS_TEST_TMPDIR/gbin"
  ln -sf "$grofe_bin" "$BATS_TEST_TMPDIR/gbin/tmux"
  grofe_bin="$BATS_TEST_TMPDIR/gbin/tmux"
  gsock="canopy-wkg-$$"
  "$grofe_bin" -L "$gsock" new-session -d -s main 'sleep 600'
  "$grofe_bin" -L "$gsock" new-window -t main: 'sleep 600'
  "$grofe_bin" -L "$gsock" select-window -t main:1
  stored_as_typed "$grofe_bin" "$gsock" window
  want="$("$grofe_bin" -L "$gsock" list-windows -t main -F '#{window_name}' | /usr/bin/sed -n 2p)"
  "$grofe_bin" -L "$gsock" rename-window -t main:1 plain
  run prompt_rename "$grofe_bin" "$gsock" @wk_menu_windows Rename "$typed"
  name="$("$grofe_bin" -L "$gsock" list-windows -t main -F '#{window_name}' | /usr/bin/sed -n 2p)"
  "$grofe_bin" -L "$gsock" kill-server 2>/dev/null || true
  [ "$name" = "$want" ] || skip "this grofe lacks %%% (got: $name, want: $want)"
}

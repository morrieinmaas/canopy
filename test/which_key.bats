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

# menu_items <option>: one "name<TAB>key<TAB>command" line per item of a
# which-key menu option, split by tmux's own word rules (double quotes group,
# a backslash escapes). A "" is a separator.
menu_items() {
  srv show-option -gqv "$1" | awk '
    function flush() { if (inword) words[n++] = w; w = ""; inword = 0 }
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
    }
    END {
      for (i = 0; i < n; i++) {
        if (words[i] == "") continue
        printf "%s\t%s\t%s\n", words[i], words[i + 1], words[i + 2]
        i += 2
      }
    }'
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
          word="${cmd##* }"
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

@test "which-key: Respawn pane asks first, and takes the pane directory when it runs" {
  start_which_key
  menu_items @wk_menu_panes | grep -q "^Respawn pane	R	confirm-before .*restart-pane$"
  # The alias keeps the format for the pane it runs in. -gF would have
  # replaced it with the directory of whatever pane was current at load.
  srv show-options -g command-alias | grep -F 'restart-pane=' | grep -qF '#{pane_current_path}'
  # The window the alias runs in is the session's current one.
  srv new-window -t main: -c "$there" 'sleep 600'
  [ "$(srv display-message -p -t main:1 '#{pane_current_path}')" = "$there" ]
  old="$(srv display-message -p -t main:1 '#{pane_pid}')"
  srv restart-pane
  for _ in $(seq 1 40); do
    [ "$(srv display-message -p -t main:1 '#{pane_pid}')" != "$old" ] && break
    sleep 0.1
  done
  [ "$(srv display-message -p -t main:1 '#{pane_pid}')" != "$old" ]
  [ "$(srv display-message -p -t main:1 '#{pane_current_path}')" = "$there" ]
}

@test "which-key: Reload config on tmux reloads canopy's tmux.conf, not ~/.tmux.conf" {
  start_which_key
  srv set-environment -g CANOPY_PLUGINS off
  printf "set -g @reload_marker yes\n" >"$CANOPY_CONFIG/user.conf"
  [ -z "$(srv show-options -gqv @reload_marker)" ]
  srv show-options -g command-alias | grep -F 'reload-config=' | grep -qF 'tmux/tmux.conf'
  [ -z "$(srv show-options -g command-alias | grep -F 'reload-config=' | grep -F '.tmux.conf')" ]
  srv reload-config
  [ "$(srv show-options -gqv @reload_marker)" = yes ]
}

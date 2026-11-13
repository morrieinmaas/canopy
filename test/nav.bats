#!/usr/bin/env bats
load helper

# tmux/conf.d/40-nav.conf: vim-tmux-navigator's tmux side. The bindings are
# the plugin's own defaults; grofe/templates/40-canopy-nav.toml is the same
# layer for grofe, and the tests here hold the two to the same keys.
setup() {
  setup_canopy_env
  sock="canopy-test-nav-$$"
  conf="$CANOPY_STORE/tmux/conf.d/40-nav.conf"
  tmpl="$CANOPY_STORE/grofe/templates/40-canopy-nav.toml"
}

teardown() {
  kill_tmux_server "$sock"
}

# The listing line of one binding. list-keys prints a backslash key as C-\\,
# and the key argument form of list-keys is not used: tmux 3.7b answers it
# with nothing for a key bound in a config.
binding() {
  tmux -L "$sock" list-keys -T "$1" | awk -v t="$1" -v k="$2" '$3 == t && $4 == k'
}

# The condition of the first root binding, as written in the layer: the
# string between `if-shell "` and `" "send-keys`.
is_vim_condition() {
  awk '/^bind-key -n C-h / { sub(/^[^"]*"/, ""); sub(/" "send-keys.*$/, ""); print; exit }' "$conf"
}

@test "the shipped config binds the navigator's five root keys and five copy-mode-vi keys" {
  tmux -L "$sock" -f "$CANOPY_STORE/tmux/tmux.conf" new-session -d
  for table in root copy-mode-vi; do
    for k in C-h C-j C-k C-l 'C-\\\\'; do
      run binding "$table" "$k"
      [[ "$output" == *"select-pane"* ]] || { printf '%s missing %s\n' "$table" "$k"; false; }
    done
  done
  run binding prefix C-l
  [[ "$output" == *"send-keys C-l"* ]]
}

@test "each key goes the way grofe's nav fragment sends it" {
  tmux -L "$sock" -f /dev/null new-session -d
  tmux -L "$sock" source-file "$conf"
  for pair in 'C-h -L' 'C-j -D' 'C-k -U' 'C-l -R' 'C-\\ -l'; do
    key="${pair% *}" dir="${pair#* }"
    run binding root "${key/\\/\\\\}"
    [[ "$output" == *"select-pane $dir"* ]] || { printf 'tmux %s: %s\n' "$key" "$output"; false; }
    [[ "$output" == *"@tmux_navigator_disable_when_zoomed"* ]]
    # grofe: the same direction after the same key, in the root section.
    awk -v k="${key//\\/\\\\}" -v d="select-pane $dir'" '
      /^\[keys\.root\]/ { on = 1; next } /^\[/ { on = 0 }
      on && index($0, "\"" k "\" = ") == 1 || on && index($0, k " = ") == 1 { if (index($0, d)) found = 1 }
      END { exit !found }' "$tmpl" || { printf 'grofe has no %s %s\n' "$key" "$dir"; false; }
  done
}

@test "the condition sees Neovim, Vim and fzf on the pane's tty and nothing else" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  for p in nvim vim fzf less; do ln -s "$(command -v sleep)" "$BATS_TEST_TMPDIR/bin/$p"; done
  cond="$(is_vim_condition)"
  [ -n "$cond" ]
  tmux -L "$sock" -f /dev/null new-session -d -x 80 -y 24 "exec $BATS_TEST_TMPDIR/bin/less 60"
  tmux -L "$sock" set -g remain-on-exit off
  for p in nvim vim fzf; do
    tmux -L "$sock" new-window -d -n "$p" "exec $BATS_TEST_TMPDIR/bin/$p 60"
  done
  sleep 1
  for p in nvim vim fzf less; do
    target="$p"
    [ "$p" = less ] && target="0"
    tmux -L "$sock" set -g @r none
    tmux -L "$sock" if-shell -t ":$target" "$cond" "set -g @r vim" "set -g @r shell"
    got="$(tmux -L "$sock" show -gv @r)"
    case "$p" in
      less) [ "$got" = shell ] || { printf 'less: %s\n' "$got"; false; } ;;
      *) [ "$got" = vim ] || { printf '%s: %s\n' "$p" "$got"; false; } ;;
    esac
  done
}

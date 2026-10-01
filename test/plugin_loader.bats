#!/usr/bin/env bats
load helper

# The plugin loader: canopy_load_plugins in lib/plugins.sh, called from
# 30-plugins.conf on tmux and from the grofe plugin fragment's
# load-commands, over the ten vendored plugins.
#
# Every server here runs on a private socket in a short scratch directory,
# with a scratch $HOME and XDG tree, and loads from a copy of the store, so
# no plugin can write into this checkout or into anyone's real home. The
# tmux cases use a tmux 3.7b named by absolute path; the grofe cases need
# a grofe binary ($CANOPY_GROFE) and are skipped without one.
#
# Re-vendoring clones all eight upstreams from GitHub, so it runs only when
# CANOPY_TEST_VENDOR=1.

PLUGINS="tmux-resurrect tmux-continuum tmux-sensible tmux-yank tmux-fzf tmux-sessionx tmux-which-key opensessions tmux-fzf-url tmux-claude-session-manager"
NEW_EIGHT="tmux-sensible tmux-yank tmux-fzf tmux-sessionx tmux-which-key opensessions tmux-fzf-url tmux-claude-session-manager"

setup() {
  setup_canopy_env
  setup_canopy_home
  XDG_STATE_HOME="$HOME/.local/state"
  export XDG_STATE_HOME
  # tmux-which-key resolves its XDG directories with realpath, which needs
  # them to exist, as they do in any real home.
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/plugins.sh"
  real_store="$CANOPY_STORE"
  # Socket paths have a length limit that BATS_TEST_TMPDIR can exceed.
  socks="$(mktemp -d /tmp/cnp-tp3.XXXXXX)"
  mkdir -p "$socks/tmux" "$socks/xdg"
  chmod 700 "$socks/tmux" "$socks/xdg"
  TMUX_TMPDIR="$socks/tmux"
  XDG_RUNTIME_DIR="$socks/xdg"
  export TMUX_TMPDIR XDG_RUNTIME_DIR
  unset TMUX TMUX_PANE GROFE GROFE_PANE
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  PATH="$bin:$PATH"
  export PATH
  servers=""
}

teardown() {
  for s in $servers; do
    "${s%%:*}" -L "${s#*:}" kill-server >/dev/null 2>&1 || true
  done
  rm -rf "$socks"
  return 0
}

# The real tmux 3.7b, by absolute path; $CANOPY_TMUX names one.
need_tmux37() {
  tmux37="${CANOPY_TMUX:-$(command -v tmux || true)}"
  [ -n "$tmux37" ] && [ "$("$tmux37" -V 2>/dev/null)" = "tmux 3.7b" ] || skip "no tmux 3.7b"
}

need_grofe() {
  grofe_bin="$(command -v "${CANOPY_GROFE:-grofe}" || true)"
  [ -n "$grofe_bin" ] || skip "no grofe binary"
}

# A copy of the store, so a plugin that writes into its own tree, or a test
# that moves one aside, changes nothing in this checkout.
copy_store() {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store"
  for d in bin lib plugins tmux grofe; do
    cp -R "$real_store/$d" "$store/$d"
  done
  CANOPY_STORE="$store"
  export CANOPY_STORE
}

# What the plugins read before they load: claude-session-manager's keys
# as the owner sets them (its defaults take yank's y and fzf-url's u), and
# a status-right holding continuum's #{continuum_status}, which continuum
# replaces on load whether or not another server is running, and no
# continuum restore at start. On tmux they are set on the server before
# canopy's tmux.conf is sourced, because user.conf is sourced after the
# plugin layer and would set them too late.
set_plugin_options() {
  srv set -g @claude_launch_key a \; set -g @claude_list_key A \; \
    set -g @continuum-restore-max-delay 0
}

write_grofe_config() {
  local dir="$XDG_CONFIG_HOME/grofe"
  mkdir -p "$dir/conf.d"
  cp "$CANOPY_STORE"/grofe/conf.d/*.toml "$dir/conf.d/"
  cat >"$dir/config.toml" <<EOF
[environment]
CANOPY_STORE = "$CANOPY_STORE"
CANOPY_STATE = "$CANOPY_STATE"
CANOPY_CONFIG = "$CANOPY_CONFIG"
EOF
  cat >"$dir/user.toml" <<'EOF'
[user-options]
claude_launch_key = "a"
claude_list_key = "A"
continuum-restore-max-delay = "0"

[status]
right = "#{continuum_status}"
EOF
}

# The whole grofe tree as -f arguments, in grofe's layer order.
grofe_files() {
  local dir="$XDG_CONFIG_HOME/grofe" f
  set -- -f "$dir/config.toml"
  for f in "$dir"/conf.d/*.toml; do set -- "$@" -f "$f"; done
  printf '%s\n' "$@" -f "$dir/user.toml"
}

# start <backend>: a server with the ported config, and `srv` to talk to it.
#   tmux        real tmux 3.7b, -f /dev/null, then canopy's tmux.conf
#   grofe-tmux  grofe answering to the tmux name, the grofe tree as -f
#   grofe       grofe under its own name, reading its native config
start() {
  backend="$1"
  case "$1" in
    tmux)
      ln -sf "$tmux37" "$bin/tmux"
      srv() { env -u TMUX -u TMUX_PANE "$tmux37" -L grofe-tp3-tmux "$@"; }
      servers="$servers $tmux37:grofe-tp3-tmux"
      srv -f /dev/null new-session -d -s main -x 120 -y 40 'sleep 600'
      set_plugin_options
      srv source-file "$CANOPY_STORE/tmux/tmux.conf"
      # canopy's status layer sets status-right before the plugin layer
      # runs, so continuum's #{continuum_status} is put back and the plugin
      # layer sourced a second time, as a reload sources it. That also
      # shows a second load pass loading the same set.
      srv set -g status-right '#{continuum_status}'
      srv source-file "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
      ;;
    grofe-tmux)
      ln -sf "$grofe_bin" "$bin/tmux"
      write_grofe_config
      srv() { "$bin/tmux" -L grofe-tp3 "$@"; }
      servers="$servers $bin/tmux:grofe-tp3"
      local files
      files="$(grofe_files)"
      # shellcheck disable=SC2086
      srv $files new-session -d -s main -x 120 -y 40 'sleep 600'
      ;;
    grofe)
      ln -sf "$grofe_bin" "$bin/tmux"
      ln -sf "$grofe_bin" "$bin/grofe"
      write_grofe_config
      srv() { "$bin/grofe" -L grofe-tp3n "$@"; }
      servers="$servers $bin/grofe:grofe-tp3n"
      srv new-session -d -s main -x 120 -y 40 'sleep 600'
      ;;
  esac
}

# The loader is done when the last plugin's binding is there and the
# prefix-send re-assert after the loop has run. tmux finishes before
# source-file returns; grofe runs load commands after start.
wait_loaded() {
  local i
  for i in $(seq 1 120); do
    keys="$(srv list-keys -T prefix 2>/dev/null)" || keys=""
    case "$keys" in
      *tmux-claude-session-manager/scripts/launch.sh*)
        if printf '%s\n' "$keys" | grep -Eq 'prefix +C-s +send-prefix( |$)'; then
          return 0
        fi
        ;;
    esac
    sleep 0.25
  done
  printf 'the plugin load did not finish:\n%s\nplugins.log:\n%s\n' "$keys" "$(plugin_log)" >&2
  srv list-keys -T prefix >&2 || true
  return 1
}

prefix_binding() {
  printf '%s\n' "$keys" | awk -v k="$1" '$1 == "bind-key" && $3 == "prefix" && $4 == k'
}

# One spot check per plugin, each something only that plugin's load does.
loaded() {
  case "$1" in
    tmux-resurrect)
      [ "$(srv show -gv @resurrect-save-script-path)" = "$CANOPY_STORE/plugins/tmux-resurrect/scripts/save.sh" ]
      ;;
    # continuum swaps #{continuum_status} for a #(continuum_status.sh).
    # grofe under its own name shows a #() as the status source it
    # registered for it, @src-<hash>, and nothing but continuum would have
    # put one there.
    tmux-continuum)
      case "$(srv show -gv status-right)" in
        *"tmux-continuum/scripts/continuum_status.sh"*) ;;
        '#{@src-'*) [ "$backend" = grofe ] ;;
        *) false ;;
      esac
      ;;
    tmux-sensible) [[ "$(prefix_binding C-p)" == *" previous-window"* ]] ;;
    tmux-yank) [[ "$(prefix_binding y)" == *"tmux-yank/scripts/copy_line.sh"* ]] ;;
    tmux-fzf) [[ "$(prefix_binding F)" == *"tmux-fzf/main.sh"* ]] ;;
    tmux-sessionx) [[ "$(prefix_binding O)" == *"tmux-sessionx/scripts/sessionx.sh"* ]] ;;
    # tmux expands the command alias which-key binds Space to.
    tmux-which-key)
      [[ "$(srv show -gv command-alias)" == *"show-wk-menu-root="* ]] &&
        [[ "$(prefix_binding Space)" == *" display-menu "* ]]
      ;;
    opensessions) [[ "$(prefix_binding o)" == *"switch-client -T opensessions"* ]] ;;
    tmux-fzf-url) [[ "$(prefix_binding u)" == *"tmux-fzf-url/fzf-url.sh"* ]] ;;
    tmux-claude-session-manager) [[ "$(prefix_binding a)" == *"tmux-claude-session-manager/scripts/launch.sh"* ]] ;;
    *) return 1 ;;
  esac
}

# Every plugin but the ones named loaded.
assert_loaded_except() {
  local name bad=""
  for name in $PLUGINS; do
    case " $* " in *" $name "*) continue ;; esac
    loaded "$name" || bad="$bad $name"
  done
  [ -z "$bad" ] || {
    printf 'not loaded:%s\n' "$bad"
    printf 'plugins.log:\n%s\n' "$(plugin_log)"
    printf '%s\n' "$keys"
    false
  }
}

plugin_log() { cat "$CANOPY_STATE/plugins.log" 2>/dev/null || true; }

# On grofe, two entry points run and then stop at a form grofe does not
# answer yet: which-key's `source-file` of its tmux-syntax menu, and
# claude-session-manager's `set-hook -g alert-bell`. Both are logged as
# failed, and neither stops the plugins after it. Nothing else may be.
assert_grofe_log() {
  run plugin_log
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *" tmux-which-key: entry point plugin.sh.tmux failed" | *" tmux-claude-session-manager: entry point claude_hatch.tmux failed") ;;
      *)
        printf 'unexpected plugins.log line: %s\n' "$line"
        return 1
        ;;
    esac
  done <<<"$output"
}

# The load must leave no compat-miss line of its own: the loader is one
# run-shell, and each entry point another. A line for a form inside a
# plugin's script (copy-mode's send-keys -X, a hook grofe has no event
# for) is that plugin's compat check, not the loader's.
assert_no_load_miss() {
  local log="$XDG_STATE_HOME/grofe/compat-miss.log"
  [ -f "$log" ] || return 0
  printf 'compat-miss.log:\n%s\n' "$(cat "$log")"
  ! grep -Eq 'run-shell|if-shell|source-file' "$log"
}

# --- vendoring ---------------------------------------------------------------

@test "VERSIONS pins all ten plugins, resurrect and continuum first" {
  run canopy_plugin_names
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "$PLUGINS " ]
  for name in $PLUGINS; do
    line="$(awk -v n="$name" '$1 == n { print; exit }' "$CANOPY_STORE/plugins/VERSIONS")"
    [[ "$(printf '%s' "$line" | awk '{ print $2 }')" == https://github.com/*/"$name".git ]]
    [[ "$(printf '%s' "$line" | awk '{ print $3 }')" =~ ^[0-9a-f]{40}$ ]]
  done
}

@test "each of the ten is vendored with one executable *.tmux entry point and its digest" {
  for name in $PLUGINS; do
    dir="$CANOPY_STORE/plugins/$name"
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -e "$dir/.git" ]
    set -- "$dir"/*.tmux
    [ "$#" -eq 1 ] && [ -f "$1" ] && [ -x "$1" ]
    [ "$(canopy_plugin_recorded_digest "$name")" = "$(canopy_plugin_digest "$dir")" ]
    [ -z "$(find "$dir" -type d -empty)" ]
    [ -z "$(find "$dir" \( -name .gitignore -o -name .gitmodules \) -print)" ]
  done
}

@test "every vendored file is in git, so a clone reproduces the digest" {
  # A global excludesFile is enough to keep a vendored file out of a
  # commit; tmux-which-key ships a .vscode/ that one commonly ignores.
  for name in $PLUGINS; do
    on_disk="$(cd "$CANOPY_STORE/plugins/$name" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort)"
    in_git="$(git -C "$CANOPY_STORE" ls-files "plugins/$name" | sed "s|^plugins/$name/||" | LC_ALL=C sort)"
    [ "$on_disk" = "$in_git" ] || {
      printf '%s: on disk and in git differ\n' "$name"
      diff <(printf '%s\n' "$on_disk") <(printf '%s\n' "$in_git") || true
      false
    }
  done
}

@test "vendor.sh twice in a row reproduces each of the eight, and CHECKSUMS" {
  [ "${CANOPY_TEST_VENDOR:-}" = 1 ] || skip "set CANOPY_TEST_VENDOR=1 to clone the eight upstreams"
  copy_store
  for name in $NEW_EIGHT; do
    TMPDIR="$BATS_TEST_TMPDIR" sh "$store/plugins/vendor.sh" "$name" >/dev/null
    cp "$store/plugins/CHECKSUMS" "$BATS_TEST_TMPDIR/first"
    first="$(canopy_plugin_digest "$store/plugins/$name")"
    TMPDIR="$BATS_TEST_TMPDIR" sh "$store/plugins/vendor.sh" "$name" >/dev/null
    [ "$(canopy_plugin_digest "$store/plugins/$name")" = "$first" ]
    cmp "$store/plugins/CHECKSUMS" "$BATS_TEST_TMPDIR/first"
    diff -r "$real_store/plugins/$name" "$store/plugins/$name"
  done
  cmp "$store/plugins/CHECKSUMS" "$real_store/plugins/CHECKSUMS"
}

# --- the call sites ----------------------------------------------------------

# The names a call site passes to canopy_load_plugins.
call_list() {
  tr '\n' ' ' <"$1" | sed -n 's/.*canopy_load_plugins \(.*\)/\1/p' | sed "s/'.*//; s/\\\\//g" | tr -s ' ' | sed 's/^ //; s/ $//'
}

@test "30-plugins.conf and the grofe fragment load the ten in VERSIONS order" {
  want="$(canopy_plugin_names | tr '\n' ' ' | sed 's/ $//')"
  [ "$(call_list "$CANOPY_STORE/tmux/conf.d/30-plugins.conf")" = "$want" ]
  [ "$(call_list "$CANOPY_STORE/grofe/templates/30-canopy-plugins.toml")" = "$want" ]
  [ "$(call_list "$CANOPY_STORE/grofe/conf.d/30-canopy-plugins.toml")" = "$want" ]
}

@test "no line of canopy's own config uses TPM" {
  run grep -rnE '^[^#]*(@tpm_plugins|@plugin[[:space:]]|plugins/tpm)' "$CANOPY_STORE/tmux" "$CANOPY_STORE/grofe"
  [ "$status" -eq 1 ]
}

# --- the loader on its own ---------------------------------------------------

# A fake plugin tree and a tmux that records what it was asked to do.
fake_plugins() {
  copy_store
  rm -rf "$store/plugins"
  mkdir -p "$store/plugins/one" "$store/plugins/two" "$store/plugins/empty"
  printf '#!/bin/sh\n' >"$store/plugins/one/one.tmux"
  printf '#!/bin/sh\nexit 3\n' >"$store/plugins/two/b.tmux"
  printf '#!/bin/sh\n' >"$store/plugins/two/a.tmux"
  chmod +x "$store/plugins/one/one.tmux" "$store/plugins/two/a.tmux" "$store/plugins/two/b.tmux"
  printf '#!/bin/sh\n' >"$store/plugins/empty/off.tmux"
  cat >"$bin/tmux" <<EOF
#!/bin/sh
if [ "\$1" = show-option ]; then
  [ -f "$BATS_TEST_TMPDIR/off" ] && echo off
  exit 0
fi
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/calls"
case "\$2" in *b.tmux*) exit 1 ;; esac
EOF
  chmod +x "$bin/tmux"
}

@test "the loader runs each executable *.tmux through tmux run-shell, in glob order" {
  fake_plugins
  canopy_load_plugins one two empty missing
  run cat "$BATS_TEST_TMPDIR/calls"
  [ "${lines[0]}" = "run-shell '$store/plugins/one/one.tmux'" ]
  [ "${lines[1]}" = "run-shell '$store/plugins/two/a.tmux'" ]
  [ "${lines[2]}" = "run-shell '$store/plugins/two/b.tmux'" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "a missing tree or entry point is one dormant line, a failing one is logged, the rest load" {
  fake_plugins
  run canopy_load_plugins one two empty missing
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run plugin_log
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *" two: entry point b.tmux failed" ]]
  [[ "${lines[1]}" == *" empty: dormant, no executable *.tmux in $store/plugins/empty" ]]
  [[ "${lines[2]}" == *" missing: dormant, no executable *.tmux in $store/plugins/missing" ]]
}

@test "each load pass starts the log afresh" {
  fake_plugins
  canopy_load_plugins missing
  canopy_load_plugins one
  run plugin_log
  [ -z "$output" ]
}

@test "a server with @canopy_plugins off loads nothing and keeps the last log" {
  fake_plugins
  canopy_load_plugins missing
  touch "$BATS_TEST_TMPDIR/off"
  canopy_load_plugins one two
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  run plugin_log
  [[ "$output" == *" missing: dormant"* ]]
}

@test "canopy's scratch servers set @canopy_plugins off before they source a config" {
  run grep -c 'set -g @continuum-restore-max-delay 0 \\; set -g @canopy_plugins off \\;' "$CANOPY_STORE/lib/tmux.sh"
  [ "$output" -eq 2 ]
}

@test "without bash every plugin is dormant and nothing runs" {
  fake_plugins
  nobash="$BATS_TEST_TMPDIR/nobash"
  mkdir -p "$nobash"
  ln -s "$bin/tmux" "$nobash/tmux"
  for tool in date mkdir; do ln -s "$(command -v "$tool")" "$nobash/$tool"; done
  PATH="$nobash" canopy_load_plugins one two
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  run plugin_log
  [[ "${lines[0]}" == *" one: dormant, bash not found" ]]
  [[ "${lines[1]}" == *" two: dormant, bash not found" ]]
}

# --- doctor ------------------------------------------------------------------

@test "canopy doctor reports all ten vendored trees present and unmodified" {
  run canopy-doctor
  for name in $PLUGINS; do
    commit="$(awk -v n="$name" '$1 == n { print $3; exit }' "$CANOPY_STORE/plugins/VERSIONS")"
    printf '%s\n' "$output" | grep -qxF "  $name: pinned $commit, tree matches"
  done
  [[ "$output" != *"MISSING"* ]]
  [[ "$output" != *"MODIFIED"* ]]
}

# --- a real server -----------------------------------------------------------

@test "grofe as tmux: the ported config loads all ten with no load error and no load miss" {
  need_grofe
  copy_store
  start grofe-tmux
  wait_loaded
  # The two grofe gaps assert_grofe_log names stop which-key before it binds.
  assert_loaded_except tmux-which-key
  assert_grofe_log
  assert_no_load_miss
  run plugin_log
  [[ "$output" != *"dormant"* ]]
  # No plugin wrote into its vendored tree.
  for name in $PLUGINS; do
    [ "$(canopy_plugin_recorded_digest "$name")" = "$(canopy_plugin_digest "$store/plugins/$name")" ]
  done
}

@test "grofe under its own name, on its native config, loads the same set" {
  need_grofe
  copy_store
  start grofe
  wait_loaded
  assert_loaded_except tmux-which-key
  assert_grofe_log
  run plugin_log
  [[ "$output" != *"dormant"* ]]
}

@test "grofe: with tmux-which-key moved aside only it is dormant, and doctor calls it missing" {
  need_grofe
  copy_store
  mv "$store/plugins/tmux-which-key" "$BATS_TEST_TMPDIR/tmux-which-key.aside"
  start grofe-tmux
  wait_loaded
  assert_loaded_except tmux-which-key
  run plugin_log
  printf '%s\n' "$output"
  [ "$(printf '%s\n' "$output" | grep -c 'dormant')" -eq 1 ]
  printf '%s\n' "$output" | grep -q " tmux-which-key: dormant, no executable \*.tmux in $store/plugins/tmux-which-key$"
  run canopy-doctor
  printf '%s\n' "$output" | grep -q '  tmux-which-key: pinned [0-9a-f]*, tree MISSING'
  [[ "$output" != *"MODIFIED"* ]]
  mv "$BATS_TEST_TMPDIR/tmux-which-key.aside" "$store/plugins/tmux-which-key"
}

@test "tmux 3.7b: the same loader loads all ten" {
  need_tmux37
  copy_store
  start tmux
  wait_loaded
  assert_loaded_except
  run plugin_log
  [ -z "$output" ]
  for name in $PLUGINS; do
    [ "$(canopy_plugin_recorded_digest "$name")" = "$(canopy_plugin_digest "$store/plugins/$name")" ]
  done
}

@test "tmux 3.7b: with tmux-which-key moved aside only it is dormant" {
  need_tmux37
  copy_store
  mv "$store/plugins/tmux-which-key" "$BATS_TEST_TMPDIR/tmux-which-key.aside"
  start tmux
  wait_loaded
  assert_loaded_except tmux-which-key
  run plugin_log
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *" tmux-which-key: dormant, no executable *.tmux in $store/plugins/tmux-which-key" ]]
  mv "$BATS_TEST_TMPDIR/tmux-which-key.aside" "$store/plugins/tmux-which-key"
}

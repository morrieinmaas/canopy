#!/usr/bin/env bats
load helper

# The plugin loader: canopy_load_plugins in lib/plugins.sh, called from
# 30-plugins.conf on tmux and from the grofe plugin fragment's
# load-commands, over the ten vendored plugins.
#
# Every server here runs on a private socket in the suite's private socket
# directory (test/setup_suite.bash), with a scratch $HOME and XDG tree, and
# loads from a copy of the store, so no plugin can write into this
# checkout or into anyone's real home. The rest of the suite loads no
# plugin (CANOPY_PLUGINS=off, test/helper.bash); this file does. The
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
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  unset CANOPY_PLUGINS
  . "$CANOPY_STORE/lib/env.sh"
  . "$CANOPY_STORE/lib/plugins.sh"
  real_store="$CANOPY_STORE"
  # grofe keeps its sockets under XDG_RUNTIME_DIR.
  XDG_RUNTIME_DIR="$TMUX_TMPDIR/xdg"
  (umask 077 && mkdir -p "$XDG_RUNTIME_DIR")
  export XDG_RUNTIME_DIR
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
  # opensessions' binaries, as canopy install provisions them, so its entry
  # point neither runs its installer nor writes /tmp/opensessions-install.log.
  local b
  for b in opensessions-sidebar opensessions-server lazydiff; do
    printf '#!/bin/sh\nexit 0\n' >"$store/plugins/opensessions/bin/$b"
    chmod +x "$store/plugins/opensessions/bin/$b"
  done
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$store/plugins/opensessions/package.json" |
    head -1 >"$store/plugins/opensessions/bin/.opensessions-version"
  mkdir -p "$store/plugins/tmux-fzf-url/bin"
  printf '#!/bin/sh\necho "xre 0.1.1"\n' >"$store/plugins/tmux-fzf-url/bin/xre"
  chmod +x "$store/plugins/tmux-fzf-url/bin/xre"
  # ARTIFACTS rows for exactly these files, so the loader's artifact check
  # passes as it does after canopy install.
  CANOPY_ARTIFACTS="$BATS_TEST_TMPDIR/ARTIFACTS.copy"
  export CANOPY_ARTIFACTS
  local f
  for f in opensessions/bin/opensessions-sidebar opensessions/bin/opensessions-server \
    opensessions/bin/lazydiff opensessions/bin/.opensessions-version tmux-fzf-url/bin/xre; do
    printf '%s any https://fixture.invalid/none %s none %s %s\n' "${f%%/*}" \
      "$(printf 0%.0s $(seq 64))" "${f#*/}" "$(canopy_sha256 "$store/plugins/$f")"
  done >"$CANOPY_ARTIFACTS"
}

# What the plugins read before they load, set where a user sets them:
# claude-session-manager's keys as the owner sets them (its defaults take
# yank's y and fzf-url's u), no continuum restore at start, and a
# status-right holding continuum's #{continuum_status}, which continuum
# replaces on load whether or not another server is running.
write_user_conf() {
  cat >"$CANOPY_CONFIG/user.conf" <<'EOF'
set -g @claude_launch_key 'a'
set -g @claude_list_key 'A'
set -g @continuum-restore-max-delay 0
set -g status-right '#{continuum_status}'
EOF
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
      write_user_conf
      srv -f /dev/null new-session -d -s main -x 120 -y 40 'sleep 600'
      srv source-file "$CANOPY_STORE/tmux/tmux.conf"
      # A second time, as prefix r reloads: the same set loads again.
      srv source-file "$CANOPY_STORE/tmux/tmux.conf"
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
    # resurrect binds its restore (and its save, which tmux.conf and the
    # grofe fragment then take back): M-s and continuum's saves run
    # canopy's one-at-a-time wrapper.
    tmux-resurrect)
      [[ "$(prefix_binding M-r)" == *"tmux-resurrect/scripts/restore.sh"* ]] &&
        [[ "$(prefix_binding M-s)" == *"plugins/strategies/canopy_save.sh"* ]] &&
        [ "$(srv show -gv @resurrect-save-script-path)" = "$CANOPY_STORE/plugins/strategies/canopy_save.sh" ]
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

# Whether this grofe answers the two forms which-key and
# claude-session-manager stopped at before grofe fixed them (M3.7 lane 1): a
# tmux-syntax `source-file` and `set-hook -g alert-bell`. Asked of the
# running server, through the tmux name the plugins call it by.
grofe_runs_all_ten() {
  local sock probe
  sock="$(srv display-message -p '#{socket_path}')" || return 1
  probe="$BATS_TEST_TMPDIR/probe.conf"
  printf 'set -g @canopy_probe 1\n' >"$probe"
  "$bin/tmux" -S "$sock" source-file "$probe" >/dev/null 2>&1 &&
    [ "$("$bin/tmux" -S "$sock" show -gv @canopy_probe 2>/dev/null)" = 1 ] &&
    "$bin/tmux" -S "$sock" set-hook -g alert-bell 'display-message probe' >/dev/null 2>&1 &&
    "$bin/tmux" -S "$sock" set-hook -gu alert-bell >/dev/null 2>&1
}

# On a grofe with lane 1's fixes all ten load and plugins.log is empty. On
# one without, two entry points stop at the forms above, which-key before
# it binds: both are logged as failed, and neither stops the plugins after
# it. Nothing else may be.
assert_grofe_load() {
  if grofe_runs_all_ten; then
    assert_loaded_except
    run plugin_log
    [ -z "$output" ] || {
      printf 'unexpected plugins.log:\n%s\n' "$output"
      return 1
    }
    return 0
  fi
  assert_loaded_except tmux-which-key
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

@test "tmux.conf and the grofe fragment load the ten in VERSIONS order" {
  want="$(canopy_plugin_names | tr '\n' ' ' | sed 's/ $//')"
  [ "$(call_list "$CANOPY_STORE/tmux/tmux.conf")" = "$want" ]
  [ "$(call_list "$CANOPY_STORE/grofe/templates/30-canopy-plugins.toml")" = "$want" ]
  [ "$(call_list "$CANOPY_STORE/grofe/conf.d/30-canopy-plugins.toml")" = "$want" ]
}

@test "on tmux the plugins load after user.conf, and prefix C-s is taken back after them" {
  conf="$CANOPY_STORE/tmux/tmux.conf"
  user="$(grep -nF 'source-file -q "$CANOPY_CONFIG/user.conf"' "$conf" | cut -d: -f1)"
  load="$(grep -n "^run-shell .*canopy_load_plugins" "$conf" | cut -d: -f1)"
  csend="$(grep -nx 'bind-key C-s send-prefix' "$conf" | cut -d: -f1)"
  [ -n "$user" ] && [ -n "$load" ] && [ -n "$csend" ]
  [ "$user" -lt "$load" ] && [ "$load" -lt "$csend" ]
  run grep -c 'canopy_load_plugins\|^bind-key C-s' "$CANOPY_STORE/tmux/conf.d/30-plugins.conf"
  [ "$output" -eq 0 ]
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
if [ "\$3" = show-option ]; then
  [ -f "$BATS_TEST_TMPDIR/off" ] && echo off
  exit 0
fi
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/calls"
case "\$4" in *b.tmux*) exit 1 ;; esac
EOF
  chmod +x "$bin/tmux"
  # As if run by a server: the loader talks to this socket and no other.
  TMUX="$BATS_TEST_TMPDIR/fake.sock,1,0"
  export TMUX
}

@test "the loader runs each executable *.tmux through run-shell on \$TMUX's socket, in glob order" {
  fake_plugins
  canopy_load_plugins one two empty missing
  run cat "$BATS_TEST_TMPDIR/calls"
  sock="$BATS_TEST_TMPDIR/fake.sock"
  [ "${lines[0]}" = "-S $sock run-shell '$store/plugins/one/one.tmux'" ]
  [ "${lines[1]}" = "-S $sock run-shell '$store/plugins/two/a.tmux'" ]
  [ "${lines[2]}" = "-S $sock run-shell '$store/plugins/two/b.tmux'" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "outside a server the loader runs nothing, and says so once" {
  fake_plugins
  unset TMUX
  canopy_load_plugins one two
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  run plugin_log
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *" loader: loaded nothing, TMUX is unset"* ]]
}

@test "an entry point whose path holds a quote is passed as one word" {
  fake_plugins
  mkdir -p "$store/plugins/it's"
  printf '#!/bin/sh\n' >"$store/plugins/it's/q.tmux"
  chmod +x "$store/plugins/it's/q.tmux"
  canopy_load_plugins "it's"
  run cat "$BATS_TEST_TMPDIR/calls"
  word="${lines[0]#-S * run-shell }"
  eval "set -- $word"
  [ "$#" -eq 1 ]
  [ "$1" = "$store/plugins/it's/q.tmux" ]
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

@test "without bash only an entry point that asks for bash is dormant" {
  fake_plugins
  printf '#!/usr/bin/env bash\n' >"$store/plugins/one/one.tmux"
  nobash="$BATS_TEST_TMPDIR/nobash"
  mkdir -p "$nobash"
  ln -s "$bin/tmux" "$nobash/tmux"
  for tool in date mkdir sed; do ln -s "$(command -v "$tool")" "$nobash/$tool"; done
  PATH="$nobash" canopy_load_plugins one two
  run cat "$BATS_TEST_TMPDIR/calls"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"/plugins/two/a.tmux'" ]]
  run plugin_log
  [[ "${lines[0]}" == *" one: dormant, bash not found" ]]
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
  assert_grofe_load
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
  assert_grofe_load
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

# --- release artifacts, and files written into a tree ----------------------

@test "every ARTIFACTS row is well formed, and every dest is in LOCAL" {
  while read -r name platform url sum member dest want; do
    case "$name" in '#'* | '') continue ;; esac
    canopy_plugin_pin "$name" >/dev/null
    case "$platform" in darwin-arm64 | darwin-x86_64 | linux-arm64 | linux-x86_64 | any) ;; *) false ;; esac
    case "$url" in https://github.com/*/releases/download/* | text:*) ;; *) false ;; esac
    [[ "$want" =~ ^[0-9a-f]{64}$ ]]
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || [ "$sum" = - ]
    [ -n "$member" ]
    grep -qxF "$name $dest" "$real_store/plugins/LOCAL"
  done <"$real_store/plugins/ARTIFACTS"
  # Every platform canopy names has opensessions' three binaries and xre.
  for platform in darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64; do
    CANOPY_ARTIFACTS="$real_store/plugins/ARTIFACTS" run canopy_plugin_artifacts "$platform"
    [ "${#lines[@]}" -eq 5 ]
    [[ "$output" != *"bad "* ]]
  done
}

@test "a file plugins/LOCAL lists does not change the tree digest" {
  copy_store
  before="$(canopy_plugin_digest "$store/plugins/tmux-which-key")"
  printf 'x\n' >"$store/plugins/tmux-which-key/config.yaml"
  printf 'x\n' >"$store/plugins/tmux-which-key/plugin/init.tmux"
  [ "$(canopy_plugin_digest "$store/plugins/tmux-which-key")" = "$before" ]
  printf 'x\n' >"$store/plugins/tmux-which-key/other"
  [ "$(canopy_plugin_digest "$store/plugins/tmux-which-key")" != "$before" ]
}

# A local release: one .tar.gz holding a binary, behind an https url that a
# fake curl answers from disk, recording how it was asked.
fixture_artifacts() {
  copy_store
  rm -f "$store/plugins/opensessions/bin/opensessions-server" "$store/plugins/opensessions/bin/.opensessions-version"
  cat >"$bin/curl" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/curl-calls"
out=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    https://fixture.invalid/*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
src="$BATS_TEST_TMPDIR/\${url#https://fixture.invalid/}"
[ -f "\$src" ] && cp "\$src" "\$out"
EOF
  chmod +x "$bin/curl"
  mkdir -p "$BATS_TEST_TMPDIR/rel/pkg"
  printf '#!/bin/sh\necho fixture\n' >"$BATS_TEST_TMPDIR/rel/pkg/server"
  chmod +x "$BATS_TEST_TMPDIR/rel/pkg/server"
  tar -czf "$BATS_TEST_TMPDIR/rel.tar.gz" -C "$BATS_TEST_TMPDIR/rel" pkg/server
  archive_sum="$(canopy_sha256 "$BATS_TEST_TMPDIR/rel.tar.gz")"
  file_sum="$(canopy_sha256 "$BATS_TEST_TMPDIR/rel/pkg/server")"
  stamp_sum="$(printf 'v9\n' | canopy_sha256)"
  CANOPY_ARTIFACTS="$BATS_TEST_TMPDIR/ARTIFACTS"
  export CANOPY_ARTIFACTS
  {
    printf 'opensessions %s https://fixture.invalid/rel.tar.gz %s pkg/server bin/opensessions-server %s\n' \
      "$(canopy_platform)" "$archive_sum" "$file_sum"
    printf 'opensessions any text:v9 - - bin/.opensessions-version %s\n' "$stamp_sum"
    printf 'opensessions not-this-machine https://fixture.invalid/none %s x bin/lazydiff %s\n' "$archive_sum" "$file_sum"
  } >"$CANOPY_ARTIFACTS"
}

@test "provisioning puts each artifact for this machine in place, checked, and nothing else" {
  fixture_artifacts
  run canopy_provision_artifacts
  [ "$status" -eq 0 ]
  [ -x "$store/plugins/opensessions/bin/opensessions-server" ]
  [ "$(canopy_sha256 "$store/plugins/opensessions/bin/opensessions-server")" = "$file_sum" ]
  [ "$(cat "$store/plugins/opensessions/bin/.opensessions-version")" = v9 ]
  [ "$(cat "$store/plugins/opensessions/bin/lazydiff")" = "$(printf '#!/bin/sh\nexit 0')" ]
  # https only, redirects included.
  [[ "$(cat "$BATS_TEST_TMPDIR/curl-calls")" == *"--proto =https --proto-redir =https https://fixture.invalid/rel.tar.gz"* ]]
}

@test "a second provisioning run fetches nothing" {
  fixture_artifacts
  canopy_provision_artifacts
  rm "$BATS_TEST_TMPDIR/rel.tar.gz"
  run canopy_provision_artifacts
  [ "$status" -eq 0 ]
}

@test "an archive whose sha256 differs is refused, and nothing is written" {
  fixture_artifacts
  printf 'tampered' >>"$BATS_TEST_TMPDIR/rel.tar.gz"
  run canopy_provision_artifacts
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the recorded $archive_sum; refused"* ]]
  [ ! -e "$store/plugins/opensessions/bin/opensessions-server" ]
  # The text row does not depend on the archive, and is still provided.
  [ -f "$store/plugins/opensessions/bin/.opensessions-version" ]
}

@test "an unreachable artifact is reported, not fatal" {
  fixture_artifacts
  rm "$BATS_TEST_TMPDIR/rel.tar.gz"
  run canopy_provision_artifacts
  [ "$status" -eq 1 ]
  [[ "$output" == *"opensessions: could not download https://fixture.invalid/rel.tar.gz"* ]]
}

@test "doctor checks each provisioned binary against its own sha256" {
  fixture_artifacts
  run canopy-doctor
  [[ "$output" == *"opensessions: bin/opensessions-server MISSING (provision with: canopy install)"* ]]
  canopy_provision_artifacts
  run canopy-doctor
  [[ "$output" == *"opensessions: bin/opensessions-server provisioned, matches"* ]]
  [[ "$output" == *"opensessions: pinned "*", tree matches"* ]]
  printf 'x' >>"$store/plugins/opensessions/bin/opensessions-server"
  run canopy-doctor
  [[ "$output" == *"opensessions: bin/opensessions-server MODIFIED"* ]]
  # The tree digest leaves the binary out, so the tree itself still matches.
  [[ "$output" == *"opensessions: pinned "*", tree matches"* ]]
}

@test "canopy install provisions the artifacts" {
  fixture_artifacts
  run canopy install --yes
  [ "$status" -eq 0 ]
  [ "$(canopy_sha256 "$store/plugins/opensessions/bin/opensessions-server")" = "$file_sum" ]
}

@test "doctor shows what the last plugin load skipped" {
  printf '2026-01-01T00:00:00Z tmux-which-key: dormant, no executable *.tmux in x\n' >"$CANOPY_STATE/plugins.log"
  run canopy-doctor
  [[ "$output" == *"last plugin load:"* ]]
  [[ "$output" == *"    2026-01-01T00:00:00Z tmux-which-key: dormant"* ]]
}

# --- isolation ---------------------------------------------------------------

@test "no test or scratch server names the shared socket directory" {
  run grep -rnE --exclude=plugin_loader.bats --exclude=setup_suite.bash \
    'TMUX_TMPDIR=/tmp([^/]|$)|"/tmp/tmux-' "$real_store/test" "$real_store/lib" "$real_store/bin"
  [ "$status" -eq 1 ]
}

# --- refusing what an ARTIFACTS row or a tree must not do ------------------

# rows_with <name> <dest>: one row, valid but for what the arguments make it.
rows_with() {
  CANOPY_ARTIFACTS="$BATS_TEST_TMPDIR/ARTIFACTS.bad"
  export CANOPY_ARTIFACTS
  printf '%s any text:x - - %s %s\n' "$1" "$2" "$(printf 'x\n' | canopy_sha256)" >"$CANOPY_ARTIFACTS"
}

@test "an ARTIFACTS row is refused for an absolute dest, a .. segment, an odd character, a dest LOCAL does not list, or an unpinned plugin" {
  copy_store
  for row in "opensessions /etc/x" "opensessions bin/../../x" "opensessions .." "opensessions bin/a b" \
    'opensessions bin/$x' "opensessions bin/not-listed" "not-a-plugin bin/xre"; do
    rows_with $row
    run canopy_plugin_artifacts
    [[ "$output" == "bad "* ]] || { printf 'accepted: %s\n' "$row"; false; }
    run canopy_provision_artifacts
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused an ARTIFACTS row"* ]]
  done
  [ ! -e /etc/x ] && [ ! -e "$store/x" ] && [ ! -e "$store/plugins/x" ]
  rows_with opensessions bin/.opensessions-version
  run canopy_plugin_artifacts
  [[ "$output" == "ok "* ]]
}

@test "doctor reports a refused ARTIFACTS row" {
  copy_store
  rows_with opensessions bin/../../x
  run canopy-doctor
  [[ "$output" == *"opensessions: ARTIFACTS row for bin/../../x REFUSED"* ]]
}

# The real tmux-fzf-url, with a recording tmux, and its xre in ARTIFACTS.
fzf_url_gate() {
  copy_store
  cat >"$bin/tmux" <<EOF
#!/bin/sh
[ "\$3" = show-option ] && exit 0
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/calls"
EOF
  chmod +x "$bin/tmux"
  TMUX="$BATS_TEST_TMPDIR/fake.sock,1,0"
  export TMUX
}

@test "tmux-fzf-url loads with its xre in place" {
  fzf_url_gate
  canopy_load_plugins tmux-fzf-url
  [[ "$(cat "$BATS_TEST_TMPDIR/calls")" == *"tmux-fzf-url/fzf-url.tmux'" ]]
  [ -z "$(plugin_log)" ]
}

@test "tmux-fzf-url with bin/xre deleted is dormant, so its curl | bash can never run" {
  fzf_url_gate
  rm "$store/plugins/tmux-fzf-url/bin/xre"
  canopy_load_plugins tmux-fzf-url
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  run plugin_log
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *" tmux-fzf-url: dormant, a release binary from plugins/ARTIFACTS is missing or fails its sha256"* ]]
}

@test "tmux-fzf-url with bin/xre corrupted is dormant too" {
  fzf_url_gate
  printf 'x' >>"$store/plugins/tmux-fzf-url/bin/xre"
  canopy_load_plugins tmux-fzf-url
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [[ "$(plugin_log)" == *" tmux-fzf-url: dormant, a release binary"* ]]
}

@test "a plugin whose ARTIFACTS row is refused does not load" {
  fzf_url_gate
  printf 'tmux-fzf-url any text:x - - /tmp/xre %s\n' "$(printf 'x\n' | canopy_sha256)" >>"$CANOPY_ARTIFACTS"
  canopy_load_plugins tmux-fzf-url
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a symlinked *.tmux entry point is refused" {
  fzf_url_gate
  mv "$store/plugins/tmux-fzf-url/fzf-url.tmux" "$store/plugins/tmux-fzf-url/real.sh"
  ln -s real.sh "$store/plugins/tmux-fzf-url/fzf-url.tmux"
  canopy_load_plugins tmux-fzf-url
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [[ "$(plugin_log)" == *" tmux-fzf-url: dormant, entry point fzf-url.tmux is a symlink, refused"* ]]
}

@test "retargeting a symlink changes the tree digest" {
  copy_store
  dir="$store/plugins/tmux-continuum"
  before="$(canopy_plugin_digest "$dir")"
  [ "$before" = "$(canopy_plugin_recorded_digest tmux-continuum)" ]
  link="$dir/scripts/handle_tmux_automatic_start/README.md"
  rm "$link"
  ln -s ../../README.md "$link"
  [ "$(canopy_plugin_digest "$dir")" != "$before" ]
}

@test "doctor compares which-key's copied files with what they are copied from" {
  copy_store
  wk="$store/plugins/tmux-which-key"
  cp "$wk/config.example.yaml" "$wk/config.yaml"
  cp "$wk/plugin/init.example.tmux" "$wk/plugin/init.tmux"
  run canopy-doctor
  [[ "$output" != *"tmux-which-key: config.yaml MODIFIED"* ]]
  [[ "$output" != *"tmux-which-key: plugin/init.tmux MODIFIED"* ]]
  printf '# edit\n' >>"$wk/plugin/init.tmux"
  printf '# edit\n' >>"$wk/config.yaml"
  run canopy-doctor
  [[ "$output" == *"tmux-which-key: plugin/init.tmux MODIFIED, it differs from plugin/init.example.tmux"* ]]
  [[ "$output" == *"tmux-which-key: config.yaml MODIFIED, it differs from config.example.yaml"* ]]
  # The tree digest still leaves them out.
  [[ "$output" == *"tmux-which-key: pinned "*", tree matches"* ]]
}

# --- the tmux shim -----------------------------------------------------------

@test "the suite's tmux refuses a call with no target before it connects" {
  CANOPY_SHIM_REFUSALS="$BATS_TEST_TMPDIR/refused"
  export CANOPY_SHIM_REFUSALS
  [ "$(command -v tmux)" = "$CANOPY_TEST_SOCKS/bin/tmux" ] || [[ "$(command -v tmux)" == "$bin/tmux" ]]
  run env -u TMUX -u TMUX_TMPDIR "$CANOPY_TEST_SOCKS/bin/tmux" ls
  [ "$status" -eq 97 ]
  [ "$(cat "$CANOPY_SHIM_REFUSALS")" = "ls" ]
  # And a call that names a socket under the suite's directory goes through.
  run "$CANOPY_TEST_SOCKS/bin/tmux" -L nothing-here ls
  [ "$status" -ne 97 ]
}

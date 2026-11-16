#!/bin/sh
# tmux-which-key's prebuilt menu titles itself "tmux": the root menu's
# prefix Space binding and its two show-wk-menu command aliases. On grofe
# the title says grofe. Run after which-key has loaded; with no which-key
# binding it changes nothing.
#
# tmux 3.7b (and grofe, as it) prints nothing for `list-keys -T prefix
# Space`, so the whole table is filtered for the one binding.
tmp="${TMPDIR:-/tmp}/canopy-wk-title.$$"
trap 'rm -f "$tmp"' EXIT
{
  tmux list-keys -T prefix | grep -E '^bind-key +-T prefix +Space +display-menu '
  tmux show-options -g command-alias | grep 'show-wk-menu' | sed 's/^/set-option -g /'
} | sed 's/\]tmux#\[/]grofe#[/' >"$tmp"
[ -s "$tmp" ] && tmux source-file "$tmp"
exit 0

#!/bin/sh
# tmux-which-key's prebuilt menu titles itself "tmux": the root menu's
# prefix Space binding and its two show-wk-menu command aliases. On grofe
# the title says grofe. Run after which-key has loaded; with no which-key
# binding it changes nothing.
#
# `list-keys -T prefix Space` would print just the one binding on tmux, but
# grofe's answers to that form are empty, so the whole table is filtered.
tmp="${TMPDIR:-/tmp}/canopy-wk-title.$$"
trap 'rm -f "$tmp"' EXIT
{
  tmux list-keys -T prefix | grep -E '^bind-key +-T prefix +Space +display-menu '
  tmux show-options -g command-alias | grep 'show-wk-menu' | sed 's/^/set-option -g /'
} | sed 's/\]tmux#\[/]grofe#[/' >"$tmp"
[ -s "$tmp" ] && tmux source-file "$tmp"
exit 0

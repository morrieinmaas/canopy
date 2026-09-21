# shellcheck shell=sh
# shellcheck disable=SC2154  # CANOPY_ADAPTER_DIR and CANOPY_TX are exported by bin/canopy-agent before it sources this file
# Puts canopy's hooks into Claude Code's own settings file.
#
# Sourced by bin/canopy-agent inside a transaction, so canopy_die,
# canopy_have and canopy_agent_own are already defined, and $CANOPY_TX and
# $CANOPY_ADAPTER_DIR are already set. Every file this touches goes through
# canopy_agent_own first; that is what makes `canopy restore` able to put
# the user's settings back byte for byte.

claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
claude_settings="$claude_config_dir/settings.json"
claude_report="$CANOPY_ADAPTER_DIR/report.sh"

# The directory is required to exist rather than created. If Claude Code has
# never run for this user there is nothing to hook into, and canopy
# inventing a configuration directory for an agent that is not installed is
# a surprise, not a convenience.
[ -d "$claude_config_dir" ] ||
  canopy_die "canopy-agent: $claude_config_dir does not exist, so Claude Code is not set up for this user; nothing to install into"

# The placeholder is substituted with sed, so a store path holding a
# character sed reads as syntax is refused rather than silently mangled.
case "$claude_report" in
  *'|'* | *'&'* | *\\*)
    canopy_die "canopy-agent: the store path $claude_report contains a character canopy cannot substitute safely"
    ;;
  *) ;;
esac

claude_hooks="$(sed "s|{report}|$claude_report|g" "$CANOPY_ADAPTER_DIR/hooks.json")"

canopy_agent_own "$claude_settings"

if [ -f "$claude_settings" ]; then
  # An existing settings file is merged, never replaced: it holds the
  # user's model, theme, permissions and quite possibly hooks of their own.
  #
  # jq is required for this branch and only this branch. Editing arbitrary
  # JSON with sed is how a config file gets corrupted, and a corrupted
  # settings.json stops Claude Code from starting at all.
  canopy_have jq ||
    canopy_die "canopy-agent: $claude_settings already exists and merging JSON needs jq, which is not installed; install jq, or add $CANOPY_ADAPTER_DIR/hooks.json to its \"hooks\" key by hand (replacing {report} with $claude_report)"

  # Canopy's own entries are recognised by the reporter path they carry, so
  # a second run replaces them instead of adding a duplicate set, and an
  # event the user also hooks keeps their entries alongside canopy's.
  claude_merged="$claude_settings.canopy-merge.$$"
  if ! jq --argjson new "$claude_hooks" --arg marker "$claude_report" '
        def drop_canopy($m):
          with_entries(
            .value |= (
              map(.hooks |= map(select(((.command // "") | contains($m)) | not)))
              | map(select((.hooks | length) > 0))
            )
          );
        ((.hooks // {}) | drop_canopy($marker)) as $kept
        | .hooks = ($kept + ($new | with_entries(.value = (($kept[.key] // []) + .value))))
      ' "$claude_settings" >"$claude_merged"; then
    rm -f "$claude_merged"
    canopy_die "canopy-agent: $claude_settings is not valid JSON, so canopy will not rewrite it"
  fi
  # Renamed over the path rather than written into it. When settings.json is
  # a symlink, which a dotfiles manager routinely makes it, writing into it
  # would modify a file canopy never recorded and cannot promise to restore.
  mv "$claude_merged" "$claude_settings"
else
  # rm first: a dangling symlink here is still a symlink, and a redirect
  # into it would create the file it points at.
  rm -f "$claude_settings"
  printf '{\n  "hooks": %s\n}\n' "$claude_hooks" >"$claude_settings"
fi

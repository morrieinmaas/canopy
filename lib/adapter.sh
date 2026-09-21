# shellcheck shell=sh
# shellcheck disable=SC2154  # CANOPY_STORE/CANOPY_CONFIG are exported by lib/env.sh's canopy_paths
# shellcheck disable=SC3043  # `local` is explicitly permitted (plan's Global Constraints): universally supported by dash/ash/bash, used here so callers never see this file's internals

# The agent adapter contract.
#
# An adapter is a directory holding one file, `manifest`, of `key=value`
# lines. It tells canopy how to recognise one agent in a pane and how to
# put that agent back where it was. docs/adapters/contract.md is the
# document; this file is the only thing that reads it.
#
# Adapters are looked up by directory name, and the manifest's own `id`
# must agree with that name. One name, checked, rather than two names that
# can drift: an adapter copied into place under the wrong directory is
# caught the first time anything reads it, not the first time a pane fails
# to resume.
#
# The search order is $CANOPY_CONFIG/adapters before $CANOPY_STORE/adapters,
# so a user's adapter of a given id wins over a shipped one of the same id.

# canopy_adapter_keys
# The six keys, in the order the contract document lists them. Every key
# is required in every manifest; a value may be empty, a key may not be
# absent. Absent-means-default is how two readers of the same file end up
# disagreeing about what the default was.
canopy_adapter_keys() {
  printf 'id command resume_template can_pin_at_launch launch_template detect_draft\n'
}

# canopy_adapter_dir <id>
# The directory holding <id>'s manifest, or 1 if no adapter has that id.
canopy_adapter_dir() {
  local dir
  for dir in "$CANOPY_CONFIG/adapters" "$CANOPY_STORE/adapters"; do
    if [ -f "$dir/$1/manifest" ]; then
      printf '%s\n' "$dir/$1"
      return 0
    fi
  done
  return 1
}

# canopy_adapter_list
# Every installed adapter id, one per line, sorted and deduplicated. An
# adapter shadowed by one of the same id earlier in the search path is
# listed once, because there is one adapter by that id as far as every
# caller is concerned.
canopy_adapter_list() {
  local dir entry name
  {
    for dir in "$CANOPY_CONFIG/adapters" "$CANOPY_STORE/adapters"; do
      [ -d "$dir" ] || continue
      for entry in "$dir"/*/; do
        [ -f "$entry/manifest" ] || continue
        name="${entry%/}"
        printf '%s\n' "${name##*/}"
      done
    done
  } | LC_ALL=C sort -u
}

# canopy_adapter_get <id> <key>
# Prints one key's value. Returns 1 when no adapter has that id, so a
# caller can ask whether an adapter exists. Every other problem is a
# broken contract rather than a missing one, and dies loudly: an unknown
# key in the request, an unknown or duplicated or missing key in the
# manifest, a line that is not key=value, an id that disagrees with the
# directory, a can_pin_at_launch that is neither yes nor no, or a template
# with no {id} to substitute into.
#
# The whole manifest is parsed and validated on every call, not just the
# requested line. A reader that stopped at the key it wanted would happily
# return a correct value out of a manifest that is wrong three lines
# lower, and the consumer that eventually trips over that line would be
# debugging the wrong file.
canopy_adapter_get() {
  local id key dir manifest known line k v seen
  local a_id a_command a_resume a_pin a_launch a_draft
  id="$1"
  key="$2"
  known="$(canopy_adapter_keys)"

  case " $known " in
    *" $key "*) ;;
    *) canopy_die "canopy_adapter_get: $key is not a contract key (the contract is: $known)" ;;
  esac

  if ! dir="$(canopy_adapter_dir "$id")"; then
    printf 'canopy_adapter_get: no adapter named %s is installed\n' "$id" >&2
    return 1
  fi
  manifest="$dir/manifest"

  seen=""
  a_id=""
  a_command=""
  a_resume=""
  a_pin=""
  a_launch=""
  a_draft=""

  # `|| [ -n "$line" ]` so a final line with no trailing newline is still
  # read rather than silently dropped, which is how a hand-edited manifest
  # loses its last key.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
      *'='*) ;;
      *) canopy_die "$manifest: not a key=value line: $line" ;;
    esac
    k="${line%%=*}"
    v="${line#*=}"
    case " $known " in
      *" $k "*) ;;
      *) canopy_die "$manifest: unknown key: $k (the contract is: $known)" ;;
    esac
    case " $seen " in
      *" $k "*) canopy_die "$manifest: duplicate key: $k" ;;
      *) ;;
    esac
    seen="$seen $k "
    case "$k" in
      id) a_id="$v" ;;
      command) a_command="$v" ;;
      resume_template) a_resume="$v" ;;
      can_pin_at_launch) a_pin="$v" ;;
      launch_template) a_launch="$v" ;;
      detect_draft) a_draft="$v" ;;
      *) ;;
    esac
  done <"$manifest"

  for k in $known; do
    case " $seen " in
      *" $k "*) ;;
      *) canopy_die "$manifest: missing required key: $k" ;;
    esac
  done

  [ "$a_id" = "$id" ] ||
    canopy_die "$manifest: id is $a_id but the adapter directory is named $id; they must agree"
  [ -n "$a_command" ] ||
    canopy_die "$manifest: command is empty, so no pane could ever be recognised as this agent"
  case "$a_pin" in
    yes | no) ;;
    *) canopy_die "$manifest: can_pin_at_launch must be yes or no, got: $a_pin" ;;
  esac
  case "$a_resume" in
    *'{id}'*) ;;
    *) canopy_die "$manifest: resume_template must contain the {id} placeholder, got: $a_resume" ;;
  esac
  if [ "$a_pin" = yes ]; then
    case "$a_launch" in
      *'{id}'*) ;;
      *) canopy_die "$manifest: can_pin_at_launch is yes, so launch_template must contain the {id} placeholder, got: $a_launch" ;;
    esac
  fi

  case "$key" in
    id) printf '%s\n' "$a_id" ;;
    command) printf '%s\n' "$a_command" ;;
    resume_template) printf '%s\n' "$a_resume" ;;
    can_pin_at_launch) printf '%s\n' "$a_pin" ;;
    launch_template) printf '%s\n' "$a_launch" ;;
    detect_draft) printf '%s\n' "$a_draft" ;;
    *) ;;
  esac
}

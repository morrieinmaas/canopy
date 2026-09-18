# shellcheck shell=sh
# shellcheck disable=SC2154  # CANOPY_STATE is exported by lib/env.sh's canopy_paths
# shellcheck disable=SC3043  # `local` is explicitly permitted (plan's Global Constraints): universally supported by dash/ash/bash, used here so callers never see this file's internals

# Manifest format (tab-separated), five columns, defined once here:
#   action<TAB>path<TAB>pre(absent|sha256)<TAB>backup_rel(-|path)<TAB>post(sha256|absent)
# action is one of: own|splice|drop|generate|env
# Paths must not contain tab or newline characters; the manifest format
# cannot represent them (a tab or newline in a path corrupts the row into
# extra fields). canopy_tx_record enforces this at record time: it fails
# loudly via canopy_die instead of writing a row that cannot round-trip,
# which restore.sh would otherwise silently skip during recovery, far
# from the cause, and precisely when someone is relying on the tool.

# Path mangling for backup filenames: percent-encode "%" as "%25" and
# "/" as "%2F", leaving every other character as-is. This is fixed-width
# encoding for the one character ("%") that could otherwise be confused
# with an encoded sequence, so it cannot collide the way a variable-width
# escape (e.g. "%"->"%%", "/"->"%") can: a path containing "/%" and one
# containing "%/" mangle to different strings, because the two escaped
# characters always occupy a fixed 3-byte slot and can never be mistaken
# for each other regardless of ordering. Only "%" and "/" are encoded;
# this is a backup filename, not a URL, so nothing else needs escaping,
# and encoding more would only make backups harder to read by hand.
canopy_tx_mangle() {
  printf '%s' "$1" | sed 's/%/%25/g' | sed 's#/#%2F#g'
}

# canopy_tx_begin <label>
# Creates $CANOPY_STATE/backups/<epoch>-<label>/, prints its path, and
# seeds it with a manifest.tsv header and a self-contained restore.sh.
# Two transactions can begin within the same epoch second; uniqueness is
# enforced atomically via mkdir itself (it succeeds exactly once for a
# given path), appending a numeric suffix on collision.
canopy_tx_begin() {
  local label epoch base tx attempt max_attempts
  label="$1"
  epoch="$(date +%s)"
  mkdir -p "$CANOPY_STATE/backups"
  base="$CANOPY_STATE/backups/${epoch}-${label}"
  tx="$base"
  attempt=1
  max_attempts=1000
  while ! mkdir "$tx" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$max_attempts" ]; then
      canopy_die "canopy_tx_begin: could not allocate a unique transaction dir for $base"
    fi
    tx="${base}.${attempt}"
  done
  mkdir -p "$tx/files"
  printf '# action\tpath\tpre\tbackup_rel\tpost\n' >"$tx/manifest.tsv"
  canopy_tx_write_restore "$tx/restore.sh"
  chmod +x "$tx/restore.sh"
  printf '%s\n' "$tx"
}

# canopy_tx_record <txdir> <action> <path>
# Captures pre-state for path: if it exists, copies it into
# <txdir>/files/<mangled> and records its sha256; otherwise records absent.
# The post column is filled in later by canopy_tx_commit.
canopy_tx_record() {
  local tx action path nl tab mangled pre backup_rel
  tx="$1"
  action="$2"
  path="$3"
  case "$action" in
    own | splice | drop | generate | env) ;;
    *) canopy_die "canopy_tx_record: invalid action '$action' (expected own|splice|drop|generate|env)" ;;
  esac
  nl='
'
  tab="$(printf '\t')"
  case "$path" in
    *"$tab"* | *"$nl"*)
      canopy_die "canopy_tx_record: path contains a tab or newline, which the manifest format cannot represent: $path"
      ;;
    *) ;;
  esac
  if [ -e "$path" ]; then
    mangled="$(canopy_tx_mangle "$path")"
    cp -p "$path" "$tx/files/$mangled"
    pre="$(canopy_sha256 "$path")"
    backup_rel="files/$mangled"
  else
    pre="absent"
    backup_rel="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$path" "$pre" "$backup_rel" "" >>"$tx/manifest.tsv"
}

# canopy_tx_commit <txdir>
# Records each recorded path's post-state sha256 (or absent) and marks
# the transaction complete.
canopy_tx_commit() {
  local tx manifest path post tmp
  tx="$1"
  manifest="$tx/manifest.tsv"
  awk -F'\t' 'NR > 1 { print $2 }' "$manifest" | sort -u | while IFS= read -r path; do
    if [ -e "$path" ]; then
      post="$(canopy_sha256 "$path")"
    else
      post="absent"
    fi
    tmp="$manifest.tmp"
    awk -F'\t' -v OFS='\t' -v p="$path" -v post="$post" '
      NR == 1 { print; next }
      $2 == p { $5 = post }
      { print }
    ' "$manifest" >"$tmp" && mv "$tmp" "$manifest"
  done
  touch "$tx/.committed"
}

# canopy_tx_write_restore <path>
# Writes a genuinely self-contained restore.sh to <path>. It reads only
# manifest.tsv and files/ relative to its own location, and never sources
# or calls anything from the canopy store; it is the escape hatch for
# when canopy itself is what broke.
canopy_tx_write_restore() {
  cat >"$1" <<'RESTORE_EOF'
#!/bin/sh
# Self-contained restore script for this transaction. Reads only
# manifest.tsv and files/ next to this script; depends on nothing
# outside this directory.
set -e

dir=$(cd "$(dirname "$0")" && pwd)
manifest="$dir/manifest.tsv"

if [ ! -f "$manifest" ]; then
  echo "restore.sh: $manifest not found" >&2
  exit 1
fi

tab=$(printf '\t')
restored=0
removed=0

while IFS="$tab" read -r action path pre backup_rel post; do
  case "$action" in
  '#'* | '') continue ;;
  esac
  : "$post"
  if [ "$pre" = "absent" ]; then
    if [ -e "$path" ]; then
      rm -f "$path"
      removed=$((removed + 1))
    fi
  elif [ "$backup_rel" != "-" ] && [ -f "$dir/$backup_rel" ]; then
    mkdir -p "$(dirname "$path")"
    cp -p "$dir/$backup_rel" "$path"
    restored=$((restored + 1))
  fi
done <"$manifest"

printf 'restore: %d file(s) restored, %d file(s) removed\n' "$restored" "$removed"
RESTORE_EOF
}

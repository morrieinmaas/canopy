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
# Captures pre-state for path: if anything is there, copies it into
# <txdir>/files/<mangled> and records its state per canopy_file_state;
# otherwise records absent. The post column is filled in later by
# canopy_tx_commit.
canopy_tx_record() {
  local tx action path nl tab ordinal mangled pre backup_rel
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
  pre="$(canopy_file_state "$path")"
  # Both the path and, for a symlink, the recorded target go into the row,
  # so both have to round-trip through a tab-separated line. Failing here
  # is loud; writing a row restore.sh would silently misparse is not.
  case "$path$pre" in
    *"$tab"* | *"$nl"*)
      canopy_die "canopy_tx_record: path or symlink target contains a tab or newline, which the manifest format cannot represent: $path"
      ;;
    *) ;;
  esac
  # The ordinal this row is about to get: the manifest holds one header
  # line plus one line per row already recorded, so the first data row is
  # ordinal 1.
  ordinal="$(awk 'END { print NR }' "$tx/manifest.tsv")"
  if [ "$pre" = "absent" ]; then
    backup_rel="-"
  else
    # Backup filenames are unique per row, not per path. Deriving the name
    # from the path alone meant recording the same path twice in one
    # transaction made the second cp clobber the first, leaving the
    # first row's pre hash describing bytes that were no longer on disk.
    # The percent-encoded path stays for readability and the row ordinal
    # is appended: two rows can never collide, because the name ends in
    # ".<ordinal>" and no two rows share an ordinal.
    #
    # -P: a symlink is backed up as the link it is, never as a copy of
    # whatever it points at. The link is the artifact canopy is taking
    # ownership of; its target is a file canopy never recorded and must
    # not touch.
    mangled="$(canopy_tx_mangle "$path").$ordinal"
    cp -pP "$path" "$tx/files/$mangled"
    backup_rel="files/$mangled"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$path" "$pre" "$backup_rel" "" >>"$tx/manifest.tsv"
}

# canopy_tx_commit <tx>
# Stamps each row's post-state and marks the transaction committed.
# Post-stamping is per row, not per path: rows are the unit of this
# manifest (a path may legitimately appear on more than one of them), and
# a single pass that rewrites each row in place cannot leave one row's
# columns describing another row's file.
canopy_tx_commit() {
  local tx manifest tmp tab action path pre backup_rel post
  tx="$1"
  manifest="$tx/manifest.tsv"
  tmp="$manifest.tmp"
  tab="$(printf '\t')"
  : >"$tmp"
  while IFS="$tab" read -r action path pre backup_rel post; do
    case "$action" in
      '#'*)
        printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$path" "$pre" "$backup_rel" "$post" >>"$tmp"
        continue
        ;;
      '') continue ;;
      *) ;;
    esac
    post="$(canopy_file_state "$path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$path" "$pre" "$backup_rel" "$post" >>"$tmp"
  done <"$manifest"
  mv "$tmp" "$manifest"
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
  # -e is false for a dangling symlink, so -L is asked too, both for what
  # is on disk now and for the backup: a backed-up relative symlink almost
  # never resolves from inside files/, and treating that as "no backup"
  # skipped the restore silently.
  if [ "$pre" = "absent" ]; then
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -f "$path"
      removed=$((removed + 1))
    fi
  elif [ "$backup_rel" != "-" ] && { [ -e "$dir/$backup_rel" ] || [ -L "$dir/$backup_rel" ]; }; then
    mkdir -p "$(dirname "$path")"
    # Removed first, then copied with -P: whatever is at $path may itself
    # be a symlink, and writing into it would write through to a file this
    # manifest never recorded. A backed-up symlink is put back as the link
    # it was, pointing where it pointed.
    rm -f "$path"
    cp -pP "$dir/$backup_rel" "$path"
    restored=$((restored + 1))
  fi
done <"$manifest"

printf 'restore: %d file(s) restored, %d file(s) removed\n' "$restored" "$removed"
RESTORE_EOF
}

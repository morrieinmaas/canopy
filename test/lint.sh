#!/bin/sh
# The one definition of what gets linted, so a contributor running this
# locally lints exactly what CI lints. Before this script existed, the
# same file list and shellcheck/shfmt flags were duplicated in
# .github/workflows/ci.yml and docs/06-contributing-and-testing.md, and
# the two only had to agree on paper.
#
# That duplication was not what actually let SC2329 findings reach the
# runner unseen: the real cause was an unpinned shellcheck version, which
# mise.toml resolved once to a stale local install while CI resolved a
# fresh one on every run. mise.toml now pins an exact version for that
# reason. This script closes the other half of the same failure shape,
# so the file list and flags cannot drift apart either.
#
# Usage: sh test/lint.sh
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

status=0

set --
for f in bin/* lib/*.sh test/smoke/*.sh; do
  [ -e "$f" ] && set -- "$@" "$f"
done
if [ "$#" -gt 0 ]; then
  shellcheck "$@" || status=1
fi

set --
for d in bin lib test/smoke; do
  [ -d "$d" ] && set -- "$@" "$d"
done
if [ "$#" -gt 0 ]; then
  shfmt -d -i 2 -ci "$@" || status=1
fi

exit "$status"

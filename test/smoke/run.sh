#!/bin/sh
# Builds every smoke image, runs every scenario inside each of them, and
# prints one pass/fail matrix. Exits non-zero if any scenario fails, if a
# build fails, or if a container stops before finishing its scenarios.
#
# Usage: test/smoke/run.sh [image...]     (default: debian alpine)
#        DOCKER=podman test/smoke/run.sh
#
# The two images are chosen for what they catch. debian:stable-slim makes
# /bin/sh dash, which catches a bashism. alpine:latest makes it BusyBox
# ash and the whole userland BusyBox rather than GNU, which catches a
# GNU-only flag in find, grep, sed, cp or date. canopy has only ever run
# on macOS with GNU coreutils on the PATH, so neither risk was tested
# anywhere before this harness.
#
# Nothing here runs canopy on the host. Installing canopy writes to
# ~/.config/tmux and ~/.tmux.conf, and starting tmux to check what loaded
# would attach to a real server, so both belong in a container and only in
# a container.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
docker_cli="${DOCKER:-docker}"

if [ "$#" -eq 0 ]; then
  set -- debian alpine
fi

if ! command -v "${docker_cli}" >/dev/null 2>&1; then
  printf 'smoke: %s not found on PATH; set DOCKER=<cli> to name another one\n' "${docker_cli}" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
matrix="${tmpdir}/matrix.tsv"
: >"${matrix}"
overall=0

for image in "$@"; do
  tag="canopy-smoke-${image}"
  dockerfile="${here}/Dockerfile.${image}"
  if [ ! -f "${dockerfile}" ]; then
    printf 'smoke: no such image definition: %s\n' "${dockerfile}" >&2
    exit 1
  fi

  printf '\n### building %s ###\n' "${tag}"
  build_log="${tmpdir}/${image}.build.log"
  if ! "${docker_cli}" build -f "${dockerfile}" -t "${tag}" "${repo}" >"${build_log}" 2>&1; then
    printf 'smoke: build FAILED for %s\n' "${tag}" >&2
    cat "${build_log}" >&2
    printf '%s\tbuild\tFAIL\timage build\n' "${image}" >>"${matrix}"
    overall=1
    continue
  fi
  printf 'built %s\n' "${tag}"

  printf '\n### running scenarios in %s ###\n' "${tag}"
  run_log="${tmpdir}/${image}.run.log"
  # The container's own exit status is not what is trusted here: it
  # reaches this shell through a pipe, and POSIX sh has no pipefail. The
  # scenario file prints a RESULT row per scenario and a
  # SCENARIOS-COMPLETE sentinel only when it reaches the end, so a crash
  # partway through is caught by the missing sentinel rather than by a
  # status this loop cannot see.
  "${docker_cli}" run --rm "${tag}" 2>&1 | tee "${run_log}" || :

  if ! grep -q '^SCENARIOS-COMPLETE ' "${run_log}"; then
    printf 'smoke: %s stopped before finishing its scenarios\n' "${tag}" >&2
    printf '%s\trun\tFAIL\tscenarios did not run to completion\n' "${image}" >>"${matrix}"
    overall=1
  fi

  awk -F'\t' -v img="${image}" '
    $1 == "RESULT" { printf "%s\t%s\t%s\t%s\n", img, $2, $3, $4 }
  ' "${run_log}" >>"${matrix}"
done

printf '\n### pass/fail matrix ###\n\n'
if [ ! -s "${matrix}" ]; then
  printf 'smoke: no scenarios reported a result\n' >&2
  exit 1
fi

awk -F'\t' '
  BEGIN { printf "%-8s  %-4s  %-6s  %s\n", "image", "id", "result", "scenario" }
  { printf "%-8s  %-4s  %-6s  %s\n", $1, $2, $3, $4; if ($3 == "FAIL") failed++ }
  END {
    printf "\n%d scenario result(s), %d failed\n", NR, failed + 0
    if (failed > 0) exit 1
  }
' "${matrix}" || overall=1

if [ "${overall}" -ne 0 ]; then
  printf '\nsmoke: FAILED\n' >&2
  exit 1
fi
printf '\nsmoke: OK\n'

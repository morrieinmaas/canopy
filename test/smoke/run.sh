#!/bin/sh
# Builds every smoke image, runs every scenario inside each of them, and
# prints one pass/fail matrix. Exits non-zero if any scenario fails, if a
# build fails, or if a container stops before finishing its scenarios.
#
# Usage: test/smoke/run.sh [image...]     (default: debian alpine fedora arch)
#        DOCKER=podman test/smoke/run.sh
#
# Each image is here for something specific it catches:
#
#   debian  /bin/sh is dash, which catches a bashism
#   alpine  /bin/sh is BusyBox ash and the whole userland is BusyBox rather
#           than GNU, which catches a GNU-only flag in find, grep, sed, cp
#           or date
#   fedora  the RPM half of the world, and one of the two Linux platforms
#           canopy is actually installed on
#   arch    rolling, so the newest tmux, coreutils and git of the four, and
#           the other platform canopy is installed on
#
# canopy has only ever run on macOS with GNU coreutils on the PATH, so none
# of those risks was tested anywhere before this harness. The first two are
# the portability net; the last two are the "does it work where it is used"
# check, and an image can be pointed at another base with
# CANOPY_SMOKE_BASE_<IMAGE> (see below).
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
  set -- debian alpine fedora arch
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

  # An image may take a different base than its default, which is what
  # CANOPY_SMOKE_BASE_<IMAGE> is for: the Arch image needs it on an arm64
  # host, because the official Arch image is amd64 only and emulating it
  # makes qemu rewrite what `ps` reports. Two branches rather than an
  # unquoted variable holding the flag, so nothing here depends on word
  # splitting.
  base_var="CANOPY_SMOKE_BASE_$(printf '%s' "${image}" | tr '[:lower:]-' '[:upper:]_')"
  eval "base=\${${base_var}:-}"

  printf '\n### building %s ###\n' "${tag}"
  build_log="${tmpdir}/${image}.build.log"
  if [ -n "${base}" ]; then
    printf 'base: %s (from %s)\n' "${base}" "${base_var}"
    build_ok=0
    "${docker_cli}" build --build-arg "BASE=${base}" -f "${dockerfile}" \
      -t "${tag}" "${repo}" >"${build_log}" 2>&1 || build_ok=1
  else
    build_ok=0
    "${docker_cli}" build -f "${dockerfile}" -t "${tag}" "${repo}" >"${build_log}" 2>&1 || build_ok=1
  fi
  if [ "${build_ok}" -ne 0 ]; then
    printf 'smoke: build FAILED for %s\n' "${tag}" >&2
    cat "${build_log}" >&2
    printf '%s\tbuild\tFAIL\timage build\n' "${image}" >>"${matrix}"
    overall=1
    continue
  fi
  printf 'built %s\n' "${tag}"

  # Whether this image runs natively or under emulation, said out loud,
  # because emulation can break these scenarios in a way that reads as a
  # canopy bug rather than as an environment one.
  #
  # Some emulated setups have `ps` report the emulator instead of the
  # process: `/usr/bin/qemu-x86_64-static /bin/sleep sleep 30` rather than
  # `sleep 30`. canopy recognises an agent pane by the command name `ps`
  # reports, so where that happens no pane is recognised as an agent, and
  # the reboot scenarios fail with "no agent panes are open" on a machine
  # full of them. Observed on an amd64 alpine image on an arm64 host; an
  # amd64 arch image on the same host reported the command cleanly, so this
  # is a warning rather than a prediction.
  #
  # It is easy to hit by accident: a container CLI reuses an image already in
  # local storage rather than re-resolving it, so one stale `alpine:latest`
  # of the wrong architecture is enough.
  image_arch="$("${docker_cli}" image inspect "${tag}" --format '{{.Architecture}}' 2>/dev/null || printf 'unknown')"
  case "$(uname -m)" in
    aarch64 | arm64) host_arch=arm64 ;;
    x86_64 | amd64) host_arch=amd64 ;;
    *) host_arch="$(uname -m)" ;;
  esac
  if [ "${image_arch}" != "unknown" ] && [ "${image_arch}" != "${host_arch}" ]; then
    printf '\n'
    printf 'smoke: WARNING: %s is %s on a %s host, so it runs under emulation.\n' \
      "${tag}" "${image_arch}" "${host_arch}" >&2
    printf '  Some emulators have ps report themselves rather than the process, and\n' >&2
    printf '  canopy recognises an agent pane by the command name ps reports. If the\n' >&2
    printf '  reboot scenarios fail saying no agent panes are open, that is why.\n' >&2
    printf '  Pull the matching image first: %s pull --platform linux/%s <base>\n' \
      "${docker_cli}" "${host_arch}" >&2
    printf '\n'
  fi

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

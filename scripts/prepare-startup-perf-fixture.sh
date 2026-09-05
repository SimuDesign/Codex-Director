#!/bin/zsh
set -euo pipefail

# Prepare synthetic data only. This script never launches Codex Director and
# never derives a path from HOME, CODEX_HOME, or an application preference.
readonly script_root="${0:A:h:h}"
readonly fixture_root="/tmp/codex-director-startup-perf"
readonly fixture_package="${script_root}/Tools/StartupPerformanceFixtureTool"

preflight=0
if [[ "${1:-}" == "--preflight" ]]; then
  preflight=1
  shift
fi

if (( preflight == 1 && ( $# != 2 ) )); then
  print -u2 'error=usage_preflight'
  exit 2
fi
if (( preflight == 0 && ( $# < 1 || $# > 2 ) )); then
  print -u2 'error=usage'
  exit 2
fi

case "$1" in
  cachedIndexed|uncachedIndexed|uncachedNoIndex) ;;
  *) print -u2 'error=invalid_scenario'; exit 2 ;;
esac

if [[ ! -f "${fixture_package}/Package.swift" || -L "${fixture_package}/Package.swift" ]]; then
  print -u2 'error=fixture_tool_unavailable'
  exit 2
fi

if (( preflight == 1 )); then
  fixture_id="$2"
  if [[ ! "$fixture_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' ]]; then
    print -u2 'error=invalid_fixture_id'
    exit 2
  fi
fi

if [[ ! -d "$fixture_root" ]]; then
  /bin/mkdir -p "$fixture_root"
fi
if [[ -L "$fixture_root" ]]; then
  print -u2 'error=unsafe_fixture_root'
  exit 2
fi

fixture_id="${2:-$(/usr/bin/uuidgen)}"
# Keep the shell boundary strict as well as the Swift tool's UUID validation.
if [[ ! "$fixture_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' ]]; then
  print -u2 'error=invalid_fixture_id'
  exit 2
fi

# The linked Core migration/DTO fixture tool writes only the fixed synthetic
# root and prints aggregate counters. Its scratch build is disposable and the
# command never launches/relaunches an application.
scratch_root="/tmp/codex-director-startup-perf-tool-${fixture_id}"
if [[ -e "$scratch_root" && -L "$scratch_root" ]]; then
  print -u2 'error=unsafe_tool_scratch'
  exit 2
fi
/bin/mkdir -p "$scratch_root"
if (( preflight == 1 )); then
  exec /usr/bin/swift run --package-path "$fixture_package" --scratch-path "$scratch_root" --jobs 2 -c release StartupPerformanceFixtureTool --preflight "$1" "$fixture_id"
else
  exec /usr/bin/swift run --package-path "$fixture_package" --scratch-path "$scratch_root" --jobs 2 -c release StartupPerformanceFixtureTool "$1" "$fixture_id"
fi

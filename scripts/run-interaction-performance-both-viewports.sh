#!/bin/zsh
set -euo pipefail

readonly script_root="${0:A:h}"
readonly sample_count=20
fixture_name=interactionStress
build_root=""

if (( $# > 0 )); then
  [[ "$1" == --fixture && $# == 2 ]] || {
    print -u2 "Usage: $0 [--fixture interactionStress|representative|interactionRepresentative]"
    exit 2
  }
  fixture_name="$2"
fi
[[ "$fixture_name" == interactionStress || "$fixture_name" == representative || "$fixture_name" == interactionRepresentative ]] || {
  print -u2 'error=interaction_dual_viewport_fixture_invalid'
  exit 2
}

cleanup() {
  if [[ -n "$build_root" && "$build_root:h" == /tmp && "${build_root:t}" == codex-director-interaction-perf-build.* && -d "$build_root" && ! -L "$build_root" ]]; then
    /bin/rm -rf -- "$build_root"
  fi
}
trap cleanup EXIT INT TERM

build_output="$($script_root/build-interaction-performance-harness.sh)"
print -r -- "$build_output" | rg '^(stage|build_root|app_path|executable)='
build_root="$(print -r -- "$build_output" | sed -n 's/^build_root=//p' | tail -1)"
[[ "$build_root:h" == /tmp && "${build_root:t}" == codex-director-interaction-perf-build.* && -d "$build_root" && ! -L "$build_root" ]] || {
  print -u2 'error=interaction_dual_viewport_build_root_invalid'
  exit 1
}

print "viewport_run=720x480 samples=$sample_count"
"$script_root/run-interaction-performance.sh" \
  --reuse-build "$build_root" --fixture "$fixture_name" --samples "$sample_count" --width 720 --height 480

print "viewport_run=1280x800 samples=$sample_count"
"$script_root/run-interaction-performance.sh" \
  --reuse-build "$build_root" --fixture "$fixture_name" --samples "$sample_count" --width 1280 --height 800

print "interaction_dual_viewport=complete fixture=$fixture_name samples=$sample_count build_reused=true"

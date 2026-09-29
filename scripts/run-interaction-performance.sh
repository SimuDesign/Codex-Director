#!/bin/zsh
set -euo pipefail

readonly script_root="${0:A:h}"
readonly project_root="${script_root:h}"
sample_count=20
width=1280
height=800
fixture_name=interactionStress
output_directory=""
reuse_build_root=""
fixture_id="$(/usr/bin/uuidgen)"
synthetic_root="/tmp/codex-director-interaction-perf/${fixture_id}-synthetic"
process_id=""
watchdog_id=""
build_root=""

usage() {
  print -u2 "Usage: $0 [--fixture interactionStress|representative|interactionRepresentative] [--samples 1...50] [--width 720|1280] [--height 480|800] [--output /tmp/codex-director-interaction-perf/<name>.json] [--reuse-build /tmp/codex-director-interaction-perf-build.<id>]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --fixture) (( $# >= 2 )) || usage; fixture_name="$2"; shift 2 ;;
    --samples) (( $# >= 2 )) || usage; sample_count="$2"; shift 2 ;;
    --width) (( $# >= 2 )) || usage; width="$2"; shift 2 ;;
    --height) (( $# >= 2 )) || usage; height="$2"; shift 2 ;;
    --output) (( $# >= 2 )) || usage; output_directory="$2"; shift 2 ;;
    --reuse-build) (( $# >= 2 )) || usage; reuse_build_root="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$sample_count" =~ '^[1-9][0-9]*$' && "$sample_count" -le 50 ]] || usage
[[ "$width" == 720 || "$width" == 1280 ]] || usage
[[ "$height" == 480 || "$height" == 800 ]] || usage
[[ "$fixture_name" == interactionStress || "$fixture_name" == representative || "$fixture_name" == interactionRepresentative ]] || usage
if [[ -n "$reuse_build_root" ]]; then
  [[ "$reuse_build_root:h" == /tmp && "${reuse_build_root:t}" == codex-director-interaction-perf-build.* && "$reuse_build_root" != */../* && "$reuse_build_root" != */./* && -d "$reuse_build_root" && ! -L "$reuse_build_root" ]] || {
    print -u2 'error=reuse_build_root_invalid'
    exit 2
  }
fi

# Startup plus first-entry work is variable on a cold Release build. Give a
# 20-sample run enough time to finish at either supported viewport while
# keeping a hard upper bound for a wedged diagnostic process.
if [[ "$width" == 1280 ]]; then
  seconds_per_sample=14
else
  seconds_per_sample=12
fi
timeout_seconds=$((45 + sample_count * seconds_per_sample))
(( timeout_seconds < 90 )) && timeout_seconds=90
(( timeout_seconds > 600 )) && timeout_seconds=600

if [[ -z "$output_directory" ]]; then
  output_directory="/tmp/codex-director-interaction-perf/$fixture_id-${width}x${height}.json"
fi
[[ "$output_directory" == /tmp/codex-director-interaction-perf/*.json ]] || {
  print -u2 'Output must be a .json file under /tmp/codex-director-interaction-perf/'
  exit 2
}
[[ ! -e "$output_directory" ]] || { print -u2 "Output already exists: $output_directory"; exit 1; }

cleanup() {
  if [[ -n "$watchdog_id" ]] && /bin/kill -0 "$watchdog_id" 2>/dev/null; then /bin/kill "$watchdog_id" 2>/dev/null || true; fi
  if [[ -n "$process_id" ]] && /bin/kill -0 "$process_id" 2>/dev/null; then /bin/kill -TERM "$process_id" 2>/dev/null || true; fi
  if [[ -z "$reuse_build_root" && -n "$build_root" && "$build_root" == /tmp/codex-director-interaction-perf-build.* && -d "$build_root" && ! -L "$build_root" ]]; then
    /bin/rm -rf "$build_root"
  fi
  if [[ -n "$synthetic_root" && "$synthetic_root" == /tmp/codex-director-interaction-perf/*-synthetic && -d "$synthetic_root" && ! -L "$synthetic_root" ]]; then
    /bin/rm -rf "$synthetic_root"
  fi
}
trap cleanup EXIT INT TERM

if [[ -n "$reuse_build_root" ]]; then
  build_root="$reuse_build_root"
  app_path="$build_root/derived-data/Build/Products/Release/Codex Director.app"
  print "stage=interaction_harness_reused optimization=release synthetic=true"
  print "build_root=$build_root"
  print "app_path=$app_path"
else
  build_output="$($script_root/build-interaction-performance-harness.sh)"
  print -r -- "$build_output" | rg '^(stage|build_root|app_path|executable)='
  app_path="$(print -r -- "$build_output" | sed -n 's/^app_path=//p' | tail -1)"
  build_root="$(print -r -- "$build_output" | sed -n 's/^build_root=//p' | tail -1)"
fi
contract_path="$build_root/interaction-harness-contract.txt"
[[ -f "$contract_path" && ! -L "$contract_path" && "$(<"$contract_path")" == 'schema=2;bundle=com.peiweitang.CodexDirector.InteractionPerformance;mode=true;configuration=Release;signature=ad-hoc' ]] || {
  print -u2 'error=interaction_harness_contract_missing'
  exit 1
}
executable="$app_path/Contents/MacOS/Codex Director"
[[ -x "$executable" ]] || { print -u2 'error=interaction_executable_unavailable'; exit 1; }
plist_path="$app_path/Contents/Info.plist"
plist_mode="$(/usr/libexec/PlistBuddy -c 'Print :DirectorInteractionPerformanceMode' "$plist_path" 2>/dev/null || true)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null || true)"
[[ "$plist_mode" == "true" && "$bundle_id" == "com.peiweitang.CodexDirector.InteractionPerformance" ]] || {
  print -u2 'error=interaction_harness_identity_verification_failed'
  exit 1
}
/usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || {
  print -u2 'error=interaction_harness_signature_verification_failed'
  exit 1
}

/bin/mkdir -p "${output_directory:h}"
[[ ! -e "$synthetic_root" && ! -L "$synthetic_root" ]] || { print -u2 "Synthetic fixture root already exists: $synthetic_root"; exit 1; }
log_path="${output_directory:r}.log"
CODEX_DIRECTOR_INTERACTION_PERFORMANCE=1 \
CODEX_DIRECTOR_INTERACTION_PERFORMANCE_RUNTIME=1 \
CODEX_DIRECTOR_INTERACTION_TEMP_ROOT="$synthetic_root" \
CODEX_DIRECTOR_INTERACTION_SAMPLES="$sample_count" \
CODEX_DIRECTOR_INTERACTION_WIDTH="$width" \
CODEX_DIRECTOR_INTERACTION_HEIGHT="$height" \
CODEX_DIRECTOR_INTERACTION_FIXTURE="$fixture_name" \
CODEX_DIRECTOR_INTERACTION_PERF_OUTPUT="$output_directory" \
  "$executable" >"$log_path" 2>&1 &
process_id=$!
(
  /bin/sleep "$timeout_seconds"
  if /bin/kill -0 "$process_id" 2>/dev/null; then /bin/kill -TERM "$process_id" 2>/dev/null || true; fi
) &
watchdog_id=$!

set +e
wait "$process_id"
process_result=$?
set -e
/bin/kill "$watchdog_id" 2>/dev/null || true
wait "$watchdog_id" 2>/dev/null || true
process_id=""
watchdog_id=""

[[ "$process_result" == 0 ]] || {
  print -u2 "Interaction harness failed (exit=$process_result). Log: $log_path"
  /usr/bin/tail -80 "$log_path" >&2
  exit 1
}
[[ -s "$output_directory" ]] || { print -u2 "Harness did not create report: $output_directory"; exit 1; }

# A clean tree can make this a reproducible candidate measurement, but report
# validation alone cannot satisfy the numeric, painted-state, and AX gates.
# Keep the tree decision private to this process (never print git status paths).
tree_state="clean"
tree_status="$(/usr/bin/git -C "$project_root" status --porcelain --untracked-files=all 2>/dev/null || print '?')"
[[ -z "$tree_status" ]] || tree_state="dirty"
if [[ "$tree_state" == dirty ]]; then
  print "evidence=exploratory release_gate=false"
  validator_args=(--exploratory)
else
  print "evidence=release-candidate release_gate=false"
  validator_args=()
fi
validation_log="${output_directory:r}.validator.log"
if ! "$script_root/validate-interaction-performance-report.sh" "$output_directory" \
    --fixture "$fixture_name" --samples "$sample_count" --width "$width" --height "$height" "${validator_args[@]}" \
    >"$validation_log" 2>&1; then
  print -u2 "Interaction report validation failed; JSON and logs retained: report=$output_directory log=$log_path validator_log=$validation_log"
  exit 1
fi
print -r -- "$(/bin/cat "$validation_log")"

print "report=$output_directory"
print "log=$log_path"
print "samples=$sample_count viewport=${width}x${height}"
print "fixture=$fixture_name"
print "timeout_seconds=$timeout_seconds"
print "measurement=input-to-paint-not-claimed app-markers-and-layout-settlement-only"

#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
scenario=""
sample_count=20
output_directory=""
fixture_root="/tmp/codex-director-startup-perf"
lock_file="$fixture_root/.runner.lock"
fixture_id="$(/usr/bin/uuidgen)"
owns_lock=0
build_root=""
scenario_root=""
staging=""
process_id=""
watchdog_id=""

usage() {
  print -u2 "Usage: $0 --scenario cachedIndexed|uncachedIndexed|uncachedNoIndex [--samples 1...50] [--output PATH]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --scenario)
      (( $# >= 2 )) || usage
      scenario="$2"
      shift 2
      ;;
    --samples)
      (( $# >= 2 )) || usage
      sample_count="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || usage
      output_directory="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$scenario" in
  cachedIndexed|uncachedIndexed|uncachedNoIndex) ;;
  *) usage ;;
esac
[[ "$sample_count" =~ '^[1-9][0-9]*$' && "$sample_count" -le 50 ]] || usage
if [[ -z "$output_directory" ]]; then
  output_directory="/tmp/codex-director-startup-report-$fixture_id"
fi
[[ ! -e "$output_directory" ]] || { print -u2 "Performance report output already exists: $output_directory"; exit 1; }
source_commit="$(git -C "$project_root" rev-parse HEAD)"
source_tree_state=clean
if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=all)" ]]; then
  source_tree_state=dirty
fi
if (( sample_count >= 20 )) && [[ "$source_tree_state" != clean ]]; then
  print -u2 "A release performance run requires a clean source tree"
  exit 1
fi

cleanup() {
  if [[ -n "$watchdog_id" ]] && /bin/kill -0 "$watchdog_id" 2>/dev/null; then /bin/kill "$watchdog_id" 2>/dev/null || true; fi
  if [[ -n "$process_id" ]] && /bin/kill -0 "$process_id" 2>/dev/null; then /bin/kill -TERM "$process_id" 2>/dev/null || true; fi
  if [[ -n "$staging" && "${staging:t}" == .codex-director-startup-report.* && -d "$staging" && ! -L "$staging" ]]; then
    /bin/rm -rf "$staging"
  fi
  current_manifest="$fixture_root/current-manifest.json"
  if [[ -n "$scenario_root" && "$scenario_root" == "$fixture_root/$fixture_id" && -d "$scenario_root" && ! -L "$scenario_root" ]]; then
    if [[ -f "$current_manifest" && ! -L "$current_manifest" ]] && rg -Fq -- "$fixture_id" "$current_manifest"; then
      /bin/rm -f "$current_manifest"
    fi
    /bin/rm -rf "$scenario_root"
  fi
  if (( owns_lock == 1 )); then /bin/rm -f "$lock_file"; fi
  if [[ -n "$build_root" && "$build_root" == /tmp/codex-director-startup-perf-build.* && -d "$build_root" && ! -L "$build_root" ]]; then
    /bin/rm -rf "$build_root"
  fi
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$fixture_root"
[[ -d "$fixture_root" && ! -L "$fixture_root" ]] || { print -u2 "Unsafe synthetic fixture root"; exit 1; }
/bin/chmod 700 "$fixture_root"
if ! /usr/bin/shlock -f "$lock_file" -p $$; then
  print -u2 "Another startup performance run owns the synthetic fixture root"
  exit 1
fi
owns_lock=1

build_output="$($script_dir/build-startup-performance-harness.sh)"
print -r -- "$build_output" | rg '^(stage|build_root|app_path)='
app_path="$(print -r -- "$build_output" | sed -n 's/^app_path=//p' | tail -1)"
build_root="$(print -r -- "$build_output" | sed -n 's/^build_root=//p' | tail -1)"
executable="$app_path/Contents/MacOS/Codex Director Startup Performance Harness"
[[ -d "$app_path" && -x "$executable" ]] || { print -u2 "Harness build did not produce an executable app"; exit 1; }
[[ "$build_root" == /tmp/codex-director-startup-perf-build.* && -d "$build_root" && ! -L "$build_root" ]] || {
  print -u2 "Harness returned an unsafe build root"
  exit 1
}

scenario_root="$fixture_root/$fixture_id"
"$script_dir/prepare-startup-perf-fixture.sh" "$scenario" "$fixture_id"
"$script_dir/prepare-startup-perf-fixture.sh" --preflight "$scenario" "$fixture_id"

metrics_directory="$scenario_root/metrics"
cache_path="$scenario_root/presentation.json"
[[ "$scenario_root" == "$fixture_root/$fixture_id" && -d "$scenario_root" && ! -L "$scenario_root" ]] || {
  print -u2 "Unsafe scenario root"
  exit 1
}

for (( sample = 1; sample <= sample_count; sample += 1 )); do
  if [[ "$scenario" != cachedIndexed ]]; then
    [[ ! -L "$cache_path" ]] || { print -u2 "Unsafe synthetic cache path"; exit 1; }
    /bin/rm -f "$cache_path"
  fi
  before_count="$(find "$metrics_directory" -maxdepth 1 -type f -name 'startup-metrics-*.json' | wc -l | tr -d ' ')"

  CODEX_DIRECTOR_PERF_AUTO_QUIT=1 "$executable" > /dev/null 2>&1 &
  process_id=$!
  (
    /bin/sleep 30
    if /bin/kill -0 "$process_id" 2>/dev/null; then /bin/kill -TERM "$process_id" 2>/dev/null || true; fi
  ) &
  watchdog_id=$!
  set +e
  wait "$process_id"
  process_status=$?
  set -e
  /bin/kill "$watchdog_id" 2>/dev/null || true
  wait "$watchdog_id" 2>/dev/null || true
  process_id=""
  watchdog_id=""
  [[ "$process_status" == 0 ]] || { print -u2 "Harness sample $sample failed or timed out"; exit 1; }

  after_count="$(find "$metrics_directory" -maxdepth 1 -type f -name 'startup-metrics-*.json' | wc -l | tr -d ' ')"
  [[ "$after_count" == $(( before_count + 1 )) ]] || {
    print -u2 "Harness sample $sample did not produce exactly one metrics file"
    exit 1
  }
  print "stage=startup_sample_complete scenario=$scenario sample=$sample total=$sample_count"
done

output_parent="${output_directory:h}"
/bin/mkdir -p "$output_parent"
staging="$(mktemp -d "$output_parent/.codex-director-startup-report.XXXXXX")"
summary="$staging/startup-summary.txt"
/usr/bin/swift "$project_root/Tools/StartupPerformanceFixtureTool/summarize-startup-metrics.swift" \
  --scenario "$scenario" "$metrics_directory" > "$summary"

verification_arguments=(--scenario "$scenario" --samples "$sample_count" --report "$summary")
if (( sample_count < 20 )); then verification_arguments+=(--smoke); fi
"$script_dir/verify-startup-performance-report.sh" "${verification_arguments[@]}" | tee "$staging/verification.txt"

hardware_model="$(/usr/sbin/sysctl -n hw.model)"
memory_bytes="$(/usr/sbin/sysctl -n hw.memsize)"
cat > "$staging/environment.txt" <<EOF
schema_version=1
scenario=$scenario
samples=$sample_count
measurement_mode=release_harness_synthetic
source_commit=$source_commit
source_tree_state=$source_tree_state
hardware_model=$hardware_model
memory_bytes=$memory_bytes
macos_version=$(/usr/bin/sw_vers -productVersion)
xcode_version=$(/usr/bin/xcodebuild -version | awk 'NR == 1 { print $2 }')
swift_version=$(/usr/bin/swift --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+[.][0-9]+([.][0-9]+)?).*/\1/p' | head -1)
automated_input_measurement=not_run
main_thread_stall_trace=not_run
pixel_presentation_measurement=not_claimed
EOF

/bin/mv "$staging" "$output_directory"
staging=""
print "Created startup performance report: $output_directory"

#!/bin/zsh
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$source_root/scripts/run-startup-performance.sh"
verifier="$source_root/scripts/verify-startup-performance-report.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-performance-contract.XXXXXX")"
interaction_fixture_root="/tmp/codex-director-interaction-perf"
interaction_report="$interaction_fixture_root/contract-${$}.json"
bad_interaction_report="$interaction_fixture_root/contract-${$}-bad.json"
representative_report="$interaction_fixture_root/contract-${$}-representative.json"
interaction_representative_report="$interaction_fixture_root/contract-${$}-interaction-representative.json"
trap 'rm -rf "$test_root"; rm -f "$interaction_report" "$bad_interaction_report" "$representative_report" "$interaction_representative_report"' EXIT INT TERM

pass_count=0

expect_pass() {
  local name="$1"
  shift
  if ! output="$("$@" 2>&1)"; then
    print -u2 "FAIL: $name should pass"
    print -u2 "$output"
    exit 1
  fi
  (( pass_count += 1 ))
}

expect_failure() {
  local name="$1"
  shift
  if output="$("$@" 2>&1)"; then
    print -u2 "FAIL: $name should fail"
    exit 1
  fi
  (( pass_count += 1 ))
}

[[ -x "$runner" && -x "$verifier" ]] || {
  print -u2 "FAIL: performance runner and verifier must be executable"
  exit 1
}

make_report() {
  local output_file="$1"
  local scenario="$2"
  local samples="$3"
  local p95="$4"
  local cache_hits="$5"
  local zero_gate="${6:-not_applicable}"
  cat > "$output_file" <<EOF
scenario=$scenario
valid_samples=$samples
invalid_metric_files=0
duplicate_process_samples=0
failure_samples=0
unsupported_samples=0
marker.root_appeared.present_samples=$samples missing_samples=0 median_ms=100.000 p95_ms=120.000 max_ms=130.000
marker.cache_visible.present_samples=$cache_hits missing_samples=$(( samples - cache_hits )) median_ms=300.000 p95_ms=$p95 max_ms=$p95
marker.startup_ready.present_samples=$samples missing_samples=0 median_ms=500.000 p95_ms=$p95 max_ms=$p95
process_to_root.present_samples=$samples missing_bridge=0 missing_marker=0 median_ms=120.000 p95_ms=140.000 max_ms=150.000
process_to_cache.present_samples=$cache_hits missing_bridge=0 missing_marker=$(( samples - cache_hits )) median_ms=320.000 p95_ms=$p95 max_ms=$p95
process_to_startup_ready.present_samples=$samples missing_bridge=0 missing_marker=0 median_ms=520.000 p95_ms=$p95 max_ms=$p95
cache_hits=$cache_hits cache_misses_or_unobserved=$(( samples - cache_hits ))
cached_zero_aggregation_gate=$zero_gate observer_ready=$samples unverifiable_samples=0 violating_samples=0
EOF
}

cached="$test_root/cached.txt"
make_report "$cached" cachedIndexed 20 650.000 20 all_given_valid_samples
expect_pass "cached threshold" "$verifier" --scenario cachedIndexed --samples 20 --report "$cached"

uncached="$test_root/uncached.txt"
make_report "$uncached" uncachedIndexed 20 1700.000 0
expect_pass "uncached indexed threshold" "$verifier" --scenario uncachedIndexed --samples 20 --report "$uncached"

no_index="$test_root/no-index.txt"
make_report "$no_index" uncachedNoIndex 20 1700.000 0
expect_pass "uncached no-index threshold" "$verifier" --scenario uncachedNoIndex --samples 20 --report "$no_index"

slow="$test_root/slow.txt"
make_report "$slow" cachedIndexed 20 701.000 20 all_given_valid_samples
expect_failure "cached p95 over threshold" "$verifier" --scenario cachedIndexed --samples 20 --report "$slow"

short="$test_root/short.txt"
make_report "$short" cachedIndexed 19 650.000 19 all_given_valid_samples
expect_failure "missing sample" "$verifier" --scenario cachedIndexed --samples 20 --report "$short"

failed="$test_root/failed.txt"
make_report "$failed" uncachedIndexed 20 1700.000 0
sed -i '' 's/failure_samples=0/failure_samples=1/' "$failed"
expect_failure "failed launch" "$verifier" --scenario uncachedIndexed --samples 20 --report "$failed"

violating="$test_root/violating.txt"
make_report "$violating" cachedIndexed 20 650.000 20 all_given_valid_samples
sed -i '' 's/violating_samples=0/violating_samples=1/' "$violating"
expect_failure "cached aggregation regression" "$verifier" --scenario cachedIndexed --samples 20 --report "$violating"

oversized="$test_root/oversized.txt"
make_report "$oversized" uncachedNoIndex 20 1700.000 0
/bin/dd if=/dev/zero bs=1048576 count=1 >> "$oversized" 2>/dev/null
expect_failure "oversized aggregate report" "$verifier" --scenario uncachedNoIndex --samples 20 --report "$oversized"

rg -q 'CODEX_DIRECTOR_PERF_AUTO_QUIT=1' "$runner" || { print -u2 "FAIL: runner does not require harness auto-quit"; exit 1; }
rg -q 'prepare-startup-perf-fixture\.sh.*--preflight' "$runner" || { print -u2 "FAIL: runner omits fixture preflight"; exit 1; }
rg -q 'summarize-startup-metrics\.swift' "$runner" || { print -u2 "FAIL: runner omits aggregate summarizer"; exit 1; }
rg -q 'source_tree_state=dirty' "$runner" || { print -u2 "FAIL: runner does not disclose dirty source state"; exit 1; }
rg -q 'sample_count >= 20' "$runner" || { print -u2 "FAIL: runner does not protect release evidence from dirty trees"; exit 1; }
if rg -q '\$HOME|\$CODEX_HOME|NSHomeDirectory|Application Support' "$runner" "$verifier"; then
  print -u2 "FAIL: performance scripts may not derive production data paths"
  exit 1
fi
(( pass_count += 6 ))

interaction_runner="$source_root/scripts/run-interaction-performance.sh"
interaction_validator="$source_root/scripts/validate-interaction-performance-report.sh"
interaction_dual_runner="$source_root/scripts/run-interaction-performance-both-viewports.sh"
[[ -x "$interaction_runner" && -x "$interaction_validator" && -x "$interaction_dual_runner" ]] || {
  print -u2 "FAIL: interaction performance harness scripts must be executable"
  exit 1
}
zsh -n "$interaction_runner" "$interaction_validator"
rg -q 'CODEX_DIRECTOR_INTERACTION_PERFORMANCE_RUNTIME=1' "$interaction_runner" || { print -u2 "FAIL: interaction runner omits runtime gate"; exit 1; }
rg -q -- '--reuse-build' "$interaction_runner" || { print -u2 "FAIL: interaction runner cannot reuse one frozen build"; exit 1; }
rg -q 'run-interaction-performance.sh' "$interaction_dual_runner" || { print -u2 "FAIL: dual viewport runner does not use the checked runner"; exit 1; }
rg -q -- '--width 720 --height 480' "$interaction_dual_runner" || { print -u2 "FAIL: dual viewport runner omits 720x480"; exit 1; }
rg -q -- '--width 1280 --height 800' "$interaction_dual_runner" || { print -u2 "FAIL: dual viewport runner omits 1280x800"; exit 1; }
rg -q 'timeout_seconds' "$interaction_runner" || { print -u2 "FAIL: interaction runner has no bounded timeout"; exit 1; }
rg -q 'stageEvents' "$interaction_validator" || { print -u2 "FAIL: interaction report validator omits per-event contract"; exit 1; }
rg -q -- '--samples N --width N --height N' "$interaction_validator" || { print -u2 "FAIL: interaction validator does not require expected sample and viewport inputs"; exit 1; }
rg -q -- '--fixture interactionStress|representative' "$interaction_validator" || { print -u2 "FAIL: interaction validator does not require the expected fixture"; exit 1; }
rg -q 'interactionRepresentative' "$interaction_validator" "$interaction_runner" "$interaction_dual_runner" || { print -u2 "FAIL: interaction representative fixture is not wired through the scripts"; exit 1; }
rg -q 'CODEX_DIRECTOR_INTERACTION_FIXTURE' "$interaction_runner" || { print -u2 "FAIL: interaction runner does not pass the fixture selection"; exit 1; }
rg -q -- '--fixture' "$interaction_dual_runner" || { print -u2 "FAIL: dual viewport runner does not pass the fixture selection"; exit 1; }
rg -q 'first-entry|warm-repeat' "$interaction_validator" || { print -u2 "FAIL: interaction validator does not enforce cold/warm sample paths"; exit 1; }
rg -q 'release_gate=false' "$interaction_runner" || { print -u2 "FAIL: dirty interaction runs are not marked exploratory"; exit 1; }
if rg -q '\$HOME|\$CODEX_HOME|NSHomeDirectory|Application Support|/Users/|/home/' "$interaction_runner"; then
  print -u2 "FAIL: interaction harness may derive or expose production paths"
  exit 1
fi
(( pass_count += 16 ))

/bin/mkdir -p "$interaction_fixture_root"
/usr/bin/python3 - "$interaction_report" <<'PY'
import json
import sys

names = [
    "sidebar-home",
    "sidebar-custom-agents", "sidebar-custom-skills",
    "sidebar-installed-skills", "sidebar-installed-plugins",
    "sidebar-folder",
    "folder-entry", "folder-tab", "folder-tab", "folder-tab", "folder-sort",
    "sidebar-settings",
]

def sample(index, path):
    events = []
    for i, name in enumerate(names):
        library = name in {"sidebar-custom-agents", "sidebar-custom-skills", "sidebar-installed-skills", "sidebar-installed-plugins"}
        phases = {"selectionMutation": 0.1, "initialLayoutSettlement": 0.7}
        if library:
            phases.update({"libraryReloadAwait": 0.1, "finalLayoutSettlement": 0.1})
        events.append({"sequence": i + 1, "name": name, "durationMilliseconds": 1.0, "queryCounts": {},
                       "phaseDurationsMilliseconds": phases, "phaseCounts": {"libraryReloadCompleted": 1, "libraryReloadLoaded": 1} if library else {}})
    return {
        "index": index,
        "path": path,
        "width": 720,
        "height": 480,
        "durationsMilliseconds": {name: 1.0 for name in set(names)},
        "stageEvents": events,
        "queryCounts": {},
        "queryCountsByStage": {},
        "mainRunLoopLongestTurnMilliseconds": 1.0,
    }

report = {
    "schemaVersion": 3,
    "fixture": "interactionStress",
    "measurementMode": "release-optimized-synthetic-root-model-and-layout-markers",
    "width": 720,
    "height": 480,
    "samples": [sample(1, "first-entry"), sample(2, "warm-repeat")],
    "signpostCategory": "interaction-performance",
    "inputToPaintMeasurement": "not_claimed; AX and pixel presentation are outside this app marker chain",
    "runtimeEnvironment": {"operatingSystem": "Version 26", "architecture": "arm64", "syntheticData": True},
    "buildIdentity": {
        "bundleIdentifier": "com.peiweitang.CodexDirector.InteractionPerformance",
        "appVersion": "1.4.1",
        "configuration": "Release",
        "optimization": "release",
        "compilationCondition": "DIRECTOR_INTERACTION_PERFORMANCE",
        "signature": "ad-hoc",
    },
    "inventory": {
        "agents": 1000,
        "skills": 1000,
        "folders": 1,
        "global": {"agents": 1000, "skills": 1000},
        "project": {"agents": 0, "skills": 0},
        "custom": {"agents": 0, "skills": 0},
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_pass "complete interaction report" "$interaction_validator" "$interaction_report" --fixture interactionStress --samples 2 --width 720 --height 480 --exploratory
expect_failure "interaction viewport mismatch" "$interaction_validator" "$interaction_report" --fixture interactionStress --samples 2 --width 1280 --height 800 --exploratory
cp "$interaction_report" "$representative_report"
/usr/bin/python3 - "$representative_report" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
report["fixture"] = "representative"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_pass "representative interaction report" "$interaction_validator" "$representative_report" --fixture representative --samples 2 --width 720 --height 480 --exploratory
expect_failure "fixture mismatch" "$interaction_validator" "$representative_report" --fixture interactionStress --samples 2 --width 720 --height 480 --exploratory
interaction_representative_report="$interaction_fixture_root/contract-${$}-interaction-representative.json"
cp "$interaction_report" "$interaction_representative_report"
/usr/bin/python3 - "$interaction_representative_report" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
report["fixture"] = "interactionRepresentative"
report["inventory"] = {
    "agents": 66,
    "skills": 217,
    "folders": 3,
    "global": {"agents": 47, "skills": 44},
    "project": {"agents": 19, "skills": 173},
    "custom": {"agents": 0, "skills": 0},
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_pass "interaction representative scale" "$interaction_validator" "$interaction_representative_report" --fixture interactionRepresentative --samples 2 --width 720 --height 480 --exploratory
expect_failure "interaction representative scale mismatch" "$interaction_validator" "$representative_report" --fixture interactionRepresentative --samples 2 --width 720 --height 480 --exploratory
cp "$interaction_report" "$bad_interaction_report"
/usr/bin/python3 - "$bad_interaction_report" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
report["samples"][1]["path"] = "first-entry"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_failure "interaction warm path missing" "$interaction_validator" "$bad_interaction_report" --fixture interactionStress --samples 2 --width 720 --height 480 --exploratory
cp "$interaction_report" "$bad_interaction_report"
/usr/bin/python3 - "$bad_interaction_report" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
report["samples"][0]["stageEvents"][1]["name"] = "sidebar-installed-plugins"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_failure "interaction library order changed" "$interaction_validator" "$bad_interaction_report" --fixture interactionStress --samples 2 --width 720 --height 480 --exploratory
cp "$interaction_report" "$bad_interaction_report"
/usr/bin/python3 - "$bad_interaction_report" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
report["samples"][0]["stageEvents"][1].pop("phaseDurationsMilliseconds")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_failure "interaction phase timing missing" "$interaction_validator" "$bad_interaction_report" --fixture interactionStress --samples 2 --width 720 --height 480 --exploratory
(( pass_count += 7 ))

print "Performance contract tests passed: $pass_count"

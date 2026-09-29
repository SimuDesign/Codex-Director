#!/bin/zsh
set -euo pipefail

report_path=""
expected_samples=""
expected_width=""
expected_height=""
expected_fixture=""
exploratory=false
while (( $# > 0 )); do
  case "$1" in
    --samples) (( $# >= 2 )) || exit 2; expected_samples="$2"; shift 2 ;;
    --width) (( $# >= 2 )) || exit 2; expected_width="$2"; shift 2 ;;
    --height) (( $# >= 2 )) || exit 2; expected_height="$2"; shift 2 ;;
    --fixture) (( $# >= 2 )) || exit 2; expected_fixture="$2"; shift 2 ;;
    --exploratory) exploratory=true; shift ;;
    --) shift; (( $# == 1 )) || exit 2; report_path="$1"; shift ;;
    /*.json) [[ -z "$report_path" ]] || exit 2; report_path="$1"; shift ;;
    *) print -u2 "Usage: $0 /tmp/codex-director-interaction-perf/<report>.json --fixture interactionStress|representative|interactionRepresentative --samples N --width N --height N [--exploratory]"; exit 2 ;;
  esac
done

[[ "$expected_samples" =~ '^[1-9][0-9]*$' && "$expected_samples" -le 50 ]] || { print -u2 'error=interaction_expected_samples_invalid'; exit 2; }
[[ "$expected_width" == 720 || "$expected_width" == 1280 ]] || { print -u2 'error=interaction_expected_width_invalid'; exit 2; }
[[ "$expected_height" == 480 || "$expected_height" == 800 ]] || { print -u2 'error=interaction_expected_height_invalid'; exit 2; }
[[ "$expected_fixture" == interactionStress || "$expected_fixture" == representative || "$expected_fixture" == interactionRepresentative ]] || { print -u2 'error=interaction_expected_fixture_invalid'; exit 2; }
[[ "$report_path" == /tmp/codex-director-interaction-perf/*.json && -f "$report_path" && ! -L "$report_path" ]] || {
  print -u2 'error=interaction_report_path_invalid'
  exit 2
}

# Keep this validator independent of the app target. It is intentionally
# strict about the public, privacy-safe report contract but never prints
# report values (which keeps failures free of fixture contents and paths).
/usr/bin/python3 - "$report_path" "$expected_samples" "$expected_width" "$expected_height" "$expected_fixture" "$exploratory" <<'PY'
import json
import math
import os
import sys

path = sys.argv[1]
expected_samples = int(sys.argv[2])
expected_width = int(sys.argv[3])
expected_height = int(sys.argv[4])
expected_fixture = sys.argv[5]
exploratory = sys.argv[6] == "true"
try:
    with open(path, "r", encoding="utf-8") as handle:
        report = json.load(handle)
except Exception:
    print("error=interaction_report_json_invalid", file=sys.stderr)
    raise SystemExit(1)

def require(condition, code):
    if not condition:
        print(f"error={code}", file=sys.stderr)
        raise SystemExit(1)

require(report.get("schemaVersion") == 3, "interaction_report_schema_invalid")
require(report.get("fixture") == expected_fixture, "interaction_report_fixture_invalid")
require(report.get("measurementMode") == "release-optimized-synthetic-root-model-and-layout-markers", "interaction_report_mode_invalid")
require(report.get("inputToPaintMeasurement", "").startswith("not_claimed;"), "interaction_report_input_to_paint_claim_invalid")
require(report.get("width") == expected_width and report.get("height") == expected_height, "interaction_report_viewport_invalid")

runtime = report.get("runtimeEnvironment")
build = report.get("buildIdentity")
require(isinstance(runtime, dict) and runtime.get("syntheticData") is True, "interaction_report_runtime_invalid")
require(runtime.get("architecture") in {"arm64", "x86_64", "unknown"}, "interaction_report_architecture_invalid")
require(isinstance(runtime.get("operatingSystem"), str) and len(runtime["operatingSystem"]) <= 128, "interaction_report_os_invalid")
require(isinstance(build, dict), "interaction_report_build_invalid")
require(build.get("bundleIdentifier") == "com.peiweitang.CodexDirector.InteractionPerformance", "interaction_report_bundle_invalid")
require(build.get("configuration") == "Release", "interaction_report_configuration_invalid")
require(build.get("compilationCondition") == "DIRECTOR_INTERACTION_PERFORMANCE", "interaction_report_compile_condition_invalid")
require(build.get("signature") == "ad-hoc", "interaction_report_signature_invalid")

inventory = report.get("inventory")
require(isinstance(inventory, dict), "interaction_report_inventory_missing")
def kind_counts(value, code):
    require(isinstance(value, dict), code)
    agents = value.get("agents")
    skills = value.get("skills")
    require(isinstance(agents, int) and agents >= 0, code)
    require(isinstance(skills, int) and skills >= 0, code)
    return agents, skills

total_agents, total_skills = kind_counts(inventory, "interaction_report_inventory_invalid")
global_agents, global_skills = kind_counts(inventory.get("global"), "interaction_report_global_inventory_invalid")
project_agents, project_skills = kind_counts(inventory.get("project"), "interaction_report_project_inventory_invalid")
custom_agents, custom_skills = kind_counts(inventory.get("custom"), "interaction_report_custom_inventory_invalid")
require(isinstance(inventory.get("folders"), int) and inventory["folders"] >= 0, "interaction_report_folder_count_invalid")
if expected_fixture == "interactionRepresentative":
    require((total_agents, total_skills, inventory["folders"]) == (66, 217, 3), "interaction_representative_total_scale_invalid")
    require((global_agents, global_skills) == (47, 44), "interaction_representative_global_scale_invalid")
    require((project_agents, project_skills) == (19, 173), "interaction_representative_project_scale_invalid")
    require((custom_agents, custom_skills) == (0, 0), "interaction_representative_custom_scale_invalid")

samples = report.get("samples")
require(isinstance(samples, list) and len(samples) == expected_samples, "interaction_report_sample_count_invalid")
require(samples[0].get("path") == "first-entry", "interaction_report_first_entry_missing")
if expected_samples > 1:
    require(all(sample.get("path") == "warm-repeat" for sample in samples[1:]), "interaction_report_warm_repeat_missing")
for sample in samples:
    require(isinstance(sample, dict), "interaction_report_sample_invalid")
    require(sample.get("width") == expected_width and sample.get("height") == expected_height, "interaction_report_sample_viewport_invalid")
    events = sample.get("stageEvents")
    require(isinstance(events, list) and len(events) > 0, "interaction_report_stage_events_missing")
    sequences = []
    names = []
    for event in events:
        require(isinstance(event, dict), "interaction_report_stage_event_invalid")
        require(isinstance(event.get("name"), str) and event["name"] in {
            "sidebar-home", "sidebar-custom-agents", "sidebar-custom-skills",
            "sidebar-installed-skills", "sidebar-installed-plugins", "sidebar-folder", "folder-entry",
            "folder-tab", "folder-sort", "detail", "folder-member-add",
            "folder-member-remove", "sidebar-settings"
        }, "interaction_report_stage_name_invalid")
        require(isinstance(event.get("sequence"), int) and event["sequence"] > 0, "interaction_report_stage_sequence_invalid")
        require(isinstance(event.get("durationMilliseconds"), (int, float)) and event["durationMilliseconds"] >= 0, "interaction_report_stage_duration_invalid")
        require(isinstance(event.get("queryCounts"), dict), "interaction_report_stage_queries_invalid")
        phases = event.get("phaseDurationsMilliseconds")
        counts = event.get("phaseCounts")
        require(isinstance(phases, dict) and {"selectionMutation", "initialLayoutSettlement"}.issubset(phases), "interaction_report_stage_phases_missing")
        require(set(phases).issubset({"selectionMutation", "initialLayoutSettlement", "libraryReloadAwait", "finalLayoutSettlement", "identityRead", "rowProjectionBuild"}), "interaction_report_stage_phase_name_invalid")
        require(all(isinstance(value, (int, float)) and math.isfinite(value) and value >= 0 for value in phases.values()), "interaction_report_stage_phase_duration_invalid")
        require(isinstance(counts, dict) and set(counts).issubset({"identityRead", "rowProjectionBuild", "rowViewBuild", "libraryReloadFailure", "libraryReloadCompleted", "libraryReloadLoaded"}), "interaction_report_stage_phase_counts_invalid")
        require(all(isinstance(value, int) and value >= 0 for value in counts.values()), "interaction_report_stage_phase_counts_invalid")
        if event["name"] in {"sidebar-custom-agents", "sidebar-custom-skills", "sidebar-installed-skills", "sidebar-installed-plugins"}:
            require(counts.get("libraryReloadCompleted") == 1 and counts.get("libraryReloadLoaded") == 1 and "libraryReloadAwait" in phases and "finalLayoutSettlement" in phases, "interaction_report_library_reload_incomplete")
        sequences.append(event["sequence"])
        names.append(event["name"])
    require(sequences == list(range(1, len(events) + 1)), "interaction_report_stage_order_invalid")

    cursor = 0
    def take(expected):
        global cursor
        require(cursor < len(names) and names[cursor] == expected, "interaction_report_required_stage_missing")
        cursor += 1

    take("sidebar-home")
    for library_stage in (
        "sidebar-custom-agents", "sidebar-custom-skills",
        "sidebar-installed-skills", "sidebar-installed-plugins"
    ):
        take(library_stage)
    take("sidebar-folder")
    folder_count = 0
    while cursor < len(names) and names[cursor] == "folder-entry":
        take("folder-entry")
        for _ in range(3):
            take("folder-tab")
        take("folder-sort")
        if cursor < len(names) and names[cursor] == "detail":
            take("detail")
        folder_count += 1
    require(folder_count > 0, "interaction_report_folder_stage_missing")
    if cursor < len(names) and names[cursor] == "folder-member-add":
        take("folder-member-add")
        take("folder-member-remove")
    take("sidebar-settings")
    require(cursor == len(names), "interaction_report_unexpected_stage")

# The report is explicitly a diagnostic artifact. Reject common accidental
# leakage even though the producer never emits these fields.
serialized = json.dumps(report, ensure_ascii=False)
for forbidden in ("/Users/", "/home/", "password", "cookie", "token", "prompt", "sessionID"):
    require(forbidden.lower() not in serialized.lower(), "interaction_report_privacy_field_detected")

# Structural validity alone cannot satisfy the numeric or painted-frame gates.
# Even a clean candidate remains pending independent performance acceptance.
print(f"interaction_report=valid evidence={'exploratory' if exploratory else 'release-candidate'} release_gate=false")
PY

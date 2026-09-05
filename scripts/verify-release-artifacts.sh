#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
project_file="$project_root/project.yml"
artifact_directory=""
expected_source_commit=""
expected_source_tag=""

usage() {
  print -u2 "Usage: $0 --directory PATH [--project FILE] [--source-commit SHA] [--source-tag TAG]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --directory)
      (( $# >= 2 )) || usage
      artifact_directory="$2"
      shift 2
      ;;
    --project)
      (( $# >= 2 )) || usage
      project_file="$2"
      shift 2
      ;;
    --source-commit)
      (( $# >= 2 )) || usage
      expected_source_commit="$2"
      shift 2
      ;;
    --source-tag)
      (( $# >= 2 )) || usage
      expected_source_tag="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$artifact_directory" && -d "$artifact_directory" && -f "$project_file" ]] || usage
[[ -z "$expected_source_commit" || "$expected_source_commit" =~ '^[0-9a-f]{40}$' ]] || usage
if [[ -n "$expected_source_tag" ]]; then
  "$script_dir/validate-release-tag.sh" --project "$project_file" "$expected_source_tag" >/dev/null
fi

version_reader="$script_dir/read-project-version.sh"
marketing_version="$($version_reader --project "$project_file" --marketing)"
build_version="$($version_reader --project "$project_file" --build)"
bundle_id="$($version_reader --project "$project_file" --bundle-id)"
minimum_system="$($version_reader --project "$project_file" --minimum-macos)"
minimum_major="${minimum_system%%.*}"
archive_name="Codex-Director-${marketing_version}-macOS-${minimum_major}-unnotarized.zip"
archive_path="$artifact_directory/$archive_name"
checksums_path="$artifact_directory/SHA256SUMS.txt"
build_info_path="$artifact_directory/BUILD-INFO.json"
dependencies_path="$artifact_directory/DEPENDENCIES.json"

for artifact_path in "$archive_path" "$checksums_path" "$build_info_path" "$dependencies_path"; do
  [[ -f "$artifact_path" && ! -L "$artifact_path" && -s "$artifact_path" ]] || { print -u2 "Missing or unsafe release artifact: $artifact_path"; exit 1; }
done

unexpected_entry="$(find "$artifact_directory" -mindepth 1 -maxdepth 1 ! -name "$archive_name" ! -name SHA256SUMS.txt ! -name BUILD-INFO.json ! -name DEPENDENCIES.json -print -quit)"
[[ -z "$unexpected_entry" ]] || { print -u2 "Unexpected release artifact: $unexpected_entry"; exit 1; }

checksum_line_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$checksums_path")"
[[ "$checksum_line_count" == "3" ]] || { print -u2 "SHA256SUMS.txt must contain exactly three artifacts"; exit 1; }
checksum_names="$(awk 'NF { print $2 }' "$checksums_path" | sed 's/^\*//' | LC_ALL=C sort)"
expected_checksum_names="$(printf '%s\n' BUILD-INFO.json "$archive_name" DEPENDENCIES.json | LC_ALL=C sort)"
[[ "$checksum_names" == "$expected_checksum_names" ]] || { print -u2 "SHA256SUMS.txt does not identify the complete release artifact set"; exit 1; }
(cd "$artifact_directory" && shasum -a 256 -c SHA256SUMS.txt)

/usr/bin/plutil -convert binary1 -o - "$build_info_path" >/dev/null
/usr/bin/plutil -convert binary1 -o - "$dependencies_path" >/dev/null
read_json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

[[ "$(read_json_value schemaVersion "$build_info_path")" == "1" ]] || { print -u2 "Unsupported BUILD-INFO schema"; exit 1; }
[[ "$(read_json_value marketingVersion "$build_info_path")" == "$marketing_version" ]] || { print -u2 "BUILD-INFO marketing version mismatch"; exit 1; }
[[ "$(read_json_value buildVersion "$build_info_path")" == "$build_version" ]] || { print -u2 "BUILD-INFO build version mismatch"; exit 1; }
[[ "$(read_json_value bundleIdentifier "$build_info_path")" == "$bundle_id" ]] || { print -u2 "BUILD-INFO bundle id mismatch"; exit 1; }
[[ "$(read_json_value minimumMacOS "$build_info_path")" == "$minimum_system" ]] || { print -u2 "BUILD-INFO minimum macOS mismatch"; exit 1; }
[[ "$(read_json_value archiveName "$build_info_path")" == "$archive_name" ]] || { print -u2 "BUILD-INFO archive name mismatch"; exit 1; }
[[ "$(read_json_value signing.type "$build_info_path")" == "ad-hoc" ]] || { print -u2 "BUILD-INFO signing status is incorrect"; exit 1; }
[[ "$(read_json_value signing.appleDeveloperID "$build_info_path")" == "false" ]] || { print -u2 "BUILD-INFO must not claim Developer ID signing"; exit 1; }
[[ "$(read_json_value notarizedByApple "$build_info_path")" == "false" ]] || { print -u2 "BUILD-INFO must not claim Apple notarization"; exit 1; }
[[ "$(read_json_value architectures.0 "$build_info_path")" == "arm64" ]] || { print -u2 "BUILD-INFO is missing arm64"; exit 1; }
[[ "$(read_json_value architectures.1 "$build_info_path")" == "x86_64" ]] || { print -u2 "BUILD-INFO is missing x86_64"; exit 1; }
[[ "$(read_json_value source.repository "$build_info_path")" == "https://github.com/SimuDesign/Codex-Director" ]] || { print -u2 "BUILD-INFO source repository mismatch"; exit 1; }
recorded_source_commit="$(read_json_value source.commit "$build_info_path")"
[[ "$recorded_source_commit" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "BUILD-INFO source commit is invalid"; exit 1; }
[[ "$(read_json_value buildEnvironment.macOS "$build_info_path")" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "BUILD-INFO macOS build environment is invalid"; exit 1; }
[[ "$(read_json_value buildEnvironment.xcode "$build_info_path")" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "BUILD-INFO Xcode build environment is invalid"; exit 1; }
[[ "$(read_json_value buildEnvironment.swift "$build_info_path")" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "BUILD-INFO Swift build environment is invalid"; exit 1; }
[[ "$(read_json_value buildEnvironment.sdk "$build_info_path")" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "BUILD-INFO SDK build environment is invalid"; exit 1; }

recorded_archive_hash="$(read_json_value archiveSHA256 "$build_info_path")"
actual_archive_hash="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
[[ "$recorded_archive_hash" == "$actual_archive_hash" ]] || { print -u2 "BUILD-INFO archive hash mismatch"; exit 1; }

recorded_dependency_hash="$(read_json_value packageResolvedSHA256 "$build_info_path")"
actual_dependency_hash="$(shasum -a 256 "$dependencies_path" | awk '{print $1}')"
[[ "$recorded_dependency_hash" == "$actual_dependency_hash" ]] || { print -u2 "BUILD-INFO dependency hash mismatch"; exit 1; }
cmp -s "$dependencies_path" "$project_root/Package.resolved" || { print -u2 "DEPENDENCIES.json does not match Package.resolved"; exit 1; }

if [[ -n "$expected_source_commit" ]]; then
  [[ "$recorded_source_commit" == "$expected_source_commit" ]] || { print -u2 "BUILD-INFO source commit mismatch"; exit 1; }
fi
if [[ -n "$expected_source_tag" ]]; then
  [[ "$(read_json_value source.tag "$build_info_path")" == "$expected_source_tag" ]] || { print -u2 "BUILD-INFO source tag mismatch"; exit 1; }
fi

verification_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-release-verify.XXXXXX")"
trap 'rm -rf "$verification_root"' EXIT INT TERM
archive_entries_path="$verification_root/archive-entries.txt"
zipinfo -1 "$archive_path" > "$archive_entries_path"
"$script_dir/validate-zip-entry-list.sh" "$archive_entries_path"

extract_root="$verification_root/extracted"
mkdir "$extract_root"
ditto -x -k "$archive_path" "$extract_root"
extracted_app="$extract_root/Codex Director.app"
[[ -d "$extracted_app" ]] || { print -u2 "Archive does not contain Codex Director.app at its root"; exit 1; }
unexpected_top_level="$(find "$extract_root" -mindepth 1 -maxdepth 1 ! -name 'Codex Director.app' -print -quit)"
[[ -z "$unexpected_top_level" ]] || { print -u2 "Archive contains an unexpected top-level entry: $unexpected_top_level"; exit 1; }

"$script_dir/verify-app-bundle.sh" --app "$extracted_app" --project "$project_file"
print "Verified release artifacts: $artifact_directory"

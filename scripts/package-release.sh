#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
project_file="$project_root/project.yml"
derived_data="${DERIVED_DATA_PATH:-/tmp/codex-director-xcode}"
app_path="$derived_data/Build/Products/Release/Codex Director.app"
output_directory="$project_root/dist"
source_commit="$(git -C "$project_root" rev-parse HEAD)"
source_tag=""

usage() {
  print -u2 "Usage: $0 [--app PATH] [--output PATH] [--source-commit SHA] [--source-tag TAG]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || usage
      output_directory="$2"
      shift 2
      ;;
    --source-commit)
      (( $# >= 2 )) || usage
      source_commit="$2"
      shift 2
      ;;
    --source-tag)
      (( $# >= 2 )) || usage
      source_tag="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -d "$app_path" ]] || { print -u2 "Missing Release app: $app_path"; exit 1; }
[[ "$source_commit" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "Source commit must be a full lowercase Git SHA"; exit 1; }
current_commit="$(git -C "$project_root" rev-parse HEAD)"
[[ "$source_commit" == "$current_commit" ]] || {
  print -u2 "Source commit $source_commit does not match checked-out HEAD $current_commit"
  exit 1
}
if [[ -n "$source_tag" ]]; then
  "$script_dir/validate-release-tag.sh" --project "$project_file" "$source_tag"
  tag_commit="$(git -C "$project_root" rev-parse "${source_tag}^{commit}")"
  [[ "$tag_commit" == "$source_commit" ]] || {
    print -u2 "Release tag $source_tag does not point to source commit $source_commit"
    exit 1
  }
fi

"$script_dir/verify-app-bundle.sh" --app "$app_path" --project "$project_file"

version_reader="$script_dir/read-project-version.sh"
marketing_version="$($version_reader --project "$project_file" --marketing)"
build_version="$($version_reader --project "$project_file" --build)"
bundle_id="$($version_reader --project "$project_file" --bundle-id)"
minimum_system="$($version_reader --project "$project_file" --minimum-macos)"
minimum_major="${minimum_system%%.*}"
archive_name="Codex-Director-${marketing_version}-macOS-${minimum_major}-unnotarized.zip"

if [[ -e "$output_directory" ]]; then
  print -u2 "Release output already exists; choose a new path: $output_directory"
  exit 1
fi

output_parent="${output_directory:h}"
mkdir -p "$output_parent"
staging_root="$(mktemp -d "$output_parent/.codex-director-release.XXXXXX")"
staging_payload="$staging_root/payload"
mkdir "$staging_payload"
trap 'rm -rf "$staging_root"' EXIT INT TERM

archive_path="$staging_payload/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
cp "$project_root/Package.resolved" "$staging_payload/DEPENDENCIES.json"

archive_hash="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
dependency_hash="$(shasum -a 256 "$staging_payload/DEPENDENCIES.json" | awk '{print $1}')"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
build_macos="$(sw_vers -productVersion)"
build_xcode="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
build_swift="$(swift --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
build_sdk="$(xcrun --sdk macosx --show-sdk-version)"
[[ "$build_macos" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Unable to identify macOS build environment"; exit 1; }
[[ "$build_xcode" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Unable to identify Xcode build environment"; exit 1; }
[[ "$build_swift" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Unable to identify Swift build environment"; exit 1; }
[[ "$build_sdk" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Unable to identify SDK build environment"; exit 1; }

cat > "$staging_payload/BUILD-INFO.json" <<EOF
{
  "schemaVersion": 1,
  "product": "Codex Director",
  "marketingVersion": "$marketing_version",
  "buildVersion": "$build_version",
  "bundleIdentifier": "$bundle_id",
  "minimumMacOS": "$minimum_system",
  "architectures": [
    "arm64",
    "x86_64"
  ],
  "signing": {
    "type": "ad-hoc",
    "appleDeveloperID": false
  },
  "notarizedByApple": false,
  "buildEnvironment": {
    "macOS": "$build_macos",
    "xcode": "$build_xcode",
    "swift": "$build_swift",
    "sdk": "$build_sdk"
  },
  "archiveName": "$archive_name",
  "archiveSHA256": "$archive_hash",
  "packageResolvedSHA256": "$dependency_hash",
  "source": {
    "repository": "https://github.com/SimuDesign/Codex-Director",
    "commit": "$source_commit",
    "tag": "$source_tag"
  },
  "builtAtUTC": "$created_at"
}
EOF

(
  cd "$staging_payload"
  shasum -a 256 "$archive_name" BUILD-INFO.json DEPENDENCIES.json > SHA256SUMS.txt
)

verification_arguments=(
  --directory "$staging_payload"
  --project "$project_file"
  --source-commit "$source_commit"
)
if [[ -n "$source_tag" ]]; then
  verification_arguments+=(--source-tag "$source_tag")
fi
"$script_dir/verify-release-artifacts.sh" "${verification_arguments[@]}"

mv "$staging_payload" "$output_directory"
print "Created verified release artifacts: $output_directory"

#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
project="$project_root/CodexDirector.xcodeproj"
scheme="Codex Director"
configuration="${CONFIGURATION:-Release}"
derived_data="${DERIVED_DATA_PATH:-/tmp/codex-director-xcode}"
package_cache="$derived_data/package-cache"
source_packages="$derived_data/SourcePackages"
app_path="$derived_data/Build/Products/$configuration/Codex Director.app"

if [[ ! -d "$project" ]]; then
  print -u2 "Missing Xcode project: $project"
  exit 1
fi

if [[ ! -f "$project/xcshareddata/xcschemes/Codex Director.xcscheme" ]]; then
  print -u2 "Missing shared scheme: $scheme"
  exit 1
fi

mkdir -p "$derived_data" "$package_cache" "$source_packages"

print "Building $scheme ($configuration)..."
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data" \
  -packageCachePath "$package_cache" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  DEPLOYMENT_POSTPROCESSING=YES \
  COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  build

if [[ ! -d "$app_path" || ! -x "$app_path/Contents/MacOS/Codex Director" ]]; then
  print -u2 "Build did not produce an executable app bundle: $app_path"
  exit 1
fi

"$script_dir/verify-app-bundle.sh" --app "$app_path" --project "$project_root/project.yml"
print "Built and verified: $app_path"

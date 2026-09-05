#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
project_file="$project_root/project.yml"
app_path=""

usage() {
  print -u2 "Usage: $0 --app PATH [--project FILE]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    --project)
      (( $# >= 2 )) || usage
      project_file="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$app_path" && -d "$app_path" && -f "$project_file" ]] || usage

version_reader="$script_dir/read-project-version.sh"
expected_bundle_id="$($version_reader --project "$project_file" --bundle-id)"
expected_marketing_version="$($version_reader --project "$project_file" --marketing)"
expected_build_version="$($version_reader --project "$project_file" --build)"
expected_minimum_system="$($version_reader --project "$project_file" --minimum-macos)"
executable="$app_path/Contents/MacOS/Codex Director"
info_plist="$app_path/Contents/Info.plist"

[[ -x "$executable" ]] || { print -u2 "Missing app executable: $executable"; exit 1; }
[[ -f "$info_plist" ]] || { print -u2 "Missing Info.plist: $info_plist"; exit 1; }

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$info_plist" 2>/dev/null || true)"

[[ "$bundle_id" == "$expected_bundle_id" ]] || { print -u2 "Unexpected bundle id: $bundle_id"; exit 1; }
[[ "$display_name" == "Codex Director" ]] || { print -u2 "Unexpected display name: $display_name"; exit 1; }
[[ "$short_version" == "$expected_marketing_version" ]] || { print -u2 "Unexpected marketing version: $short_version"; exit 1; }
[[ "$build_version" == "$expected_build_version" ]] || { print -u2 "Unexpected build version: $build_version"; exit 1; }
[[ "$minimum_system" == "$expected_minimum_system" ]] || { print -u2 "Unexpected minimum system: $minimum_system"; exit 1; }
[[ "$icon_name" == "AppIcon" ]] || { print -u2 "Missing CFBundleIconName=AppIcon"; exit 1; }
[[ -f "$app_path/Contents/Resources/Assets.car" ]] || { print -u2 "Compiled asset catalog is missing"; exit 1; }

notice_path="$(find "$app_path/Contents/Resources" -name THIRD_PARTY_NOTICES.md -type f -print -quit)"
[[ -n "$notice_path" ]] || { print -u2 "Bundled third-party notice is missing"; exit 1; }
rg -q 'ZIPFoundation 0\.9\.20' "$notice_path" || { print -u2 "ZIPFoundation notice/version is missing"; exit 1; }

architecture_list="$(lipo -archs "$executable" | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "$architecture_list" == "arm64 x86_64" ]] || {
  print -u2 "Release app must contain exactly arm64 and x86_64; found: $architecture_list"
  exit 1
}

codesign --verify --deep --strict "$app_path"
signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
[[ "$signature_details" == *"Signature=adhoc"* ]] || { print -u2 "Release app is not ad-hoc signed"; exit 1; }
[[ "$signature_details" == *"flags="*"runtime"* ]] || { print -u2 "Hardened runtime flag is missing"; exit 1; }

entitlements="$(codesign -d --entitlements :- "$app_path" 2>&1 || true)"
if [[ "$entitlements" == *"com.apple.security.app-sandbox"* || "$entitlements" == *"get-task-allow"* ]]; then
  print -u2 "Release entitlements contain a forbidden sandbox or debug entitlement"
  exit 1
fi

if find "$app_path/Contents" \( -iname '*fixture*' -o -iname '*test*' \) -print -quit | rg -q .; then
  print -u2 "Test or fixture content was packaged into the app bundle"
  exit 1
fi

unsafe_home_path=""
while IFS= read -r -d $'\0' bundled_file; do
  if strings -a "$bundled_file" 2>/dev/null \
    | sed -E 's#/Users/(example|runner|test|Shared)(/|$)#{{HOME}}\2#g' \
    | rg -q '/Users/[[:alnum:]_.-]+'; then
    unsafe_home_path="$bundled_file"
    break
  fi
done < <(find "$app_path/Contents" -type f -print0)
if [[ -n "$unsafe_home_path" ]]; then
  print -u2 "A user-specific absolute path was found in the app bundle: $unsafe_home_path"
  exit 1
fi

print "Verified app: $app_path"
print "Bundle: $bundle_id | Version: $short_version ($build_version) | macOS: $minimum_system | Architectures: $architecture_list | Signature: ad-hoc"

#!/bin/zsh
set -euo pipefail

build_root="${DERIVED_DATA_PATH:-/tmp/codex-director-validation}"
app_path="$build_root/Build/Products/Debug/Codex Director Validation.app"
default_app_path="$build_root/Build/Products/Debug/Codex Director.app"
products_path="$build_root/Build/Products/Debug"
plist_path="$app_path/Contents/Info.plist"

xcodebuild \
  -project CodexDirector.xcodeproj \
  -scheme 'Codex Director' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$build_root" \
  PRODUCT_BUNDLE_IDENTIFIER=com.peiweitang.CodexDirector.Validation \
  INFOPLIST_KEY_CFBundleDisplayName='Codex Director Validation' \
  INFOPLIST_KEY_DirectorUIValidationMode=YES \
  build

# Keep the app target's product name scoped to the app. Passing PRODUCT_NAME
# globally also renames SwiftPM's resource bundle, so let Xcode produce its
# normal product and move only this disposable validation bundle afterward.
# Always stage the newly built default product: retaining an existing app here
# would merely re-sign a stale validation bundle on repeat runs.
if [[ ! -d "$default_app_path" ]]; then
  print -u2 "Fresh default app is missing: $default_app_path"
  exit 1
fi
default_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$default_app_path/Contents/Info.plist")
if [[ "$default_bundle_id" != "com.peiweitang.CodexDirector.Validation" ]]; then
  print -u2 "Fresh default app has unexpected identifier: $default_bundle_id"
  exit 1
fi
fresh_debug_dylib_path="$default_app_path/Contents/MacOS/Codex Director.debug.dylib"
if [[ ! -f "$fresh_debug_dylib_path" ]]; then
  print -u2 "Fresh default debug dylib is missing: $fresh_debug_dylib_path"
  exit 1
fi
fresh_debug_dylib_hash=$(shasum -a 256 "$fresh_debug_dylib_path" | cut -d ' ' -f 1)
if [[ -e "$app_path" ]]; then
  if [[ ! -d "$app_path" || ! -f "$app_path/Contents/Info.plist" ]]; then
    print -u2 "Refusing to replace non-bundle validation path: $app_path"
    exit 1
  fi
  existing_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")
  if [[ "$existing_bundle_id" != "com.peiweitang.CodexDirector.Validation" ]]; then
    print -u2 "Refusing to replace unexpected validation bundle: $existing_bundle_id"
    exit 1
  fi
  backup_path="$products_path/Codex Director Validation.app.backup.$$.$RANDOM"
  mv "$app_path" "$backup_path"
  print "Previous validation app preserved at: $backup_path"
fi
mv "$default_app_path" "$app_path"
staged_debug_dylib_path="$app_path/Contents/MacOS/Codex Director.debug.dylib"
staged_debug_dylib_hash=$(shasum -a 256 "$staged_debug_dylib_path" | cut -d ' ' -f 1)
if [[ "$staged_debug_dylib_hash" != "$fresh_debug_dylib_hash" ]]; then
  print -u2 "Staged debug dylib differs from fresh build: $fresh_debug_dylib_hash != $staged_debug_dylib_hash"
  exit 1
fi

# Xcode's generated Info.plist intentionally ignores unknown INFOPLIST_KEY_*
# settings. Add the opt-in flag only to this disposable validation bundle.
if plutil -extract DirectorUIValidationMode raw -o - "$plist_path" >/dev/null 2>&1; then
  plutil -replace DirectorUIValidationMode -bool YES "$plist_path"
else
  plutil -insert DirectorUIValidationMode -bool YES "$plist_path"
fi

# The plist is covered by the app signature; re-sign only this /tmp bundle.
codesign --force --deep --sign - "$app_path"

mode=$(plutil -extract DirectorUIValidationMode raw -o - "$plist_path")
if [[ "$mode" != "true" ]]; then
  print -u2 "Validation bundle did not receive DirectorUIValidationMode=true"
  exit 1
fi
bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$plist_path")
if [[ "$bundle_id" != "com.peiweitang.CodexDirector.Validation" ]]; then
  print -u2 "Validation bundle has unexpected identifier: $bundle_id"
  exit 1
fi
codesign --verify --deep --strict "$app_path"
print "Validation app: $app_path"
print "DirectorUIValidationMode: $mode"
print "Bundle identifier: $bundle_id"
print "Fresh debug dylib SHA-256: $fresh_debug_dylib_hash"
print "Staged debug dylib SHA-256: $staged_debug_dylib_hash"

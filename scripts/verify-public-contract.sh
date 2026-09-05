#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

required_files=(
  LICENSE
  PRIVACY.md
  SECURITY.md
  CONTRIBUTING.md
  CHANGELOG.md
  ASSETS_LICENSE.md
  THIRD_PARTY_NOTICES.md
  README.md
  README.zh-CN.md
  docs/ARCHITECTURE.md
  docs/BUILDING.md
  docs/INSTALL.md
  docs/PERFORMANCE.md
  docs/RELEASE.md
  docs/public-asset-inventory.md
  Package.resolved
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/feature_request.yml
  .github/pull_request_template.md
  .github/workflows/ci.yml
  .github/workflows/release.yml
)

for required_file in "${required_files[@]}"; do
  [[ -s "$required_file" ]] || { print -u2 "Missing required public file: $required_file"; exit 1; }
done

rg -q '^MIT License$' LICENSE || { print -u2 "LICENSE is not identified as MIT"; exit 1; }
rg -q '^Copyright \(c\) 2026 SimuDesign$' LICENSE || { print -u2 "MIT copyright identity is incorrect"; exit 1; }

resolved_version="$(/usr/bin/plutil -extract pins.0.state.version raw -o - Package.resolved)"
resolved_revision="$(/usr/bin/plutil -extract pins.0.state.revision raw -o - Package.resolved)"
resolved_identity="$(/usr/bin/plutil -extract pins.0.identity raw -o - Package.resolved)"
[[ "$resolved_identity" == "zipfoundation" && "$resolved_version" == "0.9.20" ]] || {
  print -u2 "ZIPFoundation must remain exactly locked to 0.9.20"
  exit 1
}
[[ "$resolved_revision" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "ZIPFoundation revision is not locked to a full commit"; exit 1; }
rg -q 'ZIPFoundation 0\.9\.20' THIRD_PARTY_NOTICES.md Sources/DirectorUI/Resources/THIRD_PARTY_NOTICES.md || {
  print -u2 "ZIPFoundation license notice is incomplete"
  exit 1
}

asset_inventory="docs/public-asset-inventory.md"
while IFS= read -r asset_path; do
  [[ -n "$asset_path" ]] || continue
  asset_hash="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
  rg -Fq -- "\`$asset_path\`" "$asset_inventory" || { print -u2 "Unregistered public media: $asset_path"; exit 1; }
  rg -Fq -- "\`$asset_hash\`" "$asset_inventory" || { print -u2 "Stale public media hash: $asset_path"; exit 1; }
done < <(git ls-files '*.png' '*.jpg' '*.jpeg' '*.icns' '*.svg' | LC_ALL=C sort)

print "Public source, license, dependency, and media contracts passed."

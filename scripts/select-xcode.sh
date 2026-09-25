#!/bin/bash
# Selects the newest released Xcode 26 or later on a GitHub macOS runner, where the versions are installed side by side
# as /Applications/Xcode_<version>.app, with `sudo xcode-select --switch`. scripts/toolchain.sh then uses that Xcode.
# Run by .github/workflows/ci.yml and release.yml. bash 3.2 compatible (the system bash on macOS).
#
# Optional environment:
#   XCODE_SEARCH_ROOT  folder that holds the Xcode_<version>.app bundles (default /Applications); for trying the
#                      selection against a fake folder, with stub sudo, xcodebuild and swift first in PATH
set -euo pipefail

root="${XCODE_SEARCH_ROOT:-/Applications}"
min_major=26
best="" best_version=""
for app in "$root"/Xcode_*.app; do
  [[ -d "$app" ]] || continue
  name="${app##*/}"
  version="${name#Xcode_}"
  version="${version%.app}"
  # Released versions only (Xcode_26.6.app, Xcode_26.4.1.app), never betas or release candidates.
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
  (( 10#${version%%.*} >= min_major )) || continue
  if [[ -z "$best" || "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)" == "$version" ]]; then
    best="$app" best_version="$version"
  fi
done
if [[ -z "$best" ]]; then
  echo "::error::이 러너에 Xcode $min_major 이상이 없습니다: $(echo "$root"/Xcode*.app)"
  exit 1
fi
developer_dir="$(cd "$best" && pwd -P)/Contents/Developer"
sudo xcode-select --switch "$developer_dir"
echo "선택: $developer_dir"
xcodebuild -version
swift --version

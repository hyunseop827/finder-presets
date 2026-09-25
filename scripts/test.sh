#!/bin/zsh
# Runs the unit tests (FinderPresetsCoreTests and FinderPresetsTests). `swift test` builds the whole package (including the SwiftUI app), so the
# SwiftUI macro plugin from Xcode is needed when building with the Command Line Tools toolchain.
set -e
cd "$(dirname "$0")/.."
source "$(dirname "$0")/toolchain.sh"
echo "toolchain: $DEVELOPER_DIR"
swift test "${SWIFT_EXTRA[@]}" "$@"

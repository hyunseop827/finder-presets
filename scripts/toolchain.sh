# Sourced by build/test scripts. Picks the toolchain and the macro-plugin flags SwiftPM needs.
# - Xcode with an accepted license: everything (SwiftUI macros, Swift Testing macros) ships inside it.
# - Command Line Tools only: SwiftUI's macro plugin lives only in Xcode.app, and Swift Testing's plugin
#   lives in the CLT's plugins/testing directory, so both paths are passed explicitly.
#
# An explicit DEVELOPER_DIR always wins. Otherwise, in this order:
#   1. the Xcode chosen with `xcode-select -s` (CI runners pick /Applications/Xcode_<version>.app this way),
#      if `xcodebuild -version` works with it (fails while its license is not accepted)
#   2. /Applications/Xcode.app, same check
#   3. the Command Line Tools
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
	_finder_presets_selected="$(env -u DEVELOPER_DIR xcode-select -p 2>/dev/null || true)"
	if [[ "$_finder_presets_selected" == *.app/Contents/Developer && -d "$_finder_presets_selected" ]] \
	   && DEVELOPER_DIR="$_finder_presets_selected" xcodebuild -version >/dev/null 2>&1; then
		export DEVELOPER_DIR="$_finder_presets_selected"
	elif [[ -d /Applications/Xcode.app ]] \
	   && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version >/dev/null 2>&1; then
		export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
	else
		export DEVELOPER_DIR=/Library/Developer/CommandLineTools
	fi
	unset _finder_presets_selected
fi
SWIFT_EXTRA=()
if [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools ]]; then
	XCODE_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	CLT_TESTING_PLUGINS="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
	# `if` rather than `[[ ]] &&`: a false test as the last command would make `source` fail under `set -e`.
	if [[ -d "$XCODE_PLUGINS" ]]; then SWIFT_EXTRA+=(-Xswiftc -plugin-path -Xswiftc "$XCODE_PLUGINS"); fi
	if [[ -d "$CLT_TESTING_PLUGINS" ]]; then SWIFT_EXTRA+=(-Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS"); fi
fi

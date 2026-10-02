#!/bin/zsh
# Builds Finder Presets.app with SwiftPM only (no Xcode project needed) and signs it.
#
#   ./scripts/build-app.sh [debug|release]      → build/Finder Presets.app (ad-hoc signed)
#
# debug (the default) also contains the development hooks (--selftest, --layout-probe, FINDER_PRESETS_APPEARANCE);
# release leaves them out.
#
# Optional environment:
#   APP_VERSION        CFBundleShortVersionString of the bundle (default: the value in Resources/Info.plist)
#   APP_BUILD          CFBundleVersion of the bundle, a whole number such as 42 (default: the value in Resources/Info.plist);
#                      Sparkle compares it, so a release must always have a higher one (CI uses the run number)
#   OUTPUT_DIR         folder that receives the .app (default: build; relative to the repository root)
#   CODESIGN_IDENTITY  "-" (default) signs ad-hoc. A certificate name ("Developer ID Application: …") also adds a
#                      secure timestamp, as notarization requires. Both sign with the hardened runtime.
# Only the Info.plist copy inside the bundle is edited; Resources/Info.plist is never changed.
set -e
P="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-debug}"
case "$CONF" in
	debug|release) ;;
	*) print -u2 "사용법: $0 [debug|release]"; exit 2 ;;
esac
OUT="${OUTPUT_DIR:-build}"
[[ "$OUT" == /* ]] || OUT="$P/$OUT"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ -n "${APP_VERSION:-}" && ! "$APP_VERSION" =~ '^[0-9A-Za-z._+-]+$' ]]; then
	print -u2 "APP_VERSION 형식이 잘못되었습니다: '$APP_VERSION' (예: 1.2.0, 1.2.0-beta.1)"; exit 2
fi
# The same form scripts/make-appcast.sh and the release's build-number check accept (sparkle:version), checked before
# anything is built.
if [[ -n "${APP_BUILD:-}" && ! "$APP_BUILD" =~ '^[1-9][0-9]*$' ]]; then
	print -u2 "APP_BUILD 형식이 잘못되었습니다: '$APP_BUILD' (1 이상의 정수, 예: 42)"; exit 2
fi
cd "$P"
source "$P/scripts/toolchain.sh"
echo "toolchain: $DEVELOPER_DIR"
swift build -c "$CONF" --product FinderPresets "${SWIFT_EXTRA[@]}"
# The build system decides where products go (.build/<conf> is not always a symlink to them), so ask it.
BIN_DIR="$(swift build -c "$CONF" --show-bin-path "${SWIFT_EXTRA[@]}")"
# What the executable loads, checked before the bundle at the output path is touched: Sparkle.framework by the one name
# that is looked up in the bundle, exactly once, and otherwise only libraries that are part of macOS (/System/Library,
# /usr/lib; nobody can write there). Every load command is looked at, not only the @rpath ones. Any other library found
# through @rpath (for example Swift's back-deployment libraries, which exist only inside Xcode) would be missing on a
# user's Mac; and one named by a path outside macOS (/usr/local/lib, @executable_path/…, @loader_path/…) would be loaded
# from wherever somebody put it, because the app is signed to load libraries that library validation would refuse
# (Resources/FinderPresets.entitlements). The rpaths are trimmed further down, on the bundle's copy.
SPARKLE_INSTALL_NAME="@rpath/Sparkle.framework/Versions/B/Sparkle"
SPARKLE_LOADS=0 FOREIGN=()
for library in ${(f)"$(otool -L "$BIN_DIR/FinderPresets" | awk 'NR > 1 { print $1 }')"}; do
	case "$library" in
		*/../*|*/..) FOREIGN+=("$library") ;;   # a path that climbs out of the folder it starts in
		"$SPARKLE_INSTALL_NAME") SPARKLE_LOADS=$((SPARKLE_LOADS + 1)) ;;
		/System/Library/*|/usr/lib/*) ;;
		*) FOREIGN+=("$library") ;;
	esac
done
if (( SPARKLE_LOADS != 1 || ${#FOREIGN} > 0 )); then
	print -u2 "실행 파일은 Sparkle.framework 하나($SPARKLE_INSTALL_NAME)와 macOS에 들어 있는 라이브러리(/System/Library, /usr/lib)만 불러와야 합니다."
	print -u2 "  $SPARKLE_INSTALL_NAME: ${SPARKLE_LOADS}번"
	if (( ${#FOREIGN} > 0 )); then print -u2 -l -- "  그 밖의 라이브러리:" "${(@)FOREIGN/#/    }"; fi
	exit 1
fi
# App icon: drawn by scripts/make-icon.swift (CoreGraphics, no asset catalog) and packed with iconutil.
# Only regenerated when Resources/AppIcon.icns is missing; delete that file to force a redraw.
ICNS="$P/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
	ICONSET="$P/build/AppIcon.iconset"
	rm -rf "$ICONSET"
	swift scripts/make-icon.swift "$ICONSET"
	iconutil -c icns "$ICONSET" -o "$ICNS"
	cp "$ICONSET/icon_512x512.png" "$P/build/icon-preview.png"
	echo "icon: $ICNS (preview: build/icon-preview.png)"
fi
APP="$OUT/Finder Presets.app"
PLIST="$APP/Contents/Info.plist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FinderPresets" "$APP/Contents/MacOS/FinderPresets"
# Only two run paths stay: Sparkle's (Contents/Frameworks) and the system's Swift libraries. SwiftPM also adds
# @loader_path and the toolchain's folder inside Xcode; with library validation disabled (for the ad-hoc signed Sparkle),
# a Sparkle.framework placed in either would be loaded instead of the bundled one. Nothing else loads through @rpath.
# The linker's signature goes first (editing the binary would invalidate it); the app is signed again below.
BIN="$APP/Contents/MacOS/FinderPresets"
codesign --remove-signature "$BIN"
rpaths() { otool -l "$BIN" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' }
for rpath in ${(f)"$(rpaths)"}; do
	case "$rpath" in
		/usr/lib/swift|@executable_path/../Frameworks) ;;
		*) install_name_tool -delete_rpath "$rpath" "$BIN" ;;
	esac
done
[[ "$(rpaths | LC_ALL=C sort | tr '\n' ' ')" == "/usr/lib/swift @executable_path/../Frameworks " ]] \
	|| { print -u2 "실행 파일의 rpath 가 예상과 다릅니다: $(rpaths | tr '\n' ' ')"; exit 1; }
cp Resources/Info.plist "$PLIST"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# License texts of the bundled third-party code (DSStore and Sparkle, MIT): their copyright notices must ship with the app.
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
# Sparkle.framework (AppUpdater, "업데이트 확인…"): SwiftPM leaves it next to the binary, which looks for it in
# Contents/Frameworks (the rpath in Package.swift); ditto keeps the framework's symlinks. Its XPC services serve sandboxed
# apps only and Info.plist enables none of them, so they are left out
# (https://sparkle-project.org/documentation/sandboxing/#removing-xpc-services). All of it is signed again below.
FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$BIN_DIR/Sparkle.framework" ]] || { print -u2 "$BIN_DIR/Sparkle.framework 가 없습니다."; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
# The app's two languages (Info.plist CFBundleLocalizations: ko, the development region, and en), from
# Resources/<lang>.lproj, used as they are (plain-text property lists, nothing to compile):
#   Localizable.strings (+ en's Localizable.stringsdict for plurals)  the app's texts, keyed by the Korean text
#   InfoPlist.strings                                                  Info.plist's usage descriptions
#   ServicesMenu.strings                                               the Finder services' titles (NSServices)
# Only these files are copied (never a .DS_Store). The unit tests (LocalizationTests) check every key the compiler
# extracts from the app against them; here only what a broken copy would ship is checked: every file parses, both
# languages have the same texts, and every service title and usage description is translated.
for lang in ko en; do
	mkdir -p "$APP/Contents/Resources/$lang.lproj"
	for f in Resources/$lang.lproj/*.strings(N) Resources/$lang.lproj/*.stringsdict(N); do
		plutil -lint -s "$f" || { print -u2 "$f 을(를) 읽을 수 없습니다."; exit 1; }
		cp "$f" "$APP/Contents/Resources/$lang.lproj/"
	done
	for table in Localizable InfoPlist ServicesMenu; do
		[[ -f "$APP/Contents/Resources/$lang.lproj/$table.strings" ]] || { print -u2 "Resources/$lang.lproj/$table.strings 가 없습니다."; exit 1; }
	done
	STRINGS="$APP/Contents/Resources/$lang.lproj/ServicesMenu.strings"
	i=0
	while TITLE="$(/usr/libexec/PlistBuddy -c "Print :NSServices:$i:NSMenuItem:default" "$PLIST" 2>/dev/null)"; do
		plutil -extract "$TITLE" raw -o /dev/null "$STRINGS" 2>/dev/null \
			|| { print -u2 "$lang.lproj/ServicesMenu.strings 에 서비스 제목 '$TITLE' 의 번역이 없습니다."; exit 1; }
		i=$((i + 1))
	done
	(( i > 0 )) || { print -u2 "Info.plist 에 NSServices 가 없습니다."; exit 1; }
	USAGE_KEYS=(${(f)"$(plutil -convert json -o - "$PLIST" | /usr/bin/grep -oE '"NS[A-Za-z]+UsageDescription"' | tr -d '"')"})
	(( ${#USAGE_KEYS} > 0 )) || { print -u2 "Info.plist 에 사용 설명(NS…UsageDescription)이 없습니다."; exit 1; }
	for key in "${USAGE_KEYS[@]}"; do
		plutil -extract "$key" raw -o /dev/null "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" 2>/dev/null \
			|| { print -u2 "$lang.lproj/InfoPlist.strings 에 $key 의 번역이 없습니다."; exit 1; }
	done
done
# The same Localizable texts in both languages (en: the strings and the stringsdict together).
osascript -l JavaScript - "$APP/Contents/Resources" <<'JXA' || exit 1
ObjC.import('Foundation')
function keys(path) {
	const d = $.NSDictionary.dictionaryWithContentsOfFile(path)
	return d.isNil() ? [] : ObjC.deepUnwrap(d.allKeys)
}
function run(argv) {
	const r = argv[0]
	const ko = new Set(keys(r + '/ko.lproj/Localizable.strings'))
	const en = new Set(keys(r + '/en.lproj/Localizable.strings').concat(keys(r + '/en.lproj/Localizable.stringsdict')))
	const onlyKo = [...ko].filter(k => !en.has(k)), onlyEn = [...en].filter(k => !ko.has(k))
	if (ko.size === 0 || onlyKo.length || onlyEn.length) {
		throw new Error('Localizable texts differ: ko ' + ko.size + ', en ' + en.size + '; only ko: ' + JSON.stringify(onlyKo.slice(0, 5)) + '; only en: ' + JSON.stringify(onlyEn.slice(0, 5)))
	}
	return 'localizations: ko, en (' + ko.size + ' texts each)'
}
JXA
if [[ -n "${APP_VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST"; fi
if [[ -n "${APP_BUILD:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$PLIST"; fi
echo "version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"
# The hardened runtime in both cases; its entitlements allow Apple Events (Finder) and loading the ad-hoc signed
# Sparkle.framework, which library validation would refuse (it has no Team ID).
SIGN=(--force --sign "$IDENTITY" --options runtime --entitlements Resources/FinderPresets.entitlements)
if [[ "$IDENTITY" == "-" ]]; then
	echo "signing: ad-hoc (hardened runtime)"
else
	SIGN+=(--timestamp)
	echo "signing: certificate (hardened runtime, timestamp)"
fi
# Inside out and never --deep: Sparkle's helpers, the framework, then the app with its entitlements
# (https://sparkle-project.org/documentation/sandboxing/#code-signing). The helpers keep the hardened runtime Sparkle ships
# them with; a certificate adds a timestamp, as notarization requires.
FW_SIGN=(--force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then FW_SIGN+=(--timestamp); fi
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
	codesign "${FW_SIGN[@]}" "$code"
done
codesign "${SIGN[@]}" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "built: $APP"

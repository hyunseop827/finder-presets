#!/bin/zsh
# Builds a release Finder Presets.app and packs it into a compressed disk image.
#
#   ./scripts/make-dmg.sh [version]   → build/FinderPresets-<version>.dmg and .dmg.sha256
#
# version: the argument, else APP_VERSION, else CFBundleShortVersionString of Resources/Info.plist
# (a leading "v", as in a v1.2.0 tag, is dropped). The app is built into build/release, never into
# build/Finder Presets.app, which may be running.
#
# Optional environment:
#   APP_BUILD          CFBundleVersion of the bundle (see build-app.sh)
#   CODESIGN_IDENTITY  "-" (default) signs only the app, ad-hoc; the disk image stays unsigned. A Developer ID
#                      Application certificate in the keychain signs the app (hardened runtime) and the disk image.
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
#                      App Store Connect API key (.p8 file). With all three the app and then the disk image are
#                      notarized (xcrun notarytool submit --wait) and stapled; otherwise notarization is skipped.
#   NOTARY_TIMEOUT     how long to wait for each notarization (default 30m)
# Under GitHub Actions the results are also written to $GITHUB_OUTPUT: dmg, sha256, version, signed, notarized.
# The staging folder and the verification mount live in a temporary folder that is removed even on failure.
set -e
setopt pipefail
P="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Finder Presets"

fail() { print -u2 "오류: $*"; exit 1 }

VERSION="${1:-${APP_VERSION:-}}"
if [[ -z "$VERSION" ]]; then
	VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$P/Resources/Info.plist")"
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ '^[0-9A-Za-z._+-]+$' ]] || fail "버전 형식이 잘못되었습니다: '$VERSION' (예: 1.2.0, 1.2.0-beta.1)"
IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
APP_DIR="$P/build/release"
APP="$APP_DIR/$NAME.app"
DMG="$P/build/FinderPresets-$VERSION.dmg"
SHA="$DMG.sha256"

NOTARIZE=0
if [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_PATH:-}" ]]; then
	[[ "$IDENTITY" != "-" ]] || fail "공증하려면 Developer ID 인증서로 서명해야 합니다. CODESIGN_IDENTITY 를 지정하세요."
	[[ -f "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH 파일이 없습니다."
	NOTARIZE=1
elif [[ -n "${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}${NOTARY_KEY_PATH:-}" ]]; then
	print -u2 "경고: NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH 가 모두 있어야 공증합니다. 공증을 건너뜁니다."
fi

# mktemp and the path lookup are separate, checked steps: inside `cd "$(mktemp …)"` a failed mktemp would make zsh run
# `cd ""` (which succeeds), and WORK would silently become the current directory — which the cleanup would then delete.
WORK_NEW="$(mktemp -d "${TMPDIR:-/tmp}/finder-presets-dmg.XXXXXX")" || fail "임시 폴더를 만들지 못했습니다 (TMPDIR=${TMPDIR:-/tmp})."
[[ -n "$WORK_NEW" && -d "$WORK_NEW" && "${WORK_NEW:t}" == finder-presets-dmg.* ]] || fail "임시 폴더 경로가 이상합니다: '$WORK_NEW'"
WORK="$WORK_NEW"
MNT=""
is_mounted() { [[ "$(mount)" == *" on $1 ("* ]] }
# Deletes only the folder made above: anything that is not a directory named finder-presets-dmg.* is left alone.
remove_work() { if [[ -n "$WORK" && "${WORK:t}" == finder-presets-dmg.* && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi }
cleanup() {
	local rc=$?
	if [[ -n "$MNT" ]] && is_mounted "$MNT"; then
		hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet || true
	fi
	if [[ -n "$MNT" ]] && is_mounted "$MNT"; then
		print -u2 "경고: $MNT 를 분리하지 못해 $WORK 를 남겨 둡니다. hdiutil detach -force 후 지우세요."
		rc=1
	else
		remove_work || true
	fi
	# Outputs are only moved into build/ at the very end; never leave a half-finished pair behind.
	if [[ $rc != 0 ]]; then rm -f "$DMG" "$SHA"; fi
	exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Physical path (/var → /private/var), so it matches what `mount` reports for the verification mount.
WORK_REAL="$(cd -- "$WORK" && pwd -P)" || fail "임시 폴더 경로를 확인하지 못했습니다: $WORK"
[[ "$WORK_REAL" == /* && "${WORK_REAL:t}" == finder-presets-dmg.* ]] || fail "임시 폴더 경로가 이상합니다: '$WORK_REAL'"
WORK="$WORK_REAL"
rm -f "$DMG" "$SHA"

notary() { xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" }

notarize() {   # notarize <file>: submit, wait, and fail with the notary log unless the result is Accepted
	local file="$1" result="$WORK/notary-${1:t}.json" notary_status id
	echo "notarize: ${file:t} (최대 $NOTARY_TIMEOUT 대기)"
	notary submit "$file" --wait --timeout "$NOTARY_TIMEOUT" --output-format json >"$result" || true
	notary_status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
	id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
	echo "notary: ${notary_status:-결과 없음} ${id:+(id $id)}"
	if [[ "$notary_status" != Accepted ]]; then
		cat "$result" >&2
		if [[ -n "$id" ]]; then notary log "$id" >&2 || true; fi
		fail "공증에 실패했습니다: ${file:t}"
	fi
}

echo "## 1. release 빌드 → ${APP#$P/}"
OUTPUT_DIR="$APP_DIR" APP_VERSION="$VERSION" CODESIGN_IDENTITY="$IDENTITY" "$P/scripts/build-app.sh" release

if [[ $NOTARIZE == 1 ]]; then
	echo "## 1b. 앱 공증"
	ditto -c -k --keepParent "$APP" "$WORK/app.zip"
	notarize "$WORK/app.zip"
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"
fi

echo "## 2. 디스크 이미지 만들기"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
OUT="$WORK/out.dmg"
# hdiutil occasionally reports "Resource busy" on CI machines; a short retry is the usual cure.
for attempt in 1 2 3; do
	if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT"; then break; fi
	if [[ $attempt == 3 ]]; then fail "hdiutil create 가 실패했습니다."; fi
	print -u2 "hdiutil create 실패, 다시 시도 ($attempt/3)"
	sleep $((attempt * 5))
done
if [[ "$IDENTITY" != "-" ]]; then
	codesign --force --sign "$IDENTITY" --timestamp "$OUT"
	codesign --verify --strict "$OUT"
fi

echo "## 3. 검사 (verify, 읽기 전용 마운트)"
hdiutil verify -quiet "$OUT"
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach "$OUT" -nobrowse -readonly -noautoopen -noverify -mountpoint "$MNT" -quiet
[[ -d "$MNT/$NAME.app" ]] || fail "디스크 이미지에 앱이 없습니다."
[[ -L "$MNT/Applications" && "$(readlink "$MNT/Applications")" == /Applications ]] || fail "Applications 링크가 없습니다."
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MNT/$NAME.app/Contents/Info.plist")"
[[ "$MOUNTED_VERSION" == "$VERSION" ]] || fail "앱 버전이 다릅니다: $MOUNTED_VERSION ≠ $VERSION"
NOTICES="$MNT/$NAME.app/Contents/Resources/ThirdPartyNotices.txt"
[[ -f "$NOTICES" ]] && cmp -s "$NOTICES" "$P/Resources/ThirdPartyNotices.txt" || fail "앱의 서드파티 고지(Contents/Resources/ThirdPartyNotices.txt)가 없거나 Resources/ThirdPartyNotices.txt 와 다릅니다."
codesign --verify --deep --strict "$MNT/$NAME.app"
if [[ $NOTARIZE == 1 ]]; then xcrun stapler validate "$MNT/$NAME.app"; fi
echo "  OK  앱, Applications 링크, 버전 $MOUNTED_VERSION, 서드파티 고지, 서명"
hdiutil detach "$MNT" -quiet
MNT=""

if [[ $NOTARIZE == 1 ]]; then
	echo "## 4. 디스크 이미지 공증"
	notarize "$OUT"
	xcrun stapler staple "$OUT"
	xcrun stapler validate "$OUT"
	spctl --assess --type open --context context:primary-signature --verbose "$OUT"
	hdiutil verify -quiet "$OUT"
fi

mv "$OUT" "$DMG"
(cd "${DMG:h}" && shasum -a 256 "${DMG:t}" >"${SHA:t}")
if [[ "$IDENTITY" == "-" ]]; then SIGNED=false; else SIGNED=true; fi
if [[ $NOTARIZE == 1 ]]; then NOTARIZED=true; else NOTARIZED=false; fi
echo "dmg: $DMG"
echo "sha256: $(cut -d' ' -f1 <"$SHA")"
if [[ $SIGNED == true ]]; then echo "서명: Developer ID 인증서 (앱과 디스크 이미지)"; else echo "서명: 앱만 ad-hoc (디스크 이미지는 서명 안 됨)"; fi
if [[ $NOTARIZED == true ]]; then echo "공증: 완료 (stapled)"; else echo "공증 안 됨"; fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		print -r -- "dmg=$DMG"
		print -r -- "sha256=$SHA"
		print -r -- "version=$VERSION"
		print -r -- "signed=$SIGNED"
		print -r -- "notarized=$NOTARIZED"
	} >>"$GITHUB_OUTPUT"
fi

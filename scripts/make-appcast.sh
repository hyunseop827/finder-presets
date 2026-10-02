#!/bin/zsh
# Writes the Sparkle appcast for one release: a feed with a single item, the given disk image, EdDSA-signed.
# The installed app reads it through SUFeedURL (Resources/Info.plist) when it checks for updates.
#
#   ./scripts/make-appcast.sh <app> <dmg> <download-url> <release-notes.md> <appcast.xml>
#
# <app>              the app inside <dmg> (make-dmg.sh leaves it in build/release): its CFBundleVersion,
#                    CFBundleShortVersionString, LSMinimumSystemVersion and SUPublicEDKey describe the item, so the
#                    feed always matches what it ships.
# <download-url>     where <dmg> will be downloaded from: an https address (CI: the versioned release asset, never the
#                    fixed name FinderPresets.dmg, which the next release replaces). Plain http is accepted only for
#                    this Mac itself (http://127.0.0.1:<port>/… or http://localhost:<port>/…), for an update that the
#                    owner tries out by hand.
# <release-notes.md> Markdown shown in the update window (the release notes without their '# v<version>' line).
#
# Environment:
#   SPARKLE_PRIVATE_KEY  the private EdDSA key, base64 (what `generate_keys -x` exports). Only the owner has it; CI gets
#                        it from the repository secret of the same name. Never written to disk or printed here, and
#                        taken out of the environment before the first program is started (see below).
#   SPARKLE_BIN          folder with Sparkle's sign_update (bin/ of the Sparkle-<version>.tar.xz distribution).
#
# Everything that needs no key is checked first: the files, the address, the app's version and its public key. An app
# that still carries the placeholder key (PASTE_…) is refused: a copy released with it could never update.
# The signature is checked against the app's own SUPublicEDKey (scripts/ed25519-verify.swift) before the feed is
# written: a key that is not the pair of the one the installed apps carry would make every update fail for every user,
# so that stops here instead.
# The item asks for an Apple Silicon Mac (sparkle:hardwareRequirements arm64): the app is built for arm64 only.
set -e
setopt pipefail
# The private key leaves the environment here, before any other program is started: every program this script runs
# (PlistBuddy, sign_update, swift, xmllint, …) would otherwise inherit it. It stays in a shell variable that is not
# exported and reaches exactly one program, sign_update, on standard input.
typeset +x PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
unset SPARKLE_PRIVATE_KEY
P="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Finder Presets"
LINK="https://github.com/hyunseop827/finder-presets"

fail() { print -u2 "오류: $*"; exit 1 }
(( $# == 5 )) || { print -u2 "사용법: $0 <app> <dmg> <download-url> <release-notes.md> <appcast.xml>"; exit 2 }
APP="$1" DMG="$2" URL="$3" NOTES="$4" OUT="$5"
[[ -f "$APP/Contents/Info.plist" && -f "$DMG" && -f "$NOTES" ]] || fail "앱, 디스크 이미지 또는 릴리스 노트가 없습니다."
# https, or http to this Mac only; and nothing that would need escaping in the XML attribute it is written into, or
# white space of any kind (a line break in the address would be folded into a space there).
[[ "$URL" =~ '^(https://|http://(127\.0\.0\.1|localhost)(:[0-9]+)?/)[^"<>&[:space:]]+$' ]] \
	|| fail "다운로드 주소가 잘못되었습니다 (https 주소여야 합니다): '$URL'"

# Empty when the key is missing, so the messages below are the ones shown.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true }
BUILD="$(plist CFBundleVersion)" VERSION="$(plist CFBundleShortVersionString)" MIN_OS="$(plist LSMinimumSystemVersion)"
PUBLIC_KEY="$(plist SUPublicEDKey)"
# Sparkle compares sparkle:version (CFBundleVersion) to decide what is newer: a plain integer, the CI run number.
[[ "$BUILD" =~ '^[1-9][0-9]*$' ]] || fail "앱의 빌드 번호(CFBundleVersion)가 정수가 아닙니다: '$BUILD'"
[[ "$VERSION" =~ '^[0-9A-Za-z._+-]+$' && "$MIN_OS" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] \
	|| fail "앱의 버전 정보가 이상합니다: 버전 '$VERSION', 최소 macOS '$MIN_OS'"
[[ -n "$PUBLIC_KEY" ]] || fail "앱의 Info.plist 에 SUPublicEDKey 가 없습니다."
if [[ "$PUBLIC_KEY" == PASTE_* ]]; then
	fail "앱의 SUPublicEDKey 가 아직 자리 표시 값('$PUBLIC_KEY')입니다. 저장소 소유자가 generate_keys --account finder-presets 가 출력한 공개 키를 Resources/Info.plist 에 넣은 뒤 다시 빌드해야 합니다. 이 값으로 나간 앱은 업데이트를 받을 수 없습니다."
fi
[[ "$PUBLIC_KEY" =~ '^[A-Za-z0-9+/]{43}=$' ]] || fail "앱의 SUPublicEDKey 가 EdDSA 공개 키(32바이트의 base64)가 아닙니다: '$PUBLIC_KEY'"

[[ -n "$PRIVATE_KEY" ]] || fail "SPARKLE_PRIVATE_KEY 가 없습니다 (generate_keys -x 로 내보낸 개인 키)."
[[ -x "${SPARKLE_BIN:-}/sign_update" ]] || fail "SPARKLE_BIN 에 sign_update 가 없습니다: '${SPARKLE_BIN:-}'"

# -p prints only the signature; the key goes in on standard input (sign_update reads its first line; `print` is part
# of the shell), so it is never an argument of a process, in a process's environment or in a file on disk.
# sign_update writes its errors to standard output too, and one of them quotes the key it was given: that output is
# captured here and never shown.
SIGNATURE="$(print -r -- "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" -p --ed-key-file - "$DMG")" \
	|| fail "sign_update 가 실패했습니다. SPARKLE_PRIVATE_KEY 가 generate_keys -x 로 내보낸 값 그대로인지 확인하세요."
unset PRIVATE_KEY
[[ "$SIGNATURE" =~ '^[A-Za-z0-9+/]{86}==$' ]] || fail "sign_update 가 서명을 만들지 못했습니다."
VERIFIED=0
xcrun swift "$P/scripts/ed25519-verify.swift" "$PUBLIC_KEY" "$DMG" "$SIGNATURE" || VERIFIED=$?
case $VERIFIED in
	0) ;;
	1) fail "서명이 앱의 SUPublicEDKey 와 맞지 않습니다. SPARKLE_PRIVATE_KEY 가 Resources/Info.plist 의 공개 키와 짝인지 확인하세요." ;;
	*) fail "서명을 확인하지 못했습니다 (scripts/ed25519-verify.swift 종료 코드 $VERIFIED)." ;;
esac
LENGTH="$(stat -f %z "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
BODY="$(<"$NOTES")"
BODY="${BODY//]]>/]]]]><![CDATA[>}"   # the only sequence CDATA cannot hold

TMP="$OUT.tmp"
cat > "$TMP" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$NAME</title>
    <link>$LINK</link>
    <item>
      <title>$NAME $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description sparkle:format="markdown"><![CDATA[$BODY]]></description>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$TMP" || { rm -f "$TMP"; fail "appcast XML 이 올바르지 않습니다."; }
mv "$TMP" "$OUT"
echo "appcast: $OUT ($VERSION, build $BUILD, $LENGTH bytes, $URL)"

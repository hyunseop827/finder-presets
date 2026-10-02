#!/bin/zsh
# Checks the two tools that only a release runs, scripts/make-appcast.sh and scripts/ed25519-verify.swift, without a
# key: a mistake in them must show on a pull request, not in the first release that needs them (ci.yml runs this).
#
#   ./scripts/check-release-tools.sh
#
# No key is made, read or used. The signatures are the published test vectors of RFC 8032 (section 7.1, TEST 1 to 3:
# public key, message, signature; their private keys are not here). Sparkle's sign_update is replaced by a stand-in
# that prints one of those signatures, and what make-appcast.sh hands it as "the key" is a fixed text that is no key.
# What is checked:
# - ed25519-verify.swift compiles, accepts the three vectors (exit 0), refuses a signature that belongs to another
#   message or key (1), and reports malformed arguments (2);
# - make-appcast.sh writes a well-formed feed with the app's values, the address, the length and the signature, and
#   keeps the release notes as they are; the key goes to sign_update on standard input and is in no program's
#   environment or arguments;
# - make-appcast.sh refuses, without writing a feed: the placeholder key, a signature that does not fit the app's
#   public key, a build number Sparkle could not compare, an address that is not https, a missing key; and it never
#   shows what sign_update printed.
# zsh, like the other scripts: the exit status is kept in `code` (zsh's `status` is read-only), and every failure inside
# a function leaves through `fail` (an explicit exit runs the EXIT trap; zsh skips it when errexit ends a function).
set -e
setopt pipefail nounset

cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/finder-presets-release-tools.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
	print -r -- "::error::$*"
	exit 1
}

# RFC 8032, section 7.1: public key and signature in base64 (as SUPublicEDKey and sparkle:edSignature are written),
# and the message as a file.
key1="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
sig1="5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
key2="PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="
sig2="kqAJqfDUyrhyDoILX2QlQKKye1QWUD+Ps3YiI+vbadoIWsHkPhWZbkWPNhPQ8R2MOHsurrQwKu6wDSkWErsMAA=="
key3="/FHNjmIYoaONpH7QAjDwWAgW7RO6MwOsXeuRFUiQgCU="
sig3="YpHWV97sJAJIJ+acOr4BowzlSKKEdDpEXjaA19taw6wY/5tTjRbykK5n92CYTcZZSnwV6XFu0o3AJ77O6h7ECg=="
: > "$work/message1"
printf '\x72' > "$work/message2"
printf '\xaf\x82' > "$work/message3"

print "## 1. scripts/ed25519-verify.swift"
# Compiled once for the cases below (this is also its type check); make-appcast.sh runs it as a script further down.
xcrun swiftc -o "$work/ed25519-verify" scripts/ed25519-verify.swift
verify() { # <expected exit status> <what> <arguments of ed25519-verify.swift…>
	local expected="$1" what="$2" code=0
	shift 2
	"$work/ed25519-verify" "$@" 2> /dev/null || code=$?
	[[ $code == "$expected" ]] || fail "ed25519-verify.swift: $what → 종료 코드 $code ($expected 이어야 합니다)."
	print -r -- "  OK  $what → $code"
}
verify 0 "RFC 8032 TEST 1 (빈 메시지)" "$key1" "$work/message1" "$sig1"
verify 0 "RFC 8032 TEST 2 (1바이트)" "$key2" "$work/message2" "$sig2"
verify 0 "RFC 8032 TEST 3 (2바이트)" "$key3" "$work/message3" "$sig3"
verify 1 "다른 파일의 서명" "$key2" "$work/message3" "$sig2"
verify 1 "다른 키의 서명" "$key2" "$work/message2" "$sig3"
verify 2 "자리 표시 키" "PASTE_PUBLIC_KEY_FROM_generate_keys" "$work/message2" "$sig2"
verify 2 "서명 자리에 공개 키" "$key2" "$work/message2" "$key2"
verify 2 "없는 파일" "$key2" "$work/no-such-file" "$sig2"
verify 2 "인자 부족" "$key2" "$work/message2"

print "## 2. scripts/make-appcast.sh"
zsh -n scripts/make-appcast.sh
# An app as make-appcast.sh reads it: only Contents/Info.plist.
app() { # <name> <CFBundleVersion> <SUPublicEDKey>
	mkdir -p "$work/$1.app/Contents" || fail "테스트용 앱 $1 을 만들지 못했습니다."
	cat > "$work/$1.app/Contents/Info.plist" << PLIST || fail "테스트용 앱 $1 을 만들지 못했습니다."
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.8.7</string>
<key>CFBundleVersion</key><string>$2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUPublicEDKey</key><string>$3</string>
</dict></plist>
PLIST
}
app good 57 "$key2"
app placeholder 57 "PASTE_PUBLIC_KEY_FROM_generate_keys"
app zero 0 "$key2"
app padded 057 "$key2"
# The "disk image" is the message of TEST 2, so its published signature fits the app's key.
cp "$work/message2" "$work/update.dmg"
# Release notes with everything XML could trip over, and Korean.
printf '%s\n' '- 앱 안에서 업데이트: `Finder Presets` > `업데이트 확인…`' '- a < b && c > d, ]]> and <b>&amp;</b>' > "$work/notes.md"

# The stand-in for Sparkle's sign_update. It signs nothing: it prints $STAND_IN_PRINTS and leaves with
# $STAND_IN_STATUS, after noting in $STAND_IN_LOG what it was started with. make-appcast.sh must start it with
# "-p --ed-key-file - <dmg>", the key text on standard input, and no SPARKLE_PRIVATE_KEY in the environment.
mkdir "$work/bin"
cat > "$work/bin/sign_update" << 'STAND_IN'
#!/bin/sh
IFS= read -r input || true
{
  echo "arguments: $*"
  echo "standard input: $input"
  if [ -n "${SPARKLE_PRIVATE_KEY+set}" ]; then echo "environment: SPARKLE_PRIVATE_KEY is set"; else echo "environment: clean"; fi
} > "$STAND_IN_LOG"
echo "$STAND_IN_PRINTS"
exit "${STAND_IN_STATUS:-0}"
STAND_IN
chmod +x "$work/bin/sign_update"
not_a_key="stand-in text (not a key)"
export STAND_IN_LOG="$work/sign_update.log"
url="https://github.com/hyunseop827/finder-presets/releases/download/v9.8.7/FinderPresets-9.8.7.dmg"

output=""
appcast() { # <expected exit status> <what> <app> <url> [VARIABLE=value…]: runs make-appcast.sh; its output is in $output
	local expected="$1" what="$2" name="$3" address="$4" code=0
	shift 4
	rm -f "$work/appcast.xml" "$work/appcast.xml.tmp" "$STAND_IN_LOG"
	output="$(env SPARKLE_BIN="$work/bin" SPARKLE_PRIVATE_KEY="$not_a_key" STAND_IN_PRINTS="$sig2" "$@" \
		./scripts/make-appcast.sh "$work/$name.app" "$work/update.dmg" "$address" "$work/notes.md" "$work/appcast.xml" 2>&1)" || code=$?
	[[ $code == "$expected" ]] || fail "make-appcast.sh: $what → 종료 코드 $code ($expected 이어야 합니다): $output"
	if [[ $expected != 0 && ( -e "$work/appcast.xml" || -e "$work/appcast.xml.tmp" ) ]]; then
		fail "make-appcast.sh: $what → 실패했는데 피드 파일이 남았습니다."
	fi
	[[ "$output" != *"$not_a_key"* ]] || fail "make-appcast.sh: $what → 출력에 키 자리에 넣은 값이 보입니다."
	print -r -- "  OK  $what → $code"
}
feed() { xmllint --xpath "string($1)" "$work/appcast.xml" }
expect() { # <what> <actual> <expected>
	[[ "$2" == "$3" ]] || fail "make-appcast.sh: 피드의 $1 이 '$2' 입니다 ('$3' 이어야 합니다)."
}

appcast 0 "올바른 앱과 서명" good "$url"
xmllint --noout "$work/appcast.xml"
expect "항목 수" "$(feed 'count(//item)')" 1
expect "sparkle:version" "$(feed '//item/*[local-name()="version"]')" 57
expect "sparkle:shortVersionString" "$(feed '//item/*[local-name()="shortVersionString"]')" 9.8.7
expect "sparkle:minimumSystemVersion" "$(feed '//item/*[local-name()="minimumSystemVersion"]')" 14.0
# Apple Silicon only: the app is built for arm64 alone (scripts/build-app.sh builds for the Mac it runs on, CI's arm64).
expect "sparkle:hardwareRequirements 수" "$(feed 'count(//*[local-name()="hardwareRequirements"])')" 1
expect "sparkle:hardwareRequirements" "$(feed '//item/*[local-name()="hardwareRequirements"]')" arm64
expect "enclosure url" "$(feed '//item/enclosure/@url')" "$url"
expect "enclosure length" "$(feed '//item/enclosure/@length')" 1
expect "sparkle:edSignature" "$(feed '//item/enclosure/@*[local-name()="edSignature"]')" "$sig2"
expect "description 형식" "$(feed '//item/description/@*[local-name()="format"]')" markdown
expect "릴리스 노트" "$(feed '//item/description')" "$(cat "$work/notes.md")"
expect "sign_update 호출" "$(cat "$STAND_IN_LOG")" "arguments: -p --ed-key-file - $work/update.dmg
standard input: $not_a_key
environment: clean"
appcast 0 "이 Mac의 http 주소 (직접 해 보는 업데이트)" good "http://127.0.0.1:8000/update.dmg"
appcast 0 "이 Mac의 http 주소 (localhost)" good "http://localhost:8000/update.dmg"

appcast 1 "자리 표시 키" placeholder "$url"
[[ "$output" == *PASTE_PUBLIC_KEY_FROM_generate_keys* && ! -e "$STAND_IN_LOG" ]] || fail "make-appcast.sh: 자리 표시 키인데 sign_update 를 실행했거나 이유를 알리지 않았습니다: $output"
appcast 1 "앱의 공개 키와 맞지 않는 서명" good "$url" STAND_IN_PRINTS="$sig3"
appcast 1 "서명이 아닌 출력" good "$url" STAND_IN_PRINTS="ERROR! this is not a signature"
appcast 1 "sign_update 실패 (출력에 키가 들어 있어도 보이지 않아야 함)" good "$url" STAND_IN_PRINTS="unable to decode $not_a_key" STAND_IN_STATUS=1
appcast 1 "키 없음" good "$url" SPARKLE_PRIVATE_KEY=
[[ ! -e "$STAND_IN_LOG" ]] || fail "make-appcast.sh: 키가 없는데 sign_update 를 실행했습니다."
appcast 1 "빌드 번호 0" zero "$url"
appcast 1 "빌드 번호 057" padded "$url"
appcast 1 "http 주소" good "http://github.com/hyunseop827/finder-presets/releases/download/v9.8.7/x.dmg"
appcast 1 "이 Mac처럼 보이는 다른 http 주소" good "http://127.0.0.1.example.com/update.dmg"
appcast 1 "줄바꿈이 든 주소" good "$url
"
appcast 1 "따옴표가 든 주소" good "$url\"x"
print "OK  릴리스 도구 (ed25519-verify.swift, make-appcast.sh)"

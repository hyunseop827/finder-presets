#!/bin/zsh
# Keeps the update key of the releases so far. An installed copy accepts an update only when its signature fits the
# SUPublicEDKey that copy itself carries; the app is ad-hoc signed, so there is no second way for it to trust one. A
# release with another key would pass every other check (its own key and signature fit each other) and then be refused
# by every copy that is already installed. So this commit's key must be the key of every published release that
# shipped with one (AGENTS.md, step 9).
#
#   ./scripts/check-update-key.sh
#
# The keys are read from the tags (Resources/Info.plist as it was released). The releases from before Sparkle (up to
# 0.2.1) have no key, and neither has one that shipped with the placeholder. Drafts are not looked at: no installed
# copy came from one.
# Also names the newest published release that shipped with a key, other than this version's own release (v + the
# CFBundleShortVersionString of Resources/Info.plist); empty before the first release with Sparkle. release.yml's
# build-number check then expects a published update feed, and a missing one is an error instead of "the first
# release". It goes to $GITHUB_OUTPUT as sparkle_release when that is set.
# ci.yml runs this on every push and pull request, release.yml before every release. Needs gh (GH_TOKEN in CI) and the
# tags (git fetch --tags origin; both workflows check out with them).
set -e
setopt pipefail
cd "$(dirname "$0")/.."
fail() { print -r -- "::error::$*"; exit 1 }
(( $# == 0 )) || { print -u2 "사용법: $0"; exit 2 }
PLIST=Resources/Info.plist
TAG="v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
REPOSITORY="${GITHUB_REPOSITORY:-hyunseop827/finder-presets}"

# SUPublicEDKey of the property list on standard input when it is a real Ed25519 public key (32 bytes in base64), else
# nothing: a missing key and the placeholder count the same.
key_of() {
	local key
	key="$(plutil -extract SUPublicEDKey raw -o - - 2>/dev/null)" || return 0
	if [[ "$key" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then print -r -- "$key"; fi
	return 0
}
CURRENT="$(key_of < "$PLIST")"

# Newest first. A failing API call stops here instead of reading as "no release".
RELEASES="$(gh api --paginate "repos/$REPOSITORY/releases?per_page=100" --jq '.[] | select(.draft | not) | .tag_name')" \
	|| fail "$REPOSITORY 의 릴리스 목록을 읽지 못해 업데이트 키를 확인할 수 없습니다."
# KEYED: the newest published release with a key, this version's included (for the message below).
SPARKLE_RELEASE="" KEYED=""
for name in ${(f)RELEASES}; do
	[[ "$name" == v* ]] || continue   # not one of release.yml's releases
	git rev-parse -q --verify "refs/tags/$name" > /dev/null \
		|| fail "릴리스 $name 의 태그가 이 저장소에 없어 그 릴리스의 업데이트 키를 확인할 수 없습니다. git fetch --tags origin 뒤 다시 실행하세요."
	# "The tag has no such file" is told apart from "the tag cannot be read".
	listed="$(git ls-tree --name-only "refs/tags/$name" -- "$PLIST")" \
		|| fail "태그 $name 를 읽지 못해 그 릴리스의 업데이트 키를 확인할 수 없습니다."
	released=""
	if [[ -n "$listed" ]]; then
		released="$(git show "refs/tags/$name:$PLIST" | key_of)" || fail "태그 $name 의 $PLIST 를 읽지 못했습니다."
	fi
	[[ -n "$released" ]] || continue
	# Also the release of this version itself, when it is out: a key changed under a version that is already released
	# is caught on the pull request, not only by the release job's "app changed" check after the merge.
	if [[ "$released" != "$CURRENT" ]]; then
		fail "$PLIST 의 SUPublicEDKey 가 $name 릴리스의 키와 다릅니다. 설치된 앱은 자기가 가진 키로 서명된 업데이트만 받으므로, 키를 바꿔 릴리스하면 이미 설치된 앱은 모두 업데이트할 수 없게 됩니다. $name 의 키($released)로 되돌리세요. 저장소 소유자만 바꿀 수 있는 값입니다."
	fi
	KEYED="${KEYED:-$name}"
	if [[ -z "$SPARKLE_RELEASE" && "$name" != "$TAG" ]]; then SPARKLE_RELEASE="$name"; fi
done

if [[ -n "$KEYED" ]]; then
	print -r -- "OK  SUPublicEDKey 가 업데이트 키가 들어간 릴리스(최신: $KEYED)의 키와 같습니다."
else
	print -r -- "OK  업데이트 키가 들어간 릴리스가 아직 없습니다 (Sparkle을 넣은 첫 릴리스 전)."
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then print -r -- "sparkle_release=$SPARKLE_RELEASE" >> "$GITHUB_OUTPUT"; fi

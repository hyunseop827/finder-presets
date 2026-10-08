#!/bin/zsh
# Decides whether this commit releases, and refuses when it must not. The first step of the release job (release.yml,
# "버전과 릴리스 상태 확인"), and with --check the same decisions on every pull request (ci.yml) and on the agent's
# own Mac before "올려": a version lower than an existing tag, a tag whose release is unfinished, stale release notes,
# or an app that changed since the tag of its version fails before the merge, not after it.
#
#   ./scripts/release-check.sh            full mode, release.yml only: also checks that HEAD is the tested commit and
#                                         is on origin/main, writes the notes' body to $RUNNER_TEMP/release-body.md and
#                                         the decision to $GITHUB_OUTPUT (version, tag, publish, verify, tag_exists,
#                                         release_state; scripts/check-update-key.sh adds sparkle_release)
#   ./scripts/release-check.sh --check    pull requests, and by hand: the same checks without the main-only ones, and
#                                         nothing is written
#
# What is checked, in this order:
# 1. CFBundleShortVersionString of Resources/Info.plist is X.Y.Z; the tag is vX.Y.Z.
# 2. (full mode) HEAD is the commit CI tested ($GITHUB_SHA) and is on origin/main.
# 3. Every other v* tag has a published release. release.yml tags first and publishes after, so a tag whose release is
#    a draft, or has no release, is a release that stopped half way; nothing else is merged or released until it is
#    finished (AGENTS.md, step 7). A pull request's token sees no drafts, so there "no release" counts as unfinished
#    too.
# 4. No existing vX.Y.Z tag is newer than the version.
# 5. .github/release-notes.md starts with "# vX.Y.Z" and has text under it. A body identical to the newest published
#    release's is a warning, not an error: a maintenance release may say the same thing again.
# 6. When this version is already released, the app files (app_inputs below) have not changed since its tag (with
#    --check: in the working tree, so uncommitted changes count) and no untracked app file lies around; then there is
#    nothing to release. When its tag exists but its release is not published, this is the re-run of the commit that
#    tagged it (full mode) or an unfinished release (an error).
# 7. scripts/check-update-key.sh: SUPublicEDKey is the key of every published release that shipped with one.
# Needs gh (GH_TOKEN in CI) and the tags (git fetch --tags origin; both workflows check out with them).
set -e
setopt pipefail nounset
cd "$(dirname "$0")/.."
fail() { print -r -- "::error::$*"; exit 1 }

mode=full
case "${1:-}" in
	"") ;;
	--check) mode=check ;;
	*) print -u2 "사용법: $0 [--check]"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 "사용법: $0 [--check]"; exit 2 }
if [[ $mode == full ]]; then
	[[ -n "${GITHUB_SHA:-}" && -n "${GITHUB_OUTPUT:-}" && -n "${RUNNER_TEMP:-}" ]] \
		|| fail "GITHUB_SHA, GITHUB_OUTPUT, RUNNER_TEMP 가 있어야 합니다 (release.yml 이 실행합니다). 손으로 돌릴 때는 --check 를 쓰세요."
fi

# Files that make up the app: a change here after a release needs a new version. The dev CLI and the debug-only
# harnesses (#if DEBUG) are not in the release build, so a change to them alone needs none. AGENTS.md ("This
# repository") lists the same files.
app_inputs=(Sources Resources Package.swift Package.resolved scripts/build-app.sh scripts/make-icon.swift
	scripts/toolchain.sh scripts/make-dmg.sh
	':(exclude)Sources/finder-presets' ':(exclude)Sources/FinderPresets/SelfTest.swift'
	':(exclude)Sources/FinderPresets/LayoutProbe.swift')
notes=.github/release-notes.md
plist=Resources/Info.plist
repository="${GITHUB_REPOSITORY:-hyunseop827/finder-presets}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$version" =~ $semver ]] || fail "$plist 의 CFBundleShortVersionString 형식이 잘못되었습니다: '$version' (예: 1.2.0)"
tag="v$version"

if [[ $mode == full ]]; then
	[[ "$(git rev-parse 'HEAD^{commit}')" == "$GITHUB_SHA" ]] || fail "체크아웃한 커밋이 테스트한 커밋과 다릅니다."
	git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
	git merge-base --is-ancestor HEAD refs/remotes/origin/main || fail "main 에 없는 커밋은 릴리스하지 않습니다."
fi

newer() {   # newer A B: A > B for X.Y.Z
	local -a a b
	local i
	a=("${(@s:.:)1}")
	b=("${(@s:.:)2}")
	for i in 1 2 3; do
		if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
		if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
	done
	return 1
}

# Every release the token can see, drafts included (a draft carries its future tag name too). A failing API call stops
# here instead of reading as "no release".
releases="$(gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[] | [.tag_name, (.draft | tostring)] | @tsv')" \
	|| fail "$repository 의 릴리스 목록을 읽지 못했습니다."
typeset -A published drafted
published=() drafted=()
for line in ${(f)releases}; do
	name="${line%%$'\t'*}"
	draft="${line##*$'\t'}"
	if [[ "$draft" == true ]]; then drafted[$name]=1; else published[$name]=1; fi
done
release_state=none
if (( ${+published[$tag]} )); then
	release_state=published
elif (( ${+drafted[$tag]} )); then
	release_state=draft
fi

# The vX.Y.Z tags; tags of another form are not release.yml's and are left alone.
typeset -a known_tags
known_tags=()
for known in ${(f)"$(git tag --list 'v*')"}; do
	[[ "${known#v}" =~ $semver ]] || continue
	known_tags+=("$known")
done

# A tag without a published release is a release that stopped half way. This version's own tag is judged further down.
# Before the version is compared with the tags, so that a tag left behind by a failed run is named as that, not as a
# version to climb over.
typeset -a unfinished
unfinished=()
for known in $known_tags; do
	[[ "$known" != "$tag" ]] || continue
	(( ${+published[$known]} )) || unfinished+=("$known")
done
if (( ${#unfinished} > 0 )); then
	fail "공개된 릴리스가 없는 태그가 있습니다: ${(j:, :)unfinished}. 그 릴리스는 끝나지 않은 것이므로, 마치기 전에는 아무것도 머지하거나 릴리스하지 않습니다 (AGENTS.md 7단계): 그 태그를 만든 main 의 CI 실행에서 'Re-run failed jobs'를 누르세요. 풀 리퀘스트의 토큰은 초안을 보지 못하므로, 초안인 릴리스도 여기서는 '없음'으로 보입니다."
fi

# Never release backwards: no existing vX.Y.Z tag may be newer than this version.
for known in $known_tags; do
	if newer "${known#v}" "$version"; then
		fail "$tag 가 이미 있는 $known 보다 낮습니다. $plist 의 버전을 올리세요."
	fi
done

# Release notes: '# vX.Y.Z' on the first line, then what changed.
[[ -f "$notes" ]] || fail "$notes 가 없습니다."
first="$(head -n 1 "$notes" | sed -e 's/[[:space:]]*$//')"
[[ "$first" == "# $tag" ]] || fail "$notes 의 첫 줄은 '# $tag' 이어야 합니다 (지금: '$first')."
body="$(tail -n +2 "$notes")"
[[ -n "${body//[[:space:]]/}" ]] || fail "$notes 에 바뀐 점을 적으세요."

# The newest published release other than this version's: the body usually says what changed since it. The same body
# again is allowed (a maintenance release may say the same thing), but worth a look.
latest_published=""
for known in $known_tags; do
	[[ "$known" != "$tag" ]] && (( ${+published[$known]} )) || continue
	if [[ -z "$latest_published" ]] || newer "${known#v}" "${latest_published#v}"; then latest_published="$known"; fi
done
if [[ -n "$latest_published" && "$release_state" != published ]]; then
	previous_body="$(git show "refs/tags/$latest_published:$notes" 2> /dev/null | tail -n +2 || true)"
	if [[ -n "${previous_body//[[:space:]]/}" && "${body//[[:space:]]/}" == "${previous_body//[[:space:]]/}" ]]; then
		print -r -- "::warning::$notes 의 본문이 $latest_published 의 릴리스 노트와 같습니다. 유지 보수 릴리스라면 그대로 둘 수 있지만, 이 버전에서 바뀐 점을 적어야 하는지 확인하세요."
	fi
fi

tag_commit=""
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
	tag_commit="$(git rev-parse "refs/tags/$tag^{commit}")"
fi
publish=true
verify=true
if [[ "$release_state" == published ]]; then
	[[ -n "$tag_commit" ]] || fail "릴리스 $tag 는 있는데 태그를 찾지 못했습니다."
	# Full mode compares the tested commit; --check the working tree, so uncommitted changes count before "올려".
	changed=0
	if [[ $mode == full ]]; then
		git diff --quiet "$tag_commit" HEAD -- "${app_inputs[@]}" || changed=$?
	else
		git diff --quiet "$tag_commit" -- "${app_inputs[@]}" || changed=$?
	fi
	case $changed in
		0) ;;
		1) fail "$tag 릴리스 뒤에 앱이 바뀌었습니다. $plist 의 버전을 올리고 $notes 를 새 버전으로 고치세요." ;;
		*) fail "$tag 와 지금 커밋을 비교하지 못했습니다 (git diff 종료 코드 $changed)." ;;
	esac
	untracked="$(git ls-files --others --exclude-standard -- "${app_inputs[@]}")"
	[[ -z "$untracked" ]] || fail "$tag 는 이미 릴리스되었는데 추적되지 않은 앱 파일이 있습니다: ${untracked//$'\n'/, }. 커밋할 파일이면 버전을 올리고, 아니면 치우세요."
	publish=false
	# A re-run of the commit that published it checks the download again.
	if [[ $mode == check || "$tag_commit" != "${GITHUB_SHA:-}" ]]; then verify=false; fi
	print -r -- "OK  $tag 는 이미 릴리스되었고 그 뒤로 앱은 바뀌지 않았습니다. 새로 올릴 것이 없습니다."
elif [[ -n "$tag_commit" ]]; then
	if [[ $mode == check ]]; then
		fail "태그 $tag 가 이미 있는데(${tag_commit:0:7}) 공개된 릴리스가 없습니다: 그 릴리스가 끝나지 않았습니다. 그 커밋의 main CI 실행에서 'Re-run failed jobs'로 마치기 전에는 머지하지 마세요 (풀 리퀘스트의 토큰은 초안을 보지 못합니다). 그 뒤에도 앱이 바뀌었다면 버전을 올려야 합니다."
	elif [[ "$tag_commit" != "$GITHUB_SHA" ]]; then
		fail "태그 $tag 가 다른 커밋(${tag_commit:0:7})에 있고 아직 릴리스되지 않았습니다. 그 커밋의 CI 실행에서 'Re-run failed jobs'로 마치거나, 버전을 올리세요. 태그는 옮기지 않습니다."
	else
		print -r -- "$tag 를 릴리스합니다 (태그: 있음, 릴리스: $release_state)."
	fi
elif [[ $mode == check ]]; then
	print -r -- "OK  $tag 는 아직 릴리스되지 않았습니다 (태그 없음, 릴리스: $release_state). main 에 머지되면 릴리스됩니다."
else
	print -r -- "$tag 를 릴리스합니다 (태그: 없음, 릴리스: $release_state)."
fi

# In-app updates: SUPublicEDKey must be the key of every published release that shipped with one. It prints the release
# it matched, and under GitHub Actions writes sparkle_release (the newest such release other than this version's) for
# the build-number check that follows in release.yml.
./scripts/check-update-key.sh

if [[ $mode == full ]]; then
	printf '%s\n' "$body" > "$RUNNER_TEMP/release-body.md"
	{
		print -r -- "version=$version"
		print -r -- "tag=$tag"
		print -r -- "publish=$publish"
		print -r -- "verify=$verify"
		print -r -- "tag_exists=$([[ -n "$tag_commit" ]] && echo true || echo false)"
		print -r -- "release_state=$release_state"
	} >> "$GITHUB_OUTPUT"
fi

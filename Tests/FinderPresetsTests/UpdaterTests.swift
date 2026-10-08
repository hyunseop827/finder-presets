// The updater (Sparkle): what Info.plist tells it, when the app starts it, what goes into the bundle with it, and what
// the release does with the update key.
//
// Nothing here starts Sparkle, asks the network for anything or makes a key. The settings are read from
// Resources/Info.plist, the decision to start is asked of `UpdaterConfiguration` and `AppUpdater` with values, and the
// bundle and the release are read from what makes them: Package.swift, scripts/build-app.sh, the entitlements, the
// workflows and the release scripts. (How the release scripts behave is checked by running them, without a key:
// scripts/check-release-tools.sh in CI.)
//
// `thePublicKeyIsARealKey` guards the owner's public key for updates in Resources/Info.plist (set on 2026-10-02). Do not
// weaken it, and never "fix" it with another key: installed copies accept only updates signed with the key they have.
import AppKit
import Foundation
import Testing
@testable import FinderPresets

private enum Repository {
	static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

	static func text(_ path: String) throws -> String {
		try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
	}

	static func propertyList(_ path: String) throws -> [String: Any] {
		let data = try Data(contentsOf: root.appendingPathComponent(path))
		return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], "\(path) is not a dictionary")
	}

	static func swiftSources(_ folder: String) throws -> [(name: String, text: String)] {
		let items = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
		return try items.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
			.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
	}

	/// The lines of a file, empty ones included (so the indices order them).
	static func lines(_ path: String) throws -> [String] {
		try text(path).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
	}
}

/// The feed every installed copy asks for updates. Once a release has shipped with it, it can never change (AGENTS.md,
/// "Changes and releases", step 9).
private let feedURL = "https://github.com/hyunseop827/finder-presets/releases/latest/download/appcast.xml"
/// What Resources/Info.plist held before the owner's key went in; the app and the release scripts still refuse it.
private let placeholderKey = "PASTE_PUBLIC_KEY_FROM_generate_keys"
/// A public key of the right shape that is nobody's secret: the public key of RFC 8032's first Ed25519 test vector
/// (section 7.1, TEST 1), 32 bytes, as base64.
private let publishedTestKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

/// Resources/Info.plist, as Sparkle reads it.
@Suite struct UpdaterSettingsTests {
	/// Updates are looked for once a day at Sparkle's default interval and when the user asks, and never installed
	/// without the user (there is no "install automatically" option). The feed is the latest GitHub release's appcast,
	/// over HTTPS. An update is verified before it is opened. Nothing about the Mac is sent, no XPC service is asked for
	/// (they are not in the bundle), and no exception to App Transport Security is made.
	@Test func updatesAreCheckedDailyAndInstalledOnlyByTheUser() throws {
		let plist = try Repository.propertyList("Resources/Info.plist")
		#expect(plist["SUFeedURL"] as? String == feedURL)
		// Booleans, not strings or numbers: `<true/>` and `<false/>`.
		#expect(plist["SUEnableAutomaticChecks"] as? NSNumber === kCFBooleanTrue, "SUEnableAutomaticChecks must be <true/>: a check once a day, without asking first")
		#expect(plist["SUAllowsAutomaticUpdates"] as? NSNumber === kCFBooleanFalse, "SUAllowsAutomaticUpdates must be <false/>: the user chooses to install")
		#expect(plist["SUVerifyUpdateBeforeExtraction"] as? NSNumber === kCFBooleanTrue, "SUVerifyUpdateBeforeExtraction must be <true/>")
		#expect(plist["SUPublicEDKey"] is String, "without a key Sparkle cannot verify an update")
		for key in [
			"SUScheduledCheckInterval", "SUAutomaticallyUpdate", "SUEnableSystemProfiling", "SUPublicDSAKeyFile",
			"SUEnableInstallerLauncherService", "SUEnableDownloaderService", "SUEnableInstallerConnectionService", "SUEnableInstallerStatusService",
			"NSAppTransportSecurity"
		] {
			#expect(plist[key] == nil, "\(key) must not be set")
		}

		// Sparkle compares CFBundleVersion: an integer (the released app gets the CI run number).
		let build = try #require(plist["CFBundleVersion"] as? String)
		#expect(Int(build).map { $0 >= 1 } == true && String(Int(build) ?? 0) == build, "CFBundleVersion must be an integer: \(build)")
		// The release compares its build number with the same feed.
		#expect(try Repository.text(".github/workflows/release.yml").contains("FEED: https://github.com/${{ github.repository }}/releases/latest/download/appcast.xml"))
	}

	/// Resources/Info.plist holds the owner's public key, a real Ed25519 key. An app released without one could never
	/// update itself, so this test stops a merge or a release if the key is ever removed or broken.
	@Test func thePublicKeyIsARealKey() throws {
		let plist = try Repository.propertyList("Resources/Info.plist")
		let key = try #require(plist["SUPublicEDKey"] as? String, "Resources/Info.plist has no SUPublicEDKey")
		#expect(
			Data(base64Encoded: key)?.count == 32,
			"""
			Resources/Info.plist: SUPublicEDKey is "\(key)", which is not an Ed25519 public key (base64 of 32 bytes, 44 characters).
			The owner set the public key here on 2026-10-02; put that same key back (it is in the git history). Never make a new
			key: installed copies accept only updates signed with the key they shipped with, and only the owner handles update
			keys (AGENTS.md, "Changes and releases", step 8): the private key is in the owner's login keychain (account
			finder-presets) with an offline backup, and in the repository secret SPARKLE_PRIVATE_KEY.
			After the first release with this key, neither the key nor SUFeedURL may change.
			"""
		)
	}

	/// Sparkle is the app's only code that uses the network: one file imports it, and no source of the app, the Core or
	/// the dev CLI opens a connection of its own.
	@Test func onlyTheUpdaterUsesTheNetwork() throws {
		let app = try Repository.swiftSources("Sources/FinderPresets")
		let core = try Repository.swiftSources("Sources/FinderPresetsCore")
		let cli = try Repository.swiftSources("Sources/finder-presets")
		#expect(app.count >= 20 && core.count >= 15 && !cli.isEmpty)
		#expect(app.filter { $0.text.contains("import Sparkle") }.map(\.name) == ["AppUpdater.swift"])
		#expect((core + cli).filter { $0.text.contains("Sparkle") }.map(\.name).isEmpty, "the Core and the CLI know nothing about updates")
		let network = ["URLSession", "URLRequest", "NSURLConnection", "NWConnection", "import Network", "CFNetwork", "CFStream", "WebKit"]
		for source in app + core + cli {
			for word in network {
				#expect(!source.text.contains(word), "\(source.name) uses \(word)")
			}
		}
	}
}

/// When the app starts the updater: `UpdaterConfiguration`, a pure function of two Info.plist values, and `AppUpdater`
/// with a counted stand-in for "start Sparkle".
@MainActor
@Suite struct AppUpdaterTests {
	@Test func aFeedAndARealKeyAreBothNeeded() throws {
		#expect(Data(base64Encoded: publishedTestKey)?.count == 32)
		#expect(UpdaterConfiguration(feedURL: feedURL, publicKey: publishedTestKey).canStart)

		// The key: missing, empty, the placeholder, not base64, base64 of another length.
		let short = Data(repeating: 7, count: 31).base64EncodedString(), long = Data(repeating: 7, count: 33).base64EncodedString()
		let signature = Data(repeating: 7, count: 64).base64EncodedString()
		for key in [nil, "", " ", placeholderKey, "not a key", String(publishedTestKey.dropLast()), publishedTestKey + "A", short, long, signature] {
			#expect(!UpdaterConfiguration(feedURL: feedURL, publicKey: key).canStart, "\(key ?? "nil")")
			#expect(!UpdaterConfiguration.isPublicKey(key), "\(key ?? "nil")")
		}
		// Sparkle ignores white space around the key (a line break after pasting it); so does the app.
		#expect(UpdaterConfiguration(feedURL: feedURL, publicKey: " \(publishedTestKey)\n").canStart)

		// The feed: missing or empty. Any other value is handed to Sparkle, which decides when it starts whether it can
		// be read; a feed on this Mac (an update tried out by hand, over http) is one of them.
		for feed in [nil, "", " ", "\n"] {
			#expect(!UpdaterConfiguration(feedURL: feed, publicKey: publishedTestKey).canStart, "\(feed ?? "nil")")
			#expect(!UpdaterConfiguration.isFeed(feed), "\(feed ?? "nil")")
		}
		#expect(UpdaterConfiguration(feedURL: "http://127.0.0.1:8000/appcast.xml", publicKey: publishedTestKey).canStart)
		#expect(!UpdaterConfiguration(feedURL: "http://127.0.0.1:8000/appcast.xml", publicKey: placeholderKey).canStart)
		#expect(!UpdaterConfiguration(feedURL: nil, publicKey: nil).canStart)
	}

	/// With the placeholder for the key, without a feed or without both, Sparkle is never asked to start: no check, no
	/// alert, nothing on the network. The two controls then have nothing to send and stay disabled.
	@Test func nothingIsStartedWithoutAFeedAndARealKey() {
		var started = 0
		let target = NSObject()
		let start: @MainActor () -> UpdateCheck? = {
			started += 1
			return UpdateCheck(target: target, action: NSSelectorFromString("checkForUpdates:"))
		}

		for configuration in [
			UpdaterConfiguration(feedURL: feedURL, publicKey: placeholderKey),
			UpdaterConfiguration(feedURL: feedURL, publicKey: nil),
			UpdaterConfiguration(feedURL: nil, publicKey: publishedTestKey),
			UpdaterConfiguration(feedURL: nil, publicKey: nil)
		] {
			let updater = AppUpdater(configuration: configuration, start: start)
			#expect(updater.check == nil && !updater.isAvailable && !updater.canCheck)
		}
		#expect(started == 0)

		// With both: started once, and what the start gives is what the controls get.
		let updater = AppUpdater(configuration: UpdaterConfiguration(feedURL: feedURL, publicKey: publishedTestKey), start: start)
		#expect(started == 1)
		#expect(updater.isAvailable && updater.check?.target === target)

		// Sparkle did not start (it reported an error): no updater, and the app goes on without one.
		let refused = AppUpdater(configuration: UpdaterConfiguration(feedURL: feedURL, publicKey: publishedTestKey), start: { nil })
		#expect(refused.check == nil && !refused.isAvailable && !refused.canCheck)
	}

	/// Under `swift test`, as under `swift run`, there is no app bundle: no feed, no key, and the app's own updater has
	/// started nothing.
	@Test func outsideTheAppBundleNothingIsStarted() {
		let configuration = UpdaterConfiguration(bundle: .main)
		#expect(configuration.feedURL == nil && configuration.publicKey == nil && !configuration.canStart)
		#expect(AppUpdater.shared.check == nil && !AppUpdater.shared.isAvailable && !AppUpdater.shared.canCheck)
	}

	/// The app built from this repository starts its updater exactly when Resources/Info.plist holds a real key: not
	/// with the placeholder (such a build must open without an alert), and at once when the key is in.
	@Test func theAppStartsItsUpdaterOnceTheKeyIsIn() throws {
		let plist = try Repository.propertyList("Resources/Info.plist")
		let key = try #require(plist["SUPublicEDKey"] as? String)
		let configuration = UpdaterConfiguration(feedURL: plist["SUFeedURL"] as? String, publicKey: key)
		#expect(UpdaterConfiguration.isFeed(configuration.feedURL) && configuration.feedURL == feedURL)
		#expect(configuration.canStart == (Data(base64Encoded: key)?.count == 32))
		#expect(!UpdaterConfiguration(feedURL: configuration.feedURL, publicKey: placeholderKey).canStart)
	}

	/// Both controls send `checkForUpdates(_:)` to Sparkle's controller, and follow its updater's `canCheckForUpdates`
	/// (false while Sparkle's window shows a check or an update). The app starts the updater itself instead of letting
	/// the controller do it, whose failure would be an alert at every launch.
	@Test func sparklesControllerAnswersForTheControls() throws {
		let controller = try #require(NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type, "Sparkle.framework is not loaded")
		#expect(controller.instancesRespond(to: NSSelectorFromString("checkForUpdates:")))

		let source = try Repository.text("Sources/FinderPresets/AppUpdater.swift")
		#expect(source.contains("SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)"))
		#expect(source.contains("try controller.updater.start()"))
		#expect(source.contains("UpdateCheck(target: controller, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)))"))
		#expect(source.contains(#"updater.observe(\.canCheckForUpdates, options: [.initial, .new])"#))
		#expect(!source.contains("startingUpdater: true") && !source.contains("controller.startUpdater()"))
		// Checks in the background and automatic downloads are Info.plist's to decide, not the code's.
		for word in ["automaticallyChecksForUpdates", "automaticallyDownloadsUpdates", "updateCheckInterval", "checkForUpdatesInBackground", "setFeedURL", "sendsSystemProfile"] {
			#expect(!source.contains(word), "AppUpdater.swift sets \(word)")
		}
	}
}

/// What the bundle is made of, read from what makes it (building it needs no window).
@Suite struct UpdaterBundleTests {
	/// Sparkle 2.10.0 exactly (the release workflow signs with the same version's tools), found through
	/// `@executable_path/../Frameworks` (the binary's only run path besides the system's Swift libraries); the framework
	/// is copied with its symlinks, without the XPC services a non-sandboxed app does not use; its helpers, then the
	/// framework, then the app are signed with the hardened runtime, never with `--deep`, and the result is verified
	/// strictly. The executable loads Sparkle by its one name and otherwise only libraries of macOS (every load command
	/// is looked at, before the bundle is touched). The app's entitlements are exactly Apple Events (Finder) and
	/// disabled library validation (the framework is ad-hoc signed like the app).
	@Test func sparkleIsBundledAndSignedInsideOut() throws {
		let package = try Repository.text("Package.swift")
		#expect(package.contains(#".package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")"#))
		#expect(package.contains(#""-rpath", "-Xlinker", "@executable_path/../Frameworks""#))
		let resolved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Repository.root.appendingPathComponent("Package.resolved"))) as? [String: Any])
		let pins = try #require(resolved["pins"] as? [[String: Any]])
		let sparkle = try #require(pins.first { $0["identity"] as? String == "sparkle" }, "Package.resolved has no Sparkle")
		#expect((sparkle["state"] as? [String: Any])?["version"] as? String == "2.10.0")

		let lines = try Repository.lines("scripts/build-app.sh")
		let script = lines.joined(separator: "\n")
		func line(_ text: String) throws -> Int { try #require(lines.firstIndex { $0.contains(text) }, "build-app.sh: no \(text)") }
		let copy = try line(#"ditto "$BIN_DIR/Sparkle.framework" "$FW""#)
		let xpc = try line(#"rm -rf "$FW/Versions/B/XPCServices""#)
		let helpers = try line(#"for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do"#)
		let app = try line(#"codesign "${SIGN[@]}" "$APP""#)
		let verify = try line(#"codesign --verify --deep --strict "$APP""#)
		#expect(copy < xpc && xpc < helpers && helpers < app && app < verify)
		#expect(script.contains(#"FW_SIGN=(--force --sign "$IDENTITY" --options runtime)"#))
		#expect(script.contains(#"SIGN=(--force --sign "$IDENTITY" --options runtime --entitlements Resources/FinderPresets.entitlements)"#))
		#expect(!lines.contains { $0.contains("codesign") && $0.contains("--deep") && !$0.contains("--verify") })
		// Only Sparkle's run path and the system's Swift libraries stay (SwiftPM's @loader_path and toolchain folder go),
		// before the app is signed; the script checks the result and fails otherwise.
		let rpaths = try line(#"install_name_tool -delete_rpath "$rpath" "$BIN""#)
		#expect(rpaths < app && script.contains(#"/usr/lib/swift|@executable_path/../Frameworks) ;;"#))
		#expect(script.contains(#""/usr/lib/swift @executable_path/../Frameworks ""#))
		// Every load command: Sparkle by that name, exactly once, and otherwise only what is part of macOS; on the
		// build's product, before the bundle at the output path is replaced.
		#expect(script.contains(#"SPARKLE_INSTALL_NAME="@rpath/Sparkle.framework/Versions/B/Sparkle""#))
		#expect(script.contains(#"for library in ${(f)"$(otool -L "$BIN_DIR/FinderPresets" | awk 'NR > 1 { print $1 }')"}; do"#))
		#expect(script.contains(#""$SPARKLE_INSTALL_NAME") SPARKLE_LOADS=$((SPARKLE_LOADS + 1)) ;;"#))
		#expect(script.contains("/System/Library/*|/usr/lib/*) ;;") && script.contains(#"*/../*|*/..) FOREIGN+=("$library") ;;"#))
		let loads = try line(#"if (( SPARKLE_LOADS != 1 || ${#FOREIGN} > 0 )); then"#)
		let replace = try line(#"rm -rf "$APP""#)
		#expect(loads < replace)
		// The build number: what Sparkle compares, in the one form the release accepts, checked before anything is built.
		let buildNumber = try line(#"! "$APP_BUILD" =~ '^[1-9][0-9]*$'"#)
		let build = try line(#"swift build -c "$CONF" --product FinderPresets"#)
		#expect(buildNumber < build)
		// CI looks at the built bundle's load commands the same way.
		let ci = try Repository.text(".github/workflows/ci.yml")
		#expect(ci.contains("@rpath/Sparkle.framework/Versions/B/Sparkle) sparkle_loads=$((sparkle_loads + 1)) ;;") && ci.contains("/System/Library/*|/usr/lib/*) ;;"))

		let entitlements = try Repository.propertyList("Resources/FinderPresets.entitlements")
		#expect(Set(entitlements.keys) == ["com.apple.security.automation.apple-events", "com.apple.security.cs.disable-library-validation"])
		#expect(entitlements.values.allSatisfy { $0 as? NSNumber === kCFBooleanTrue })
	}
}

/// The release: what the workflows and the release scripts do with the update key, read from their text. (How they
/// behave is checked by running them: scripts/check-release-tools.sh runs make-appcast.sh and ed25519-verify.swift
/// without a key.)
@Suite struct UpdaterReleaseTests {
	/// The private key's value reaches one step of one job: the step that signs, whose shell hands it to make-appcast.sh
	/// only. ci.yml hands release.yml each secret it declares, by name; the key check only learns whether it is set; and
	/// make-appcast.sh takes it out of the environment before it starts any other program.
	@Test func thePrivateKeyReachesOnlyTheSigningStep() throws {
		let value = "SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"
		let release = try Repository.lines(".github/workflows/release.yml")
		let holders = release.indices.filter { release[$0].contains(value) }
		#expect(holders.count == 1)
		let signing = try #require(release.firstIndex { $0.contains("- name: 업데이트 피드 만들기 (appcast.xml)") })
		let next = try #require(release[(signing + 1)...].firstIndex { $0.contains("- name: ") })
		#expect(holders.first.map { signing < $0 && $0 < next } == true, "the secret belongs to the signing step")
		// In that step only make-appcast.sh is started with it: the shell takes it out of its own environment first.
		let run = try #require(release[signing..<next].firstIndex { $0.hasSuffix("run: |") })
		#expect(release[(run + 1)...].prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
		        == [#"key="$SPARKLE_PRIVATE_KEY""#, "unset SPARKLE_PRIVATE_KEY"])
		#expect(release[signing..<next].filter { $0.contains("$key") }.count == 1
		        && release[signing..<next].contains { $0.contains(#"SPARKLE_PRIVATE_KEY="$key" ./scripts/make-appcast.sh "#) })
		#expect(release.contains { $0.contains("HAS_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY != '' }}") })

		let ci = try Repository.text(".github/workflows/ci.yml")
		let secrets = ["SPARKLE_PRIVATE_KEY", "MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD", "CODESIGN_IDENTITY",
		               "NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "NOTARY_KEY_P8_BASE64"]
		#expect(ci.components(separatedBy: "${{ secrets.").count == secrets.count + 1, "ci.yml names each secret once, for release.yml")
		for name in secrets {
			#expect(ci.contains("      \(name): ${{ secrets.\(name) }}"), "ci.yml does not hand \(name) to release.yml")
			#expect(release.contains("      \(name):"), "release.yml does not declare \(name) (on.workflow_call.secrets)")
		}
		#expect(!ci.contains("\n    secrets: inherit"), "release.yml gets these secrets, not every secret of the repository")

		// make-appcast.sh: nothing is started before the key has left the environment, and it goes to sign_update on
		// standard input.
		let script = try Repository.lines("scripts/make-appcast.sh").filter { !$0.hasPrefix("#") && !$0.isEmpty }
		#expect(Array(script.prefix(4)) == ["set -e", "setopt pipefail", #"typeset +x PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}""#, "unset SPARKLE_PRIVATE_KEY"])
		#expect(script.contains { $0.contains(#"print -r -- "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" -p --ed-key-file - "$DMG""#) })
		let valueUsed = script.filter { $0.contains("$PRIVATE_KEY") || $0.contains("${SPARKLE_PRIVATE_KEY") }
		#expect(valueUsed.count == 3, "the key's value is read where it is taken, checked and handed to sign_update: \(valueUsed)")
	}

	/// Pull requests check the update key, make the release decisions without publishing (scripts/release-check.sh
	/// --check) and run the release tools without a key, and while the key-format test fails (the placeholder), the app is
	/// still built and inspected (an arm64-only executable): the steps after the tests do not depend on their result.
	@Test func pullRequestsCheckTheReleaseToolsAndStillBuildWhenTheTestsFail() throws {
		let ci = try Repository.lines(".github/workflows/ci.yml")
		func step(_ name: String) throws -> [String] {
			let start = try #require(ci.firstIndex { $0.hasSuffix("- name: \(name)") }, "ci.yml: no step \(name)")
			let end = ci[(start + 1)...].firstIndex { $0.contains("- name: ") || $0.hasPrefix("  release:") } ?? ci.endIndex
			return ci[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }
		}

		#expect(ci.contains("          fetch-depth: 0") && ci.contains("          fetch-tags: true"), "the update keys are read from the tags")
		#expect(try step("업데이트 키 확인 (지난 릴리스와 같은 키)").contains("run: ./scripts/check-update-key.sh"))
		#expect(try step("버전·태그·릴리스 노트 확인").contains("run: ./scripts/release-check.sh --check"))
		#expect(try step("릴리스 도구 확인 (키 없이)").contains("run: ./scripts/check-release-tools.sh"))
		let tests = try step("단위 테스트")
		#expect(tests.contains("id: test") && tests.contains("run: ./scripts/test.sh") && !tests.contains { $0.hasPrefix("if:") })
		let build = try step("앱 빌드 (release, ad-hoc 서명)")
		#expect(build.contains("if: ${{ !cancelled() && steps.test.outcome != 'skipped' }}") && build.contains("id: build"))
		let bundle = try step("앱 번들 확인")
		#expect(bundle.contains("if: ${{ !cancelled() && steps.build.outcome == 'success' }}"))
		#expect(bundle.contains(#"archs="$(lipo -archs "$app/Contents/MacOS/FinderPresets")""#) && bundle.contains { $0.hasPrefix(#"[[ "$archs" == arm64 ]] ||"#) })
		// A failed check never releases: the release job needs the check job and has no status function of its own.
		let release = ci[(try #require(ci.firstIndex { $0.hasPrefix("  release:") }))...]
		#expect(release.contains("    needs: test-and-build") && release.contains("    if: github.event_name == 'push' && github.ref == 'refs/heads/main'"))
		#expect(!ci.contains { $0.contains("continue-on-error") || $0.contains("always()") })
	}

	/// The update key can never change between releases: scripts/check-update-key.sh, which pull requests run and the
	/// release runs through scripts/release-check.sh, compares this commit's SUPublicEDKey with the key of every published
	/// release, and tells the build-number check whether a release with Sparkle is out (a missing feed is then an error,
	/// not "the first release"). Any answer of the published feed other than 200 or 404 stops the release.
	@Test func theReleaseKeepsTheKeyOfTheReleasesSoFar() throws {
		let script = try Repository.text("scripts/check-update-key.sh")
		for text in [
			#"released="$(git show "refs/tags/$name:$PLIST" | key_of)""#, #"if [[ "$released" != "$CURRENT" ]]; then"#,
			"select(.draft | not)", #"print -r -- "sparkle_release=$SPARKLE_RELEASE" >> "$GITHUB_OUTPUT""#
		] {
			#expect(script.contains(text), "check-update-key.sh: no \(text)")
		}
		let release = try Repository.text(".github/workflows/release.yml")
		#expect(release.contains("\n        id: prepare\n        env:\n          GH_TOKEN: ${{ github.token }}\n        run: ./scripts/release-check.sh\n"))
		#expect(try Repository.text("scripts/release-check.sh").contains("\n./scripts/check-update-key.sh\n"))
		#expect(release.contains("SPARKLE_RELEASE: ${{ steps.prepare.outputs.sparkle_release }}"))
		let notFound = try #require(release.range(of: #"if [[ "$status" == 404 ]]; then"#))
		#expect(release[notFound.upperBound...].prefix(80).contains(#"if [[ -n "$SPARKLE_RELEASE" ]]; then"#))
		#expect(release.contains(#"[[ "$status" == 200 ]] || fail"#))
	}

	/// After the publish, the fixed-name dmg and the feed are downloaded again through the latest link (retried every 30
	/// seconds, ten times, until both are this release's, each attempt with its HTTP statuses) and the feed is checked: one
	/// item, an integer build number that is the downloaded app's own CFBundleVersion, this version, the versioned dmg's
	/// address and length, a signature that verifies against SUPublicEDKey, and an app built for arm64 only.
	@Test func thePublishedFeedIsDownloadedAgainAndChecked() throws {
		let release = try Repository.text(".github/workflows/release.yml")
		for text in [
			"attempts=10", "for (( attempt = 1; attempt <= attempts; attempt++ )); do", #"status="$(curl -sSL -o "$file" -w '%{http_code}' "$base/$file" || true)""#,
			"if [[ $fetched == true ]] && same_dmg && same_feed; then", "if (( attempt < attempts )); then sleep 30; fi",
			#"[[ "$(feed_value 'count(//item)')" == 1 ]]"#, #"[[ "$feed_build" =~ ^[1-9][0-9]*$ ]]"#, #"[[ "$short" == "$VERSION" ]]"#,
			#"[[ "$url" == "$server/download/$TAG/FinderPresets-$VERSION.dmg" ]]"#, #"[[ "$length" == "$(stat -f %z FinderPresets.dmg)" ]]"#,
			#"app_plist="$mount_dir/Finder Presets.app/Contents/Info.plist""#, #"[[ "$feed_build" == "$app_build" ]]"#, #"[[ "$app_archs" == arm64 ]]"#,
			#"xcrun swift "$GITHUB_WORKSPACE/scripts/ed25519-verify.swift" "$public_key" FinderPresets.dmg "$signature" || verified=$?"#
		] {
			#expect(release.contains(text), "release.yml: no \(text)")
		}
	}
}

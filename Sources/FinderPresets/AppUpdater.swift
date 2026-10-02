import AppKit
import Sparkle

// 앱 메뉴 > "업데이트 확인…" and the status bar's "업데이트 확인": Sparkle 2's standard updater. Info.plist sets
// `SUEnableAutomaticChecks` (once a day, Sparkle's default interval, so no "check automatically?" prompt) and
// `SUAllowsAutomaticUpdates` NO (no "install automatically" option: the user always chooses). A check reads the appcast
// (`SUFeedURL`: the latest GitHub release's appcast.xml); when it lists a newer build, Sparkle's window shows the release
// notes, and only after the user agrees downloads the disk image, verifies it with the EdDSA key in
// `SUPublicEDKey` before opening it, replaces this app and relaunches it. The quit for that goes through
// `AppDelegate.applicationShouldTerminate`, so a task that writes or has Finder quit finishes first (QuitGuard) and the
// update installs right after.
//
// The updater starts only with a feed and a real key (`UpdaterConfiguration`). Without them, as with the placeholder
// key that Resources/Info.plist holds until the owner puts his in, the app opens like any other build: no alert, no
// check, and both controls stay disabled.

/// What Info.plist says about updates, and the decision whether that is enough to start the updater. Values only, so
/// the decision is tested without a bundle and without Sparkle.
struct UpdaterConfiguration {
	/// `SUFeedURL` and `SUPublicEDKey`; nil when the key is missing or not a string.
	var feedURL: String?
	var publicKey: String?

	init(feedURL: String?, publicKey: String?) {
		self.feedURL = feedURL
		self.publicKey = publicKey
	}

	/// Outside an app bundle (`swift run`, the unit tests) there is no Info.plist of the app, and both are nil.
	init(bundle: Bundle) {
		self.init(
			feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
			publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
		)
	}

	/// The updater is started only with a feed to read and a key to check updates with. Sparkle refuses to start with a
	/// key it cannot decode and then puts an alert on the screen; a build that still has the placeholder for the key
	/// must open like any other, so the same question is asked here first.
	var canStart: Bool {
		Self.isFeed(feedURL) && Self.isPublicKey(publicKey)
	}

	/// A feed is named: `SUFeedURL` is there and not empty. Whether the address can be read is Sparkle's to say when it
	/// starts (a refusal is logged, see `startSparkle`). Which address a shipped app has is not decided here: the unit
	/// tests accept only the https address of the latest GitHub release.
	static func isFeed(_ text: String?) -> Bool {
		guard let text else { return false }
		return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// An Ed25519 public key as Sparkle's `generate_keys` prints it: 32 bytes in base64 (44 characters). Sparkle itself
	/// ignores white space around the key, so this does too.
	static func isPublicKey(_ text: String?) -> Bool {
		guard let text else { return false }
		return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32
	}
}

/// What the two update controls send, and to whom: Sparkle's controller and its `checkForUpdates(_:)` in the app (the
/// value also keeps the controller alive), any object in the tests.
struct UpdateCheck {
	let target: AnyObject
	let action: Selector
}

@MainActor @Observable
final class AppUpdater {
	static let shared = AppUpdater()

	/// Nil when no updater was started: outside an app bundle, without a feed, with the placeholder for the key, or when
	/// Sparkle could not start. Both controls are then disabled, and nothing is ever asked of the network.
	let check: UpdateCheck?
	@ObservationIgnored private var observation: NSKeyValueObservation?
	/// False without an updater, and while Sparkle's window shows a check or an update (`SPUUpdater.canCheckForUpdates`).
	private(set) var canCheck = false

	/// `start` is only called when the configuration allows it. (A value, so the unit tests can ask without Sparkle.)
	init(
		configuration: UpdaterConfiguration = UpdaterConfiguration(bundle: .main),
		start: @MainActor () -> UpdateCheck? = AppUpdater.startSparkle
	) {
		check = configuration.canStart ? start() : nil
		guard let updater = (check?.target as? SPUStandardUpdaterController)?.updater else { return }
		observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
			// Sparkle changes it on the main thread.
			MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
		}
	}

	var isAvailable: Bool { check != nil }

	/// A user-initiated check: Sparkle's window says what it found (or that this is the latest version) and asks before
	/// anything is downloaded. Without an updater there is nothing to ask (the controls are disabled then).
	func checkForUpdates() {
		guard let check else { return }
		_ = NSApp.sendAction(check.action, to: check.target, from: nil)
	}

	/// Starts Sparkle's updater for the main bundle. Starting reads the settings and schedules the daily check: when no
	/// check was made in the last day (always so on the first launch) Sparkle reads the feed right away; otherwise it
	/// waits until a day has passed since the last one. Starting also lets an update the user already agreed to, and
	/// which waited for the app to quit, finish.
	///
	/// The controller is made without starting it, and the updater is started here: started by the controller, a
	/// failure would put Sparkle's "업데이트를 확인할 수 없습니다." alert on the screen at every launch, about something
	/// the user cannot change. A failure is logged instead, and the controls stay disabled.
	static func startSparkle() -> UpdateCheck? {
		let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
		do {
			try controller.updater.start()
		} catch {
			NSLog("The updater did not start: %@", error.localizedDescription)
			return nil
		}
		return UpdateCheck(target: controller, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
	}

	static var menuTitle: String { String(localized: "업데이트 확인…") }
	/// The status bar link's text, the same words as the menu item; the version is in its tooltip.
	static var linkName: String { String(localized: "업데이트 확인") }

	/// The link's tooltip: which version this is and, while the link is enabled, what a click does. A disabled link
	/// (no updater, or Sparkle's window is already checking) names only the version.
	static func help(version: String? = ReleaseLink.appVersion, enabled: Bool = true) -> String {
		let action = enabled ? String(localized: "눌러서 업데이트를 확인합니다.") : ""
		guard let version else { return action }
		let about = String(localized: "이 앱은 \(version) 버전입니다.")
		return action.isEmpty ? about : about + " " + action
	}
}

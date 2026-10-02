import Foundation
import AppKit

/// 도움말 > "최신 버전 열기…": GitHub's page of this app's latest release, in the browser (macOS opens it; this file sends
/// nothing). Checking for and installing updates is `AppUpdater`'s job (앱 메뉴 > "업데이트 확인…", the status bar's "업데이트 확인").
enum ReleaseLink {
	/// The only place the address lives: GitHub sends /releases/latest to the newest release that is not a pre-release.
	static let latest = URL(string: "https://github.com/hyunseop827/finder-presets/releases/latest")!

	/// This build's version (`CFBundleShortVersionString`); nil outside the app bundle (the tests, `swift run`).
	static var appVersion: String? {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
	}

	static var menuTitle: String { String(localized: "최신 버전 열기…") }

	/// Asks `opener` (`NSWorkspace.shared.open` in the app, a fake in the tests) to open `latest`. Returns nil when it
	/// did, else the status line that says it could not (a warning), with the address to open by hand.
	@MainActor
	static func open(with opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> String? {
		opener(latest) ? nil : String(localized: "최신 릴리스 페이지를 여는 데 실패했습니다. 직접 여세요: \(latest.absoluteString)")
	}
}

extension AppModel {
	/// "최신 버전 열기…": the release page in the browser; the status line says so when macOS could not open it.
	func openLatestRelease() {
		if let failure = ReleaseLink.open() { status = failure }
	}
}

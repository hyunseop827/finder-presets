import Foundation
import AppKit

/// "최신 버전" (the main window's toolbar) and 도움말 > "최신 버전 열기…": GitHub's page of this app's latest release, in
/// the browser. The app itself never goes online — no update check, nothing downloaded: it only asks macOS to open the
/// page, and the user decides there.
enum ReleaseLink {
	/// The only place the address lives: GitHub sends /releases/latest to the newest release that is not a pre-release.
	static let latest = URL(string: "https://github.com/hyunseop827/finder-presets/releases/latest")!

	/// This build's version (`CFBundleShortVersionString`); nil outside the app bundle (the tests, `swift run`).
	static var appVersion: String? {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
	}

	/// The toolbar button's and the menu item's names (the layout probe measures the button).
	static var buttonLabel: String { String(localized: "최신 버전") }
	static var menuTitle: String { String(localized: "최신 버전 열기…") }

	/// The tooltip: which version this is and what the button opens.
	static func help(version: String? = appVersion) -> String {
		let page = String(localized: "GitHub의 최신 릴리스 페이지를 브라우저에서 엽니다. 앱은 업데이트를 직접 확인하지 않습니다.")
		guard let version else { return page }
		return String(localized: "이 앱은 \(version) 버전입니다.") + " " + page
	}

	/// Asks `opener` (`NSWorkspace.shared.open` in the app, a fake in the tests) to open `latest`. Returns nil when it
	/// did, else the status line that says it could not (a warning), with the address to open by hand.
	@MainActor
	static func open(with opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> String? {
		opener(latest) ? nil : String(localized: "최신 릴리스 페이지를 여는 데 실패했습니다. 직접 여세요: \(latest.absoluteString)")
	}
}

extension AppModel {
	/// "최신 버전" / "최신 버전 열기…": the release page in the browser; the status line says so when macOS could not open it.
	func openLatestRelease() {
		if let failure = ReleaseLink.open() { status = failure }
	}
}

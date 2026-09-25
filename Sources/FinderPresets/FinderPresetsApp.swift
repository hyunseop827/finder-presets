import SwiftUI
import AppKit
import FinderPresetsCore

@main
struct FinderPresetsApp: App {
	@State private var model: AppModel
	// Registers the Finder services (all builds); debug builds also apply FINDER_PRESETS_APPEARANCE there.
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	init() {
		// No window tabs: 보기 > 탭 막대 보기 would add a tab bar and make the fixed window taller (see FixedWindow).
		// Here rather than in the AppDelegate, which runs later.
		NSWindow.allowsAutomaticWindowTabbing = false
		// The language and the date locale of this launch, fixed now (both are lazy `static let`s): a language chosen later
		// in the Settings window changes `Locale.preferredLanguages` at once, but the app only after a relaunch.
		_ = (AppLanguage.code, AppLanguage.locale)
		// One model for the window and the Finder services (FinderServices.swift), which can arrive before the window.
		let model = AppModel()
		_model = State(initialValue: model)
		FinderServiceProvider.shared.attach(model)
	}

	var body: some Scene {
		// No `if #available` in the scene body (scene builders and availability do not mix on macOS 14).
		WindowGroup("Finder Presets", id: "main") {
			MainView()
				.environment(model)
				.onAppear {
					#if DEBUG
					AppearanceOverride.applyFromEnvironment()
					if LayoutProbe.runIfRequested(model: model) { return }
					// The self-test drives the model directly; the first-launch guide would only get in its way.
					if SelfTest.runIfRequested(model: model) { return }
					#endif
					model.showHelpIfFirstLaunch()
					// Old records and their backups over the retention policy, once per launch in the background (never
					// for the self-test or the layout probe above, which return first).
					model.runLaunchRetentionOnce()
				}
				// The only size the content reports: constant (see UILayout.content). The window cannot be resized.
				.fixedContentSize()
				.background { FixedWindow().frame(width: 0, height: 0).accessibilityHidden(true) }
		}
		.windowResizability(.contentSize)
		.windowToolbarStyle(.unifiedCompact(showsTitle: true))
		.commands {
			CommandGroup(replacing: .newItem) {}
			// 도움말 > "Finder Presets 사용법" (⌘?) opens the guide sheet. The app has no Help Book, so the standard
			// "… 도움말" item would only say that no help is available. "최신 버전 열기…" opens GitHub's latest release
			// page in the browser, like the toolbar's "최신 버전" (ReleaseLink); it opens nothing in the app, so a dialog
			// does not stop it.
			CommandGroup(replacing: .help) {
				Button(String(localized: "Finder Presets 사용법")) { openFromMenu { model.showHelp = true } }
					.keyboardShortcut("?", modifiers: .command)
					.disabled(model.hasOpenDialog)
				Divider()
				Button(ReleaseLink.menuTitle) { model.openLatestRelease() }
			}
			// 보기 > "작업 기록" (⌘Y): the history sheet, like the toolbar's "기록".
			CommandGroup(after: .toolbar) {
				Button(String(localized: "작업 기록")) { openFromMenu { model.openHistory() } }
					.keyboardShortcut("y", modifiers: .command)
					.disabled(model.hasOpenDialog)
			}
		}

		// App menu > "설정…" (⌘,): the app's language (Views/LanguageSettings.swift), in its own small fixed-size window.
		Settings {
			LanguageSettingsView()
				.environment(model)
		}
		.windowResizability(.contentSize)
	}
}

/// A sheet opened from the menu bar: the window comes to the front first (opened again when it was closed), and nothing
/// opens over a dialog the model does not know about (the rename alert).
@MainActor private func openFromMenu(_ open: () -> Void) {
	guard !FinderServiceProvider.windowShowsDialog() else { NSSound.beep(); return }
	FinderServiceProvider.shared.showWindow()
	open()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationWillFinishLaunching(_ notification: Notification) {
		#if DEBUG
		// FINDER_PRESETS_APPEARANCE before the first window is created (and again in `onAppear`).
		AppearanceOverride.applyFromEnvironment()
		#endif
		// Finder's right-click services (Info.plist NSServices). Before launching finishes: when a service made macOS launch
		// the app, its request is delivered right after that.
		NSApp.servicesProvider = FinderServiceProvider.shared
	}

	/// "종료" (⌘Q, the Dock, logging out) while the app writes or has Finder quit is put off until that task ends; the
	/// app then quits by itself (`AppModel.terminateReply`).
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard let model = FinderServiceProvider.shared.model else { return .terminateNow }
		let reply = model.terminateReply()
		if reply == .terminateCancel { NSSound.beep() }
		return reply
	}

	func applicationWillTerminate(_ notification: Notification) {
		FinderServiceProvider.shared.model?.relaunchFinderLeftQuit()
		// "앱 다시 시작" in the Settings window: this app opens again once this process has exited.
		AppRelaunch.startIfRequested()
	}
}

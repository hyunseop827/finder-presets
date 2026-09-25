import SwiftUI
import AppKit
import Combine
import FinderPresetsCore

// One app, both languages: the language is chosen in the app's Settings window (app menu "설정…", ⌘,), the place a Mac
// user looks for an app's preferences. The main window keeps its fixed size; the Settings window has its own, also fixed.
// The same window also says which preset is the quick preset and where its shortcut is set (QuickPreset.swift).
//
// How: the choice is the per-app `AppleLanguages` key in the app's own defaults domain — exactly what macOS writes for
// System Settings > Language & Region > Applications — and it takes effect when the app launches again. It cannot switch
// live: Foundation fixes the bundle's localization at launch, so every `String(localized:)` (status lines, errors, alerts,
// plurals), AppKit's and SwiftUI's own menu items and the texts made before the switch would stay in the old language
// while only some SwiftUI literals changed (checked on macOS 26: after writing the key in the running process,
// `Bundle.main.preferredLocalizations` and `String(localized:)` keep the launch language while
// `Locale.preferredLanguages` already follows the new key). So the window says "다시 시작하면 적용됩니다" and offers
// "앱 다시 시작", which quits this app only (never Finder) and opens it again.
//
// For one launch, `-AppleLanguages '(en)'` on the command line still wins over the stored choice (the argument domain comes
// first); a `--layout-probe` run is started that way to check either language.

/// What the Settings window offers.
enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
	case system, korean, english
	var id: String { rawValue }

	/// The app's localization ("ko", "en") this choice names; nil for the system's languages.
	var localization: String? {
		switch self {
		case .system: nil
		case .korean: "ko"
		case .english: "en"
		}
	}

	/// A language's own name ("한국어", "English"), the same in both languages of the app.
	static func name(of localization: String) -> String {
		localization == "en" ? "English" : "한국어"   // l10n-exempt: a language is named in its own language
	}

	/// Whether a language identifier ("en-GB", "ko_KR", "ko") is of `localization`.
	static func matches(_ language: String, _ localization: String) -> Bool {
		language == localization || language.hasPrefix(localization + "-") || language.hasPrefix(localization + "_")
	}

	/// The localization the bundle picks for a list of preferred languages: the first language that is Korean or English,
	/// else the development region (Korean).
	static func localization(for languages: [String]) -> String {
		for language in languages {
			for localization in ["ko", "en"] where matches(language, localization) { return localization }
		}
		return "ko"
	}

	/// The per-app `AppleLanguages` to store for this choice (nil: remove the key, the system's languages apply). The
	/// user's own variant of the language is kept when the system list has one ("en-GB" keeps its date order).
	func appleLanguages(system: [String]) -> [String]? {
		guard let localization else { return nil }
		return [system.first { Self.matches($0, localization) } ?? localization]
	}

	/// The choice a stored `AppleLanguages` value stands for: none (or not a list of names) is the system's; a list set
	/// elsewhere (System Settings, `defaults`) is the language it makes the app show.
	static func choice(stored: Any?) -> LanguageChoice {
		guard let list = stored as? [String], !list.isEmpty else { return .system }
		return localization(for: list) == "en" ? .english : .korean
	}

	/// The localization the app shows after a relaunch with this choice.
	func resultingLocalization(system: [String]) -> String {
		localization ?? Self.localization(for: system)
	}

	/// The radio button's text: "시스템 설정 따름 (한국어)", "한국어", "English".
	func title(system: [String]) -> String {
		switch self {
		case .system: String(localized: "시스템 설정 따름 (\(Self.name(of: Self.localization(for: system))))")
		case .korean, .english: Self.name(of: localization ?? "ko")
		}
	}
}

/// Reads and writes the choice. `read` / `write` stand for the app's own defaults domain (`standard`); the tests pass a
/// dictionary.
struct LanguageSetting: Sendable {
	static let key = "AppleLanguages"
	var read: @Sendable () -> Any?
	var write: @Sendable ([String]?) -> Void
	/// The user's languages for all apps (System Settings > Language & Region).
	var systemLanguages: @Sendable () -> [String]

	var choice: LanguageChoice { LanguageChoice.choice(stored: read()) }

	/// Stores `choice`: the per-app list for a language, no key at all for "시스템 설정 따름".
	func set(_ choice: LanguageChoice) {
		write(choice.appleLanguages(system: systemLanguages()))
	}

	/// Whether a relaunch would show another language than this launch does (`current`: `AppLanguage.code`).
	func needsRelaunch(current: String) -> Bool {
		choice.resultingLocalization(system: systemLanguages()) != current
	}

	/// The app's own defaults domain (only its persistent domain: a `-AppleLanguages` argument of this launch is not a
	/// stored choice).
	static let standard = LanguageSetting(
		read: { Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?[key] } },
		write: { value in
			if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
		},
		systemLanguages: {
			CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
		})
}

/// "앱 다시 시작": this app quits and opens again, nothing else. The new instance is opened by a small shell that waits
/// until this process has exited, through LaunchServices (`open -n <this bundle>`), with this launch's `FINDER_PRESETS_*`
/// environment (an isolated `FINDER_PRESETS_DATA_DIR` stays isolated) and without its command-line arguments (a one-launch
/// `-AppleLanguages` would hide the new choice; debug hooks are not repeated).
@MainActor
enum AppRelaunch {
	/// Set by "앱 다시 시작" right before the app is asked to quit; `AppDelegate.applicationWillTerminate` opens the app
	/// again when it is set.
	static var requested = false

	/// Why the app cannot relaunch now, or nil. Never while a task writes or has Finder quit (QuitGuard), while Finder is
	/// not running, or while a sheet or alert is open (AppKit would not quit, or unsaved input would be lost).
	nonisolated static func blocker(working: Bool, writing: Bool, finderRunning: Bool, dialogOpen: Bool) -> String? {
		if working || writing { return String(localized: "작업이 끝난 뒤에 다시 시작할 수 있습니다.") }
		if !finderRunning { return String(localized: "Finder가 다시 실행된 뒤에 다시 시작할 수 있습니다.") }
		if dialogOpen { return String(localized: "열린 시트나 알림을 닫은 뒤에 다시 시작할 수 있습니다.") }
		return nil
	}

	/// The variables the new instance keeps: the app's own (`FINDER_PRESETS_DATA_DIR`, and `FINDER_PRESETS_APPEARANCE` of debug builds).
	/// `FINDER_PRESETS_DATA_DIR` names the folder this launch uses, not the text it was given: a relative path was resolved against
	/// `currentDirectory` (`AppDirectories.standard`), and an app LaunchServices opens starts in "/", so it is passed on
	/// as the absolute path of that same folder.
	nonisolated static func environment(from environment: [String: String], currentDirectory: String) -> [String: String] {
		var kept = environment.filter { $0.key.hasPrefix("FINDER_PRESETS_") }
		if let dir = kept["FINDER_PRESETS_DATA_DIR"], !dir.isEmpty {
			kept["FINDER_PRESETS_DATA_DIR"] = URL(fileURLWithPath: dir, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
				.standardizedFileURL.path
		}
		return kept
	}

	/// `open`'s arguments: a new instance of exactly this bundle with those variables.
	nonisolated static func openArguments(bundlePath: String, environment: [String: String]) -> [String] {
		["-n"] + environment.keys.sorted().flatMap { ["--env", "\($0)=\(environment[$0] ?? "")"] } + [bundlePath]
	}

	/// Waits (at most 60 s) for the process `$1` to exit (a zombie its parent has not reaped yet counts as exited), then
	/// runs `open` with the remaining arguments.
	nonisolated static let waitThenOpen = #"pid="$1"; shift; n=0; while kill -0 "$pid" 2>/dev/null; do "#
		+ #"case "$(ps -o stat= -p "$pid" 2>/dev/null)" in Z*) break;; esac; n=$((n+1)); [ "$n" -gt 600 ] && exit 1; sleep 0.1; "#
		+ #"done; exec /usr/bin/open "$@""#

	/// "앱 다시 시작" (the Settings window checked `blocker` first). The quit goes through `applicationShouldTerminate`
	/// like any other; when it does not happen (AppKit kept the app, or QuitGuard put it off until a task ends — then it
	/// relaunches once the task has ended), the request is dropped only in the first case.
	static func relaunch(model: AppModel) {
		requested = true
		NSApp.terminate(nil)
		// Still running: the quit was refused or put off.
		if !model.quitGuard.quitWhenDone { requested = false }
	}

	/// From `applicationWillTerminate`: starts the waiting shell when a relaunch was asked for.
	static func startIfRequested() {
		guard requested else { return }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", waitThenOpen, "sh", String(ProcessInfo.processInfo.processIdentifier)]
			+ openArguments(bundlePath: Bundle.main.bundlePath, environment: environment(from: ProcessInfo.processInfo.environment,
			                                                                      currentDirectory: FileManager.default.currentDirectoryPath))
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try? process.run()
	}
}

/// The Settings window (app menu "설정…", ⌘,): the language, then the quick preset — at one fixed size, nothing scrolls.
struct LanguageSettingsView: View {
	static let size = CGSize(width: 460, height: 346)
	/// System Settings > Keyboard, where Keyboard Shortcuts > Services holds the quick preset's shortcut. Only opened:
	/// the app never sets a shortcut (macOS keeps it per user; a service's own key equivalent could only be ⌘ or ⌘⇧).
	static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

	@Environment(AppModel.self) private var model
	@State private var choice = LanguageSetting.standard.choice
	/// Refreshed when the window opens and after each choice (the system's languages may change meanwhile).
	@State private var system = LanguageSetting.standard.systemLanguages()

	/// The quick preset's shortcut and the walkthrough that leads to it (Views/ShortcutGuideSheet.swift). The state is
	/// read again when this window appears, when the app becomes active again (the user comes back from System Settings)
	/// and when the walkthrough closes — never on a timer.
	private var guide: ShortcutGuide { ShortcutGuide.shared }
	private let becameActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)

	private var pending: Bool { choice.resultingLocalization(system: system) != AppLanguage.code }

	/// Why "앱 다시 시작" cannot run now (`AppRelaunch.blocker`). Part of it (Finder running, a sheet still attached while
	/// it closes) is not observable, so while a relaunch is pending the row below asks again every second; otherwise it
	/// shows no reason and nothing ticks.
	private func blocker() -> String? {
		AppRelaunch.blocker(working: model.isWorking, writing: model.quitGuard.writing, finderRunning: FinderController.isRunning,
		                    dialogOpen: model.hasOpenDialog || FinderServiceProvider.windowShowsDialog())
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Written only when the user picks one (opening the window never rewrites what is stored).
			Picker("언어:", selection: Binding(get: { choice }, set: { new in
				guard new != choice else { return }
				choice = new
				system = LanguageSetting.standard.systemLanguages()
				LanguageSetting.standard.set(new)
			})) {
				ForEach(LanguageChoice.allCases) { option in
					Text(verbatim: option.title(system: system)).tag(option)
				}
			}
			.pickerStyle(.radioGroup)
			.accessibilityIdentifier("languageChoice")
			.frame(height: 64, alignment: .topLeading)
			.probeFrame("settingsPicker")
			Text("앱의 메뉴와 창에 쓰는 언어입니다. Finder와 다른 앱에는 영향이 없습니다.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.lineLimit(2)
				.frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
				.padding(.top, 10)
				.probeFrame("settingsCaption")
			Divider().padding(.vertical, 10)
			Group {
				if pending {
					TimelineView(.periodic(from: .now, by: 1)) { _ in relaunchRow(blocker: blocker()) }
				} else {
					relaunchRow(blocker: nil)
				}
			}
			.frame(height: 34)
			Divider().padding(.vertical, 10)
			quickPresetSection
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 16)
		.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
		.onAppear {
			system = LanguageSetting.standard.systemLanguages()
			choice = LanguageSetting.standard.choice
			guide.refresh()
		}
		// The user leaves for System Settings, assigns the shortcut and comes back: the line says so at once, with no timer.
		.onReceive(becameActive) { _ in guide.refresh() }
		.sheet(isPresented: Binding(get: { guide.isOpen }, set: { if !$0 { guide.close() } }),
		       onDismiss: { guide.refresh() }) {
			ShortcutGuideSheet()
		}
	}

	/// "빠른 적용": the starred preset (or how to star one), the shortcut macOS has given the service, and the two buttons
	/// that lead to it — System Settings itself and the walkthrough.
	private var quickPresetSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Text("빠른 적용:")
				quickPresetName
					.lineLimit(1)
					.truncationMode(.middle)
					.frame(maxWidth: .infinity, alignment: .leading)
					// The width the text wants, for the layout probe: the flexible frame above never overlaps anything,
					// so only this shows that "없음 — …" would be cut off.
					.background(alignment: .leading) { quickPresetName.fixedSize().hidden().probeFrame("settingsQuickNameIdeal") }
				.accessibilityIdentifier("quickPresetName")
				.probeFrame("settingsQuickName")
			}
			.frame(height: 22)
			shortcutRow
			HStack(spacing: 8) {
				Button("키보드 단축키 열기…") { NSWorkspace.shared.open(Self.keyboardSettings) }
					.help("시스템 설정의 키보드 설정을 엽니다. 이 앱은 거기서 아무것도 바꾸지 않습니다.")
					.accessibilityIdentifier("openKeyboardShortcuts")
					.fixedSize()
					.probeFrame("settingsShortcuts")
				// Straight to the step that leads out of the state the line reports: the check box when the service is
				// switched off, the last step (which names the star) when nothing is starred, the beginning otherwise.
				Button("설정 방법 보기…") { guide.open(at: ShortcutStateText.step(for: guide.shortcut, starred: model.quickPreset != nil)) }
					.help("단축키를 지정하는 화면까지 단계별로 보여 줍니다.")
					.accessibilityIdentifier("openShortcutGuide")
					.fixedSize()
					.probeFrame("settingsGuideButton")
				Spacer(minLength: 0)
			}
			.frame(height: 22)
			Text(quickCaption)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.lineLimit(3)
				.frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .topLeading)
				.probeFrame("settingsQuickCaption")
		}
	}

	/// What macOS has for the service now (`ServiceShortcut`, read only): the shortcut with a done symbol, "아직 지정하지
	/// 않았습니다", or a warning when pressing it would do nothing — the service switched off, or no preset starred (a
	/// shortcut alone is only half of the quick apply). One line, whatever the state.
	private var shortcutRow: some View {
		let state = guide.shortcut
		let starred = model.quickPreset != nil
		return shortcutLabel(state, starred: starred)
			.font(.callout)
			.lineLimit(1)
			.foregroundStyle(ShortcutStateText.isWarning(state, starred: starred) ? AnyShapeStyle(Theme.warning)
			                 : state == .notAssigned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
			.help(ShortcutStateText.help(state, starred: starred))
			.frame(maxWidth: .infinity, alignment: .leading)
			// The width the line wants: the only thing that shows it would be cut off (it never wraps).
			.background(alignment: .leading) {
				shortcutLabel(state, starred: starred).font(.callout).fixedSize().hidden().probeFrame("settingsShortcutIdeal")
			}
			.frame(height: 22)
			.accessibilityIdentifier("quickPresetShortcut")
			.probeFrame("settingsShortcut")
	}

	private func shortcutLabel(_ state: ServiceShortcutState, starred: Bool) -> some View {
		Label(ShortcutStateText.line(state, starred: starred), systemImage: ShortcutStateText.symbol(state, starred: starred))
	}

	/// The three-line note under the buttons: where the shortcut is set — or, when macOS has a shortcut that does
	/// nothing, what to do about it, so the remedy is on the screen and not only in the line's tooltip.
	private var quickCaption: String {
		switch guide.shortcut {
		case .switchedOff:
			String(localized: "서비스가 꺼져 있어 단축키가 작동하지 않습니다. \"설정 방법 보기…\"를 누르면 체크상자를 켜는 화면까지 안내합니다.")
		case .assigned where model.quickPreset == nil:
			String(localized: "별표한 프리셋이 없어 단축키를 눌러도 아무 일도 일어나지 않습니다. 프리셋 목록에서 쓸 프리셋의 별표를 누르세요.")
		case .assigned, .notAssigned:
			String(localized: "단축키는 시스템 설정 > 키보드 > 키보드 단축키 > 서비스의 \"\(FinderService.quickApply.localizedTitle)\"에 지정합니다(추천 ⌃⌥⌘P). 적용하면 Finder가 다시 시작되고 열려 있던 창이 다시 열립니다.")
		}
	}

	/// The starred preset's name, or how to star one. It has the window's width to itself (a long name is shortened in
	/// the middle, like in the preset list); the hidden `settingsQuickNameIdeal` copy beside it is what shows whether
	/// "없음 — …" would be cut off.
	@ViewBuilder private var quickPresetName: some View {
		if let preset = model.quickPreset {
			Label(preset.name, systemImage: "star.fill")
				.foregroundStyle(.primary)
		} else {
			Text("없음 — 목록에서 별표로 지정")
				.foregroundStyle(.secondary)
		}
	}

	/// The note (in use now / takes effect after a relaunch / why it cannot relaunch now) and "앱 다시 시작".
	private func relaunchRow(blocker: String?) -> some View {
		HStack(alignment: .center, spacing: 12) {
			Group {
				if pending {
					Label(blocker ?? String(localized: "다시 시작하면 적용됩니다."),
					      systemImage: blocker == nil ? "arrow.clockwise.circle" : "exclamationmark.triangle.fill")
						// The app's warning color (Theme.warning: readable on light backgrounds, unlike `.orange`).
						.foregroundStyle(blocker == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.warning))
				} else {
					Label("지금 이 언어로 표시하고 있습니다.", systemImage: "checkmark.circle")
						.foregroundStyle(.secondary)
				}
			}
			.font(.callout)
			.lineLimit(2)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
			.accessibilityIdentifier("languageNote")
			.probeFrame("settingsNote")
			Button("앱 다시 시작") {
				// Asked again at the press: the row is refreshed only every second.
				guard pending, self.blocker() == nil else { NSSound.beep(); return }
				AppRelaunch.relaunch(model: model)
			}
			.help("이 앱만 종료했다가 다시 엽니다. Finder는 다시 시작하지 않습니다.")
			.accessibilityIdentifier("relaunchApp")
			.disabled(!pending || blocker != nil)
			.fixedSize()
			.probeFrame("settingsRelaunch")
		}
	}
}

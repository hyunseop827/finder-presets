import Foundation
import Testing
@testable import FinderPresets

/// The Settings window's language choice (Views/LanguageSettings.swift): which choice stores which per-app
/// `AppleLanguages`, how a stored value reads back, when a relaunch is needed, and what "앱 다시 시작" passes on. Nothing
/// here touches a real defaults domain: the setting is given an in-memory store.
@Suite struct LanguageSettingTests {
	/// An in-memory stand-in for the app's defaults domain.
	final class Store: @unchecked Sendable {
		private let lock = NSLock()
		private var value: Any?
		private(set) var writes = 0
		init(_ value: Any? = nil) { self.value = value }
		var current: Any? { lock.withLock { value } }
		func setting(system: [String]) -> LanguageSetting {
			LanguageSetting(read: { self.current },
			                write: { new in self.lock.withLock { self.value = new; self.writes += 1 } },
			                systemLanguages: { system })
		}
	}

	@Test func eachChoiceStoresItsLanguageList() {
		#expect(LanguageChoice.system.appleLanguages(system: ["ko-KR"]) == nil)
		#expect(LanguageChoice.korean.appleLanguages(system: ["en-US"]) == ["ko"])
		#expect(LanguageChoice.english.appleLanguages(system: ["ko-KR"]) == ["en"])
		// The user's own variant of the language is kept (its dates and numbers follow it).
		#expect(LanguageChoice.english.appleLanguages(system: ["ko-KR", "en-GB", "en-US"]) == ["en-GB"])
		#expect(LanguageChoice.korean.appleLanguages(system: ["en-US", "ko-KR"]) == ["ko-KR"])
		#expect(LanguageChoice.korean.appleLanguages(system: ["en-US", "ko_KR"]) == ["ko_KR"])
		// A language that only starts with the same letters is not the same language.
		#expect(LanguageChoice.english.appleLanguages(system: ["eng", "ko"]) == ["en"])
	}

	@Test func storedValuesReadBackAsTheirChoice() {
		#expect(LanguageChoice.choice(stored: nil) == .system)
		#expect(LanguageChoice.choice(stored: [String]()) == .system)
		#expect(LanguageChoice.choice(stored: "en") == .system)   // not a list: macOS ignores it too
		#expect(LanguageChoice.choice(stored: ["en"]) == .english)
		#expect(LanguageChoice.choice(stored: ["en-GB"]) == .english)
		#expect(LanguageChoice.choice(stored: ["ko"]) == .korean)
		#expect(LanguageChoice.choice(stored: ["ko-KR"]) == .korean)
		// Set elsewhere (System Settings > Language & Region > Applications, `defaults write`): what the app then shows.
		#expect(LanguageChoice.choice(stored: ["ja", "en"]) == .english)
		#expect(LanguageChoice.choice(stored: ["ja"]) == .korean)   // the development region
	}

	@Test func bundleLanguageForPreferredLanguages() {
		#expect(LanguageChoice.localization(for: ["ko-KR", "en-US"]) == "ko")
		#expect(LanguageChoice.localization(for: ["en-GB", "ko-KR"]) == "en")
		#expect(LanguageChoice.localization(for: ["ja-JP", "en-US"]) == "en")
		#expect(LanguageChoice.localization(for: ["ja-JP"]) == "ko")
		#expect(LanguageChoice.localization(for: []) == "ko")
		#expect(LanguageChoice.system.resultingLocalization(system: ["en-US"]) == "en")
		#expect(LanguageChoice.korean.resultingLocalization(system: ["en-US"]) == "ko")
		#expect(LanguageChoice.english.resultingLocalization(system: ["ko-KR"]) == "en")
	}

	@Test func writingAndReadingTheChoice() {
		let store = Store()
		let setting = store.setting(system: ["ko-KR", "en-GB"])
		#expect(setting.choice == .system && !setting.needsRelaunch(current: "ko") && setting.needsRelaunch(current: "en"))

		setting.set(.english)
		#expect(store.current as? [String] == ["en-GB"] && setting.choice == .english)
		#expect(setting.needsRelaunch(current: "ko") && !setting.needsRelaunch(current: "en"))

		setting.set(.korean)
		#expect(store.current as? [String] == ["ko-KR"] && setting.choice == .korean)

		// "시스템 설정 따름" removes the key (nothing stored at all, not an empty list).
		setting.set(.system)
		#expect(store.current == nil && setting.choice == .system)
		#expect(store.writes == 3)
	}

	@Test func titles() {
		// Outside the app bundle the texts are their Korean keys; the language names are the same in both languages.
		#expect(LanguageChoice.system.title(system: ["en-US"]) == "시스템 설정 따름 (English)")
		#expect(LanguageChoice.system.title(system: ["ko-KR"]) == "시스템 설정 따름 (한국어)")
		#expect(LanguageChoice.korean.title(system: ["en-US"]) == "한국어")
		#expect(LanguageChoice.english.title(system: ["ko-KR"]) == "English")
	}

	@Test func relaunchIsRefusedWhileBusy() {
		#expect(AppRelaunch.blocker(working: false, writing: false, finderRunning: true, dialogOpen: false) == nil)
		#expect(AppRelaunch.blocker(working: true, writing: false, finderRunning: true, dialogOpen: false) != nil)
		#expect(AppRelaunch.blocker(working: false, writing: true, finderRunning: true, dialogOpen: false) != nil)
		// A task of this app has Finder quit: never quit meanwhile (QuitGuard), and never relaunch.
		#expect(AppRelaunch.blocker(working: false, writing: false, finderRunning: false, dialogOpen: false) != nil)
		#expect(AppRelaunch.blocker(working: false, writing: false, finderRunning: true, dialogOpen: true) != nil)
	}

	@Test func relaunchKeepsTheAppsEnvironmentOnly() {
		let env = AppRelaunch.environment(from: ["FINDER_PRESETS_DATA_DIR": "/tmp/iso data", "FINDER_PRESETS_APPEARANCE": "dark", "HOME": "/Users/x",
		                                         "PATH": "/bin", "DYLD_INSERT_LIBRARIES": "/x.dylib"], currentDirectory: "/repo")
		#expect(env == ["FINDER_PRESETS_DATA_DIR": "/tmp/iso data", "FINDER_PRESETS_APPEARANCE": "dark"])
		// A relative folder is the one this launch resolved against its working directory, passed on as an absolute path
		// (the new instance starts in "/"); an empty value stays empty (it means "the standard folder").
		#expect(AppRelaunch.environment(from: ["FINDER_PRESETS_DATA_DIR": "scratch/../data dir"], currentDirectory: "/repo")
		        == ["FINDER_PRESETS_DATA_DIR": "/repo/data dir"])
		#expect(AppRelaunch.environment(from: ["FINDER_PRESETS_DATA_DIR": ""], currentDirectory: "/repo") == ["FINDER_PRESETS_DATA_DIR": ""])
		#expect(AppRelaunch.openArguments(bundlePath: "/Apps/Finder Presets.app", environment: env)
		        == ["-n", "--env", "FINDER_PRESETS_APPEARANCE=dark", "--env", "FINDER_PRESETS_DATA_DIR=/tmp/iso data", "/Apps/Finder Presets.app"])
		#expect(AppRelaunch.openArguments(bundlePath: "/A.app", environment: [:]) == ["-n", "/A.app"])
	}

	/// The waiting shell really waits for the process to exit, then runs its command with the arguments as given (spaces
	/// kept). `open` is replaced by `printf` (one argument per `|`) through a copy of the script, so nothing is opened.
	@Test func waitingShellWaitsThenRuns() throws {
		let script = AppRelaunch.waitThenOpen.replacingOccurrences(of: "exec /usr/bin/open", with: "exec /usr/bin/printf '%s|'")
		#expect(script != AppRelaunch.waitThenOpen)
		let sleeper = Process()
		sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
		sleeper.arguments = ["0.5"]
		try sleeper.run()
		let start = Date()
		let shell = Process()
		shell.executableURL = URL(fileURLWithPath: "/bin/sh")
		shell.arguments = ["-c", script, "sh", String(sleeper.processIdentifier), "-n", "--env", "FINDER_PRESETS_DATA_DIR=/a b", "/X.app"]
		let out = Pipe()
		shell.standardOutput = out
		try shell.run()
		// Reap the sleeper so `kill -0` stops finding it.
		sleeper.waitUntilExit()
		let data = out.fileHandleForReading.readDataToEndOfFile()
		shell.waitUntilExit()
		#expect(shell.terminationStatus == 0)
		#expect(Date().timeIntervalSince(start) >= 0.4)
		#expect(String(decoding: data, as: UTF8.self) == "-n|--env|FINDER_PRESETS_DATA_DIR=/a b|/X.app|")
	}
}

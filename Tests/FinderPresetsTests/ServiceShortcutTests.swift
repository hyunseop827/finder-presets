import Foundation
import Testing
@testable import FinderPresets

/// The keyboard shortcut macOS keeps for the quick preset's service (ServiceShortcut.swift): which entry of
/// `NSServicesStatus` is ours, how a `key_equivalent` is worded, and when a shortcut is there but switched off.
///
/// Dictionaries in memory only. The real `pbs` domain (and any other domain, the real home folder and the user's data) is
/// never read: `state(in:bundleID:)` is given the dictionary, and a reader is injected where one is needed.
@Suite struct ServiceShortcutTests {
	static let bundleID = "com.hyunseop.FinderPresets"
	/// The key macOS writes for our service: "<bundle identifier> - <English menu title> - <NSMessage>".
	static var entryKey: String { "\(bundleID) - \(FinderService.quickApply.englishTitle) - \(FinderService.quickApply.message)" }

	/// What `~/Library/Preferences/pbs.plist` held on the machine this was written for (the lead read it), beside another
	/// app's entry of the same shape.
	static func realWorldStatus() -> [String: Any] {
		["com.hyunseop.FinderPresets - Apply Quick Preset to Front Finder Window - applyQuickPreset": ["key_equivalent": "@~^p"],
		 "com.apple.Safari - Search With %WebSearchProvider@ - searchWithWebSearchProvider": ["key_equivalent": "@$l"],
		 "com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder": ["key_equivalent": "", "enabled_context_menu": 0]]
	}

	static func state(_ status: [String: Any]?, bundleID: String = Self.bundleID) -> ServiceShortcutState {
		ServiceShortcut.state(in: status, bundleID: bundleID)
	}

	/// The real entry of this machine, the one string the whole feature hangs on.
	@Test func theRealWorldEntryReadsAsControlOptionCommandP() {
		#expect(Self.state(Self.realWorldStatus()) == .assigned("⌃⌥⌘P"))
		#expect(ServiceShortcut.entryKey(in: Self.realWorldStatus(), bundleID: Self.bundleID) == Self.entryKey)
		// Read with an injected reader, exactly as the Settings window reads it (never the real domain).
		let reader = ServiceShortcut(bundleID: Self.bundleID, readStatus: { Self.realWorldStatus() })
		#expect(reader.state == .assigned("⌃⌥⌘P"))
		#expect(ServiceShortcut.domain == "pbs" && ServiceShortcut.statusKey == "NSServicesStatus")
	}

	/// Every modifier character, in the order macOS shows them whatever order the value has them in, and the key itself:
	/// a letter in capitals, a number, punctuation and the keys that are not characters.
	@Test func everyModifierAndKey() {
		#expect(ServiceShortcut.display("^a") == "⌃A")
		#expect(ServiceShortcut.display("~a") == "⌥A")
		#expect(ServiceShortcut.display("$a") == "⇧A")
		#expect(ServiceShortcut.display("@a") == "⌘A")
		#expect(ServiceShortcut.display("@p") == "⌘P")          // one modifier and the key alone
		#expect(ServiceShortcut.display("@~^$p") == "⌃⌥⇧⌘P")
		#expect(ServiceShortcut.display("$^@~p") == "⌃⌥⇧⌘P")    // the value's own order changes nothing
		#expect(ServiceShortcut.display("@1") == "⌘1")
		#expect(ServiceShortcut.display("^~@/") == "⌃⌥⌘/")
		#expect(ServiceShortcut.display("@-") == "⌘-")
		#expect(ServiceShortcut.display("@=") == "⌘=")          // a sign, which Unicode does not call punctuation
		#expect(ServiceShortcut.display("@\u{F704}") == "⌘F1")
		#expect(ServiceShortcut.display("^\u{F717}") == "⌃F20")
		#expect(ServiceShortcut.display("@\u{F702}") == "⌘←")
		#expect(ServiceShortcut.display("@\u{0D}") == "⌘↩")
		#expect(ServiceShortcut.display("@ ") == "⌘␣")
		#expect(ServiceShortcut.modifierCharacters.count == 4)
	}

	/// An uppercase letter means Shift as well, whether or not the value says "$" too.
	@Test func anUppercaseKeyMeansShift() {
		#expect(ServiceShortcut.display("@P") == "⇧⌘P")
		#expect(ServiceShortcut.display("$@P") == "⇧⌘P")
		#expect(ServiceShortcut.display("@~^P") == "⌃⌥⇧⌘P")
		#expect(ServiceShortcut.display("$@p") == "⇧⌘P")
	}

	/// A value the app cannot word is reported as "not assigned", never as a box or half a shortcut: no key after the
	/// modifiers, more than one key, a key that is no letter, number, punctuation mark or sign.
	@Test func aMalformedValueMeansNotAssigned() {
		for value in ["", "@", "@~^$", "@ab", "abc", "@\u{0001}", "@\u{200B}"] {
			#expect(ServiceShortcut.display(value) == nil, "\(value.debugDescription)")
			#expect(Self.state([Self.entryKey: ["key_equivalent": value]]) == .notAssigned, "\(value.debugDescription)")
		}
		// Not a string at all, or no shortcut in the entry.
		#expect(Self.state([Self.entryKey: ["key_equivalent": 5]]) == .notAssigned)
		#expect(Self.state([Self.entryKey: ["enabled_services_menu": 1]]) == .notAssigned)
		#expect(Self.state([Self.entryKey: "@p"]) == .notAssigned)
	}

	/// No entry for our service: an empty domain, no value at all, another app's entry, and the same app's other services.
	@Test func aMissingEntryMeansNotAssigned() {
		#expect(Self.state(nil) == .notAssigned)
		#expect(Self.state([:]) == .notAssigned)
		#expect(ServiceShortcut.entryKey(in: [:], bundleID: Self.bundleID) == nil)
		// Another app's service with the same message, and our app's three other services.
		var others: [String: Any] = ["com.example.Other - Apply Quick Preset to Front Finder Window - applyQuickPreset": ["key_equivalent": "@p"]]
		for service in FinderService.allCases where service != .quickApply {
			others["\(Self.bundleID) - \(service.englishTitle) - \(service.message)"] = ["key_equivalent": "@$k"]
		}
		#expect(Self.state(others) == .notAssigned)
		// Our entry with an empty title part is not an entry of ours either (the shape must hold).
		#expect(Self.state(["\(Self.bundleID) -  - \(FinderService.quickApply.message)": ["key_equivalent": "@p"]]) == .notAssigned)
		// Without a bundle identifier (outside an app bundle) nothing matches.
		#expect(Self.state(Self.realWorldStatus(), bundleID: "") == .notAssigned)
	}

	/// The entry is matched by the bundle identifier and the `NSMessage`, so a menu title that changed (a renamed item, a
	/// title macOS wrote in another language) still matches; several matching entries always give the same one.
	@Test func theEntryIsMatchedWithoutItsTitle() {
		let renamed = "\(Self.bundleID) - Quick Preset (renamed) - \(FinderService.quickApply.message)"
		#expect(Self.state([renamed: ["key_equivalent": "@~^p"]]) == .assigned("⌃⌥⌘P"))
		let several: [String: Any] = [renamed: ["key_equivalent": "@k"],
		                              Self.entryKey: ["key_equivalent": "@j"],
		                              "\(Self.bundleID) - Zzz - \(FinderService.quickApply.message)": ["key_equivalent": "@l"]]
		// Sorted keys: "…- Apply Quick Preset…" comes before "…- Quick Preset (renamed)…" and "…- Zzz…".
		#expect(ServiceShortcut.entryKey(in: several, bundleID: Self.bundleID) == Self.entryKey)
		#expect(Self.state(several) == .assigned("⌘J"))
	}

	/// The check box of 키보드 단축키 > 서비스: 0 switches the service off, so its shortcut does nothing; anything else and
	/// no switch at all leave it on. Finder's context-menu switch says nothing about the shortcut.
	@Test func aSwitchedOffServiceKeepsItsShortcutButIsAWarning() {
		func status(_ entry: [String: Any]) -> [String: Any] { [Self.entryKey: entry] }
		#expect(Self.state(status(["key_equivalent": "@~^p", "enabled_services_menu": 0])) == .switchedOff("⌃⌥⌘P"))
		#expect(Self.state(status(["key_equivalent": "@~^p", "enabled_services_menu": 1])) == .assigned("⌃⌥⌘P"))
		#expect(Self.state(status(["key_equivalent": "@~^p", "enabled_services_menu": false])) == .switchedOff("⌃⌥⌘P"))
		#expect(Self.state(status(["key_equivalent": "@~^p"])) == .assigned("⌃⌥⌘P"))
		// Switched off in Finder's right-click menu only: the shortcut still works.
		#expect(Self.state(status(["key_equivalent": "@~^p", "enabled_context_menu": 0])) == .assigned("⌃⌥⌘P"))
		// An entry macOS wrote without the switch is on, which is how a service the user has never touched in the keyboard
		// settings reads: the walkthrough's ④ therefore asks the user to look at that check box, not to switch it on.
		#expect(ServiceShortcut.isOn(nil) && ServiceShortcut.isOn("x") && !ServiceShortcut.isOn(0))
		#expect(Self.state(Self.realWorldStatus()) == .assigned("⌃⌥⌘P"))   // the real entry has no `enabled_services_menu`
		// The switched-off state is worded as a warning.
		#expect(ShortcutStateText.isWarning(.switchedOff("⌃⌥⌘P"), starred: true))
		#expect(!ShortcutStateText.isWarning(.assigned("⌃⌥⌘P"), starred: true))
		#expect(!ShortcutStateText.isWarning(.notAssigned, starred: true) && !ShortcutStateText.isWarning(.notAssigned, starred: false))
	}

	/// A shortcut is only half of the quick apply: without a starred preset, pressing it can only bring up a refusal
	/// (QuickPreset.swift), so the Settings window's line and the walkthrough's last step say so instead of showing a done
	/// symbol. While no shortcut is assigned the star is not the next move, so that line says nothing about it.
	@MainActor @Test func aShortcutWithoutAStarredPresetIsAWarningToo() {
		#expect(ShortcutStateText.isWarning(.assigned("⌃⌥⌘P"), starred: false))
		#expect(ShortcutStateText.symbol(.assigned("⌃⌥⌘P"), starred: false) == "exclamationmark.triangle.fill")
		#expect(ShortcutStateText.symbol(.assigned("⌃⌥⌘P"), starred: true) == "checkmark.circle")
		#expect(ShortcutStateText.symbol(.notAssigned, starred: false) == "keyboard")
		let line = ShortcutStateText.line(.assigned("⌃⌥⌘P"), starred: false)
		#expect(line.contains("⌃⌥⌘P") && line != ShortcutStateText.line(.assigned("⌃⌥⌘P"), starred: true))
		#expect(ShortcutStateText.help(.assigned("⌃⌥⌘P"), starred: false) != ShortcutStateText.help(.assigned("⌃⌥⌘P"), starred: true))
		// Without a shortcut the wording does not change with the star.
		#expect(ShortcutStateText.line(.notAssigned, starred: false) == ShortcutStateText.line(.notAssigned, starred: true))
		// "설정 방법 보기…" opens the walkthrough where the state can be mended: ④ for the check box, the last step for the
		// star, the beginning otherwise.
		let last = ShortcutGuideSheet.steps.count - 1
		#expect(ShortcutStateText.step(for: .switchedOff("⌃⌥⌘P"), starred: true) == 3)
		#expect(ShortcutStateText.step(for: .assigned("⌃⌥⌘P"), starred: false) == last)
		#expect(ShortcutStateText.step(for: .assigned("⌃⌥⌘P"), starred: true) == 0)
		#expect(ShortcutStateText.step(for: .notAssigned, starred: false) == 0)
	}

	// MARK: The walkthrough moves only when asked

	/// "단축키 설정 방법" is a plain step-by-step sheet: the step changes through `open(at:)` (where "설정 방법 보기…"
	/// opens it), `go(to:)`, `next()` and `previous()` only, always within the six steps. "다음" on the last step and
	/// "이전" on the first change nothing (the sheet disables both buttons there, from `isLast` / `isFirst`), closing
	/// keeps the step, and the state is read through the injected reader (never the real `pbs` domain).
	@MainActor @Test func theWalkthroughMovesOnlyThroughItsButtons() async {
		let guide = ShortcutGuide(readState: { .switchedOff("⌃⌥⌘P") })
		let last = ShortcutGuideSheet.steps.count - 1
		#expect(guide.step == 0 && guide.isFirst && !guide.isLast && !guide.isOpen && guide.shortcut == .notAssigned)
		// "설정 방법 보기…" for a service that is switched off opens on ④, the step with the check box.
		guide.open(at: ShortcutStateText.step(for: .switchedOff("⌃⌥⌘P"), starred: true))
		#expect(guide.isOpen && guide.step == 3 && guide.shortcut == .switchedOff("⌃⌥⌘P"))
		// Left alone, it stays where it is: nothing is scheduled that could carry it on.
		for _ in 0..<20 { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(50))
		#expect(guide.step == 3 && guide.isOpen)
		guide.next()
		#expect(guide.step == 4)
		guide.next()
		#expect(guide.step == last && guide.isLast && !guide.isFirst)
		guide.next()   // "다음" on the last step: nothing (never back to the first)
		#expect(guide.step == last)
		guide.previous()
		#expect(guide.step == last - 1)
		guide.go(to: 0)
		#expect(guide.step == 0 && guide.isFirst)
		guide.previous()   // "이전" on the first step: nothing
		#expect(guide.step == 0)
		guide.go(to: 99)
		#expect(guide.step == last)
		guide.go(to: -3)
		#expect(guide.step == 0)
		guide.go(to: 2)
		guide.close()
		#expect(!guide.isOpen && guide.step == 2)
		guide.open(at: 99)
		#expect(guide.isOpen && guide.step == last)
		guide.open(at: -1)
		#expect(guide.step == 0)
		guide.open()
		#expect(guide.step == 0)
	}

	/// There is nothing in the model that could advance the walkthrough by itself: it holds whether the sheet is open, the
	/// step, the shortcut state and the reader of that state — no timer, no task, no play state (the sheet once played
	/// like a short video; it now moves only with "이전"·"다음" and ← →).
	@MainActor @Test func theWalkthroughHasNoTimer() {
		let guide = ShortcutGuide(readState: { .notAssigned })
		// `@Observable` keeps a tracked property `x` as `_x`, beside its `_$observationRegistrar`.
		let stored = Set(Mirror(reflecting: guide).children.compactMap { child -> String? in
			guard let label = child.label, label != "_$observationRegistrar" else { return nil }
			return label.hasPrefix("_") ? String(label.dropFirst()) : label
		})
		#expect(stored == ["isOpen", "step", "shortcut", "readState"])
		#expect(!Mirror(reflecting: guide).children.contains { $0.value is Timer || String(describing: type(of: $0.value)).contains("Task<") })
	}

	/// `status(keyEquivalent:…)` builds what macOS writes, so the development hooks and these tests speak the same shape.
	@Test func theBuiltStatusMatchesTheRealOne() {
		let built = ServiceShortcut.status(keyEquivalent: "@~^p", bundleID: Self.bundleID)
		#expect(built.keys.sorted() == [Self.entryKey])
		#expect(Self.state(built) == .assigned("⌃⌥⌘P"))
		#expect(Self.state(ServiceShortcut.status(keyEquivalent: "@~^p", bundleID: Self.bundleID, servicesMenu: 0)) == .switchedOff("⌃⌥⌘P"))
		// The three states word themselves, and only the assigned one with a starred preset shows the "done" symbol.
		#expect(ShortcutStateText.symbol(.assigned("⌘P"), starred: true) == "checkmark.circle")
		#expect(ShortcutStateText.line(.assigned("⌘P"), starred: true).contains("⌘P"))
		#expect(ShortcutStateText.line(.switchedOff("⌘P"), starred: true).contains("⌘P"))
		#expect(!ShortcutStateText.line(.notAssigned, starred: true).isEmpty)
		#expect(!ShortcutStateText.help(.notAssigned, starred: true).isEmpty)
	}
}

import Foundation
import AppKit

// The keyboard shortcut of the quick preset's service (QuickPreset.swift), READ ONLY. macOS owns it, not the app: the user
// gives the service a shortcut in System Settings > 키보드 > "키보드 단축키…" > 서비스, and macOS writes it into its own
// `pbs` preference domain (~/Library/Preferences/pbs.plist) under `NSServicesStatus`, one entry per service:
//
//   "com.hyunseop.FinderPresets - Apply Quick Preset to Front Finder Window - applyQuickPreset" = { "key_equivalent" = "@~^p"; };
//
// so the key of an entry is "<CFBundleIdentifier> - <the NSMenuItem `default` title of Info.plist, in English> - <NSMessage>",
// `key_equivalent` is the shortcut (@ Command, ~ Option, ^ Control, $ Shift, then the key: "@~^p" is ⌃⌥⌘P), and the entry
// can also carry "enabled_services_menu" / "enabled_context_menu" (0: switched off in the keyboard settings; absent: on).
//
// Reading it is what lets the Settings window and the walkthrough (Views/ShortcutGuideSheet.swift) say whether a shortcut
// is there, instead of only telling the user where to set one. The app NEVER writes `pbs` or any other domain of the
// system: a shortcut belongs to the user, and the app changes no macOS setting. `Info.plist` cannot bring a shortcut of
// its own either (`NSKeyEquivalent` can only be ⌘ or ⌘⇧ with a key, which Finder and other apps already use).
//
// The reader is injected (`readStatus`), so the unit tests, `--selftest` and `--layout-probe` work on a dictionary in
// memory and never look at the real domain.

/// What macOS has done with the quick preset's service, as the Settings window and the walkthrough show it.
enum ServiceShortcutState: Equatable, Sendable {
	/// No shortcut: no entry for the service, no `key_equivalent` in it, or one that cannot be read (see
	/// `ServiceShortcut.display(_:)` — a value the app cannot word is reported as "not assigned", never as nonsense).
	case notAssigned
	/// The shortcut the user gave it, ready to show ("⌃⌥⌘P").
	case assigned(String)
	/// A shortcut is there, but the service itself is switched off in 키보드 단축키 > 서비스, so pressing it does nothing.
	case switchedOff(String)
}

/// Reads the shortcut macOS keeps for the quick preset's service. Nothing here writes.
struct ServiceShortcut: Sendable {
	/// macOS's own domain for the services (`~/Library/Preferences/pbs.plist`), and the keys inside it.
	static let domain = "pbs"
	static let statusKey = "NSServicesStatus"
	static let keyEquivalentKey = "key_equivalent"
	/// The check box of 키보드 단축키 > 서비스 (0: the service is switched off). "enabled_context_menu" is Finder's
	/// right-click menu and says nothing about the shortcut, so it is not read.
	static let servicesMenuKey = "enabled_services_menu"

	/// The app's bundle identifier, the first part of an entry's key.
	var bundleID: String
	/// `NSServicesStatus` of the `pbs` domain, or nil when it cannot be read.
	var readStatus: @Sendable () -> [String: Any]?

	/// What macOS has for our service right now (the domain is read again for every look).
	var state: ServiceShortcutState { Self.state(in: readStatus(), bundleID: bundleID) }

	/// The app's own reader. `CFPreferences` rather than `UserDefaults`: the user assigns the shortcut in System Settings
	/// while this app runs, and `UserDefaults` would keep handing back the value it read first. `CFPreferencesAppSynchronize`
	/// drops what CFPreferences cached for the domain (this process never sets anything in it, so nothing is written).
	static let standard = ServiceShortcut(bundleID: Bundle.main.bundleIdentifier ?? "", readStatus: {
		CFPreferencesAppSynchronize(domain as CFString)
		return CFPreferencesCopyAppValue(statusKey as CFString, domain as CFString) as? [String: Any]
	})

	/// The reader of this launch: the development hooks read a dictionary in memory, so a `--selftest` or `--layout-probe`
	/// run never reads a domain of the system.
	@MainActor static var forThisLaunch: ServiceShortcut {
		#if DEBUG
		if SelfTest.isRequested || LayoutProbe.isRequested {
			return ServiceShortcut(bundleID: Bundle.main.bundleIdentifier ?? "", readStatus: { Development.shared.status })
		}
		#endif
		return standard
	}

	// MARK: Reading the dictionary

	/// The state for an `NSServicesStatus` dictionary: nil (no such value in the domain) is "not assigned", like an entry
	/// without a shortcut.
	static func state(in status: [String: Any]?, bundleID: String) -> ServiceShortcutState {
		guard let status, let key = entryKey(in: status, bundleID: bundleID), let entry = status[key] as? [String: Any],
		      let value = entry[keyEquivalentKey] as? String, let shown = display(value) else { return .notAssigned }
		return isOn(entry[servicesMenuKey]) ? .assigned(shown) : .switchedOff(shown)
	}

	/// The entry macOS keeps for the quick preset's service. Matched by the bundle identifier and the `NSMessage` only, so
	/// a changed menu title (or a translated one, should macOS ever write it) still matches; the keys are visited in a
	/// stable order, so several matching entries always give the same one.
	static func entryKey(in status: [String: Any], bundleID: String) -> String? {
		guard !bundleID.isEmpty else { return nil }
		let prefix = bundleID + " - ", suffix = " - " + FinderService.quickApply.message
		return status.keys.sorted().first { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }
	}

	/// A switch of an entry: 0 switches it off; anything else, and no switch at all, leaves it on.
	static func isOn(_ value: Any?) -> Bool {
		guard let value else { return true }
		if let number = value as? NSNumber { return number.intValue != 0 }
		return true
	}

	// MARK: Wording a key equivalent

	static let modifierCharacters: [Character: String] = ["^": "⌃", "~": "⌥", "$": "⇧", "@": "⌘"]

	/// The keys that are not characters, as macOS shows them in a menu. Language-neutral glyphs and "F1"–"F20", so
	/// nothing here needs translating (macOS stores these keys as control characters and in the private use area).
	static let specialKeys: [Character: String] = {
		var table: [Character: String] = ["\u{09}": "⇥", "\u{0D}": "↩", "\u{03}": "⌤", "\u{08}": "⌫", "\u{7F}": "⌫",
		                                  "\u{1B}": "⎋", " ": "␣", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←",
		                                  "\u{F703}": "→", "\u{F728}": "⌦", "\u{F729}": "↖", "\u{F72B}": "↘",
		                                  "\u{F72C}": "⇞", "\u{F72D}": "⇟"]
		for number in 1...20 {
			if let scalar = Unicode.Scalar(0xF703 + number) { table[Character(scalar)] = "F\(number)" }
		}
		return table
	}()

	/// A `key_equivalent` in the order macOS writes a menu's shortcut: ⌃ ⌥ ⇧ ⌘, then the key, a letter in capitals
	/// ("@~^p" → "⌃⌥⌘P"). An uppercase letter means Shift as well, whether or not "$" is there ("@P" → "⇧⌘P").
	///
	/// Nil (the Settings window then says that nothing is assigned) when the value cannot be worded: no key after the
	/// modifiers, more than one character left, or a key that is neither one of `specialKeys` nor a letter, number,
	/// punctuation mark or sign. Showing a box for a key this app does not know would say less than "not assigned".
	static func display(_ keyEquivalent: String) -> String? {
		var found: Set<Character> = []
		var rest = Substring(keyEquivalent)
		while let first = rest.first, modifierCharacters[first] != nil {
			found.insert(first)
			rest = rest.dropFirst()
		}
		guard rest.count == 1, let key = rest.first, let glyph = keyGlyph(key) else { return nil }
		if key.isUppercase { found.insert("$") }
		// The macOS order, whatever order the value has them in.
		return "^~$@".compactMap { found.contains($0) ? modifierCharacters[$0] : nil }.joined() + glyph
	}

	/// The key itself: a letter in capitals (a menu shows ⌘P for the stored "p"), a number, punctuation mark or sign as it
	/// is, the glyph of a key that is not a character. Nil for anything else.
	static func keyGlyph(_ key: Character) -> String? {
		if let special = specialKeys[key] { return special }
		guard key.isLetter || key.isNumber || key.isPunctuation || key.isSymbol else { return nil }
		return key.isLetter ? key.uppercased() : String(key)
	}

	// MARK: For the tests and the development hooks

	/// A status dictionary like the one macOS writes, with one entry for the quick preset's service.
	/// `servicesMenu`: the check box of 키보드 단축키 > 서비스 (nil: no switch in the entry, which means on).
	static func status(keyEquivalent: String, bundleID: String, title: String = FinderService.quickApply.englishTitle,
	                   message: String = FinderService.quickApply.message, servicesMenu: Int? = nil) -> [String: Any] {
		var entry: [String: Any] = [keyEquivalentKey: keyEquivalent]
		if let servicesMenu { entry[servicesMenuKey] = servicesMenu }
		return ["\(bundleID) - \(title) - \(message)": entry]
	}

	#if DEBUG
	/// What `--selftest` and `--layout-probe` read instead of the real `pbs` domain (a development run reads no domain of
	/// the system). The layout probe puts each state in it in turn.
	final class Development: @unchecked Sendable {
		static let shared = Development()
		private let lock = NSLock()
		private var value: [String: Any]?

		var status: [String: Any]? {
			get { lock.withLock { value } }
			set { lock.withLock { value = newValue } }
		}
	}
	#endif
}

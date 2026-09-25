import Foundation

/// The two Finder defaults this app touches, captured verbatim so an undo can put them back exactly.
/// `nil` means the key was absent from the domain.
public struct GlobalSnapshot: Codable, Equatable, Sendable {
	/// `FXPreferredViewStyle`: `icnv` / `Nlsv` / `clmv` / `glyv`.
	public var preferredViewStyle: String?
	/// `StandardViewSettings` serialized as a binary plist (types preserved as CFPreferences returned them).
	public var standardViewSettings: Data?
	public var takenAt: Date

	public init(preferredViewStyle: String?, standardViewSettings: Data?, takenAt: Date = Date()) {
		self.preferredViewStyle = preferredViewStyle
		self.standardViewSettings = standardViewSettings
		self.takenAt = takenAt
	}

	public var standardViewSettingsDictionary: [String: Any]? {
		standardViewSettings.flatMap(ViewRecordCodec.plist(from:))
	}

	/// Value comparison. The binary plist bytes are not stable across serializations (key order), so `==` is not enough.
	public func hasSameValues(as other: GlobalSnapshot) -> Bool {
		guard preferredViewStyle == other.preferredViewStyle else { return false }
		switch (standardViewSettingsDictionary, other.standardViewSettingsDictionary) {
		case (nil, nil): return true
		case let (a?, b?): return (a as NSDictionary).isEqual(b as NSDictionary)
		default: return false
		}
	}

	/// The properties this app understands, decoded from the snapshot (nil where the domain has no value).
	public var decodedSettings: ViewSettings {
		GlobalDefaultsWriter.decode(viewStyle: preferredViewStyle, standardViewSettings: standardViewSettingsDictionary)
	}
}

public enum GlobalDefaultsError: Error, LocalizedError, Sendable {
	case synchronizeFailed(String)
	case corruptSnapshot

	public var errorDescription: String? {
		switch self {
		case .synchronizeFailed(let domain): "기본값을 디스크에 기록하지 못했습니다 (\(domain))"
		case .corruptSnapshot: "저장된 전역 설정 스냅샷을 읽을 수 없어 복원을 중단했습니다"
		}
	}
}

/// Reads and writes Finder's global view defaults through CFPreferences.
///
/// A running Finder keeps these values in memory and writes them back on quit, so a caller must
/// quit Finder before `write`/`restore` and launch it afterwards (see `GlobalApplier`). Every function
/// takes the domain explicitly so tests can use a throwaway domain instead of `finderDomain`.
public enum GlobalDefaultsWriter {
	public static let finderDomain = "com.apple.finder"
	public static let viewStyleKey = "FXPreferredViewStyle"
	public static let standardViewSettingsKey = "StandardViewSettings"
	static let iconSectionKey = "IconViewSettings"
	static let listArraySectionKey = "ExtendedListViewSettingsV2"   // `columns` as an array (like lsvC)
	static let listDictSectionKey = "ListViewSettings"              // `columns` as a dictionary (like lsvp)

	// MARK: Read

	public static func readViewStyle(domain: String) -> String? {
		CFPreferencesCopyAppValue(viewStyleKey as CFString, domain as CFString) as? String
	}

	public static func readStandardViewSettings(domain: String) -> [String: Any]? {
		CFPreferencesCopyAppValue(standardViewSettingsKey as CFString, domain as CFString) as? [String: Any]
	}

	/// Captures the domain's current values as they are (no type sanitizing) for a later `restore`.
	public static func snapshot(domain: String) -> GlobalSnapshot {
		let dict = readStandardViewSettings(domain: domain)
		return GlobalSnapshot(preferredViewStyle: readViewStyle(domain: domain),
		                      standardViewSettings: dict.flatMap { try? ViewRecordCodec.data(from: $0) })
	}

	/// Decodes the managed properties from raw domain values (string-typed numbers accepted).
	public static func decode(viewStyle: String?, standardViewSettings svs: [String: Any]?) -> ViewSettings {
		var out = ViewSettings(viewStyle: viewStyle.flatMap(ViewStyle.init(rawValue:)))
		if let icon = svs?[iconSectionKey] as? [String: Any] {
			out.icon = ViewRecordCodec.decodeIcon(ViewRecordCodec.sanitizeIconPlist(icon))
		}
		if let list = (svs?[listArraySectionKey] as? [String: Any]) ?? (svs?[listDictSectionKey] as? [String: Any]) {
			out.list = ViewRecordCodec.decodeList(ViewRecordCodec.sanitizeListPlist(list))
		}
		return out
	}

	// MARK: Plan

	/// Merges the non-nil fields of `settings` into the three sections this app manages, key by key.
	/// Sections and keys the settings do not mention are returned as they are in `current`; the touched
	/// sections are type-sanitized first because CFPreferences may hand Finder's numbers back as strings.
	/// A nil `viewStyle` in the result means "leave `FXPreferredViewStyle` alone".
	public static func plannedValues(for settings: ViewSettings, current: [String: Any]?) -> (viewStyle: String?, standardViewSettings: [String: Any]) {
		var svs = current ?? [:]
		if !settings.icon.isEmpty {
			let existing = (svs[iconSectionKey] as? [String: Any]).map(ViewRecordCodec.sanitizeIconPlist)
			svs[iconSectionKey] = ViewRecordCodec.mergeIcon(settings.icon, into: existing, base: ViewRecordCodec.factoryIconPlist)
		}
		if !settings.list.isEmpty {
			// Finder keeps the list options twice (array-form and dict-form columns). When one section is missing,
			// it is created from the other one — never from the factory values — so both sections describe the same
			// list view (the same rule the reader and StoreEditor use).
			let existingArray = (svs[listArraySectionKey] as? [String: Any]).map(ViewRecordCodec.sanitizeListPlist)
			let existingDict = (svs[listDictSectionKey] as? [String: Any]).map(ViewRecordCodec.sanitizeListPlist)
			var arrayBase = ViewRecordCodec.factoryListPlist
			if existingArray == nil, let dict = existingDict {
				arrayBase = dict
				if let cols = dict["columns"] as? [String: [String: Any]] { arrayBase["columns"] = ViewRecordCodec.arrayColumns(fromDict: cols) }
			}
			let mergedArray = ViewRecordCodec.mergeList(settings.list, into: existingArray, base: arrayBase)
			svs[listArraySectionKey] = mergedArray
			svs[listDictSectionKey] = ViewRecordCodec.mergeList(settings.list, into: existingDict, base: ViewRecordCodec.dictForm(ofList: mergedArray))
		}
		return (settings.viewStyle?.rawValue, svs)
	}

	// MARK: Write

	/// Writes the values and synchronizes the domain. `viewStyle == nil` leaves `FXPreferredViewStyle` untouched;
	/// an empty dictionary leaves `StandardViewSettings` untouched (never wipes Finder's settings by accident).
	/// Finder must not be running while this is called.
	public static func write(viewStyle: String?, standardViewSettings: [String: Any], domain: String) throws {
		let app = domain as CFString
		if let viewStyle {
			CFPreferencesSetAppValue(viewStyleKey as CFString, viewStyle as NSString, app)
		}
		if !standardViewSettings.isEmpty {
			CFPreferencesSetAppValue(standardViewSettingsKey as CFString, standardViewSettings as NSDictionary, app)
		}
		guard CFPreferencesAppSynchronize(app) else { throw GlobalDefaultsError.synchronizeFailed(domain) }
	}

	/// Puts both keys back exactly as the snapshot recorded them; a nil value removes the key.
	/// Finder must not be running while this is called.
	public static func restore(_ snapshot: GlobalSnapshot, domain: String) throws {
		let app = domain as CFString
		var dict: NSDictionary?
		if let data = snapshot.standardViewSettings {
			// A snapshot that has data which cannot be parsed must never turn into "remove the key".
			guard let parsed = ViewRecordCodec.plist(from: data) else { throw GlobalDefaultsError.corruptSnapshot }
			dict = parsed as NSDictionary
		}
		CFPreferencesSetAppValue(viewStyleKey as CFString, snapshot.preferredViewStyle.map { $0 as NSString }, app)
		CFPreferencesSetAppValue(standardViewSettingsKey as CFString, dict, app)
		guard CFPreferencesAppSynchronize(app) else { throw GlobalDefaultsError.synchronizeFailed(domain) }
	}
}

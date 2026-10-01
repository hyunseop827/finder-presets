import Foundation

/// Read-only access to Finder's global view defaults (`com.apple.finder`).
public struct GlobalDefaults: @unchecked Sendable {
	public var preferredViewStyle: ViewStyle?
	public var iconPlist: [String: Any]
	public var listArrayPlist: [String: Any]

	public init(preferredViewStyle: ViewStyle? = nil,
	            iconPlist: [String: Any] = ViewRecordCodec.factoryIconPlist,
	            listArrayPlist: [String: Any] = ViewRecordCodec.factoryListPlist) {
		self.preferredViewStyle = preferredViewStyle
		self.iconPlist = iconPlist
		self.listArrayPlist = listArrayPlist
	}

	/// The effective settings a folder without explicit records gets. No grouping: whether Finder shows a folder without a
	/// `GRP0` record with its global `FXPreferredGroupBy` is unverified, so a preset's grouping is compared
	/// with the folder's own record only, and written to every folder that does not hold it yet.
	public var effectiveSettings: ViewSettings {
		ViewSettings(viewStyle: preferredViewStyle, icon: ViewRecordCodec.decodeIcon(iconPlist), list: ViewRecordCodec.decodeList(listArrayPlist))
	}

	public var recordBases: RecordBases {
		RecordBases(icon: iconPlist, listArray: listArrayPlist)
	}

	public static let factory = GlobalDefaults()

	/// Reads the current user's Finder defaults. Never writes.
	public static func readCurrent() -> GlobalDefaults {
		typealias W = GlobalDefaultsWriter
		guard let d = UserDefaults(suiteName: W.finderDomain) else { return .factory }
		return GlobalDefaults(viewStyle: d.string(forKey: W.viewStyleKey), standardViewSettings: d.dictionary(forKey: W.standardViewSettingsKey))
	}

	/// The defaults the domain's two values describe (string-typed numbers accepted), on top of Finder's factory values.
	init(viewStyle: String?, standardViewSettings svs: [String: Any]?) {
		typealias W = GlobalDefaultsWriter
		var icon = ViewRecordCodec.factoryIconPlist
		if let i = svs?[W.iconSectionKey] as? [String: Any] { icon.merge(ViewRecordCodec.sanitizeIconPlist(i)) { _, new in new } }
		var listArray = ViewRecordCodec.factoryListPlist
		if let l = svs?[W.listArraySectionKey] as? [String: Any] {
			listArray.merge(ViewRecordCodec.sanitizeListPlist(l)) { _, new in new }
		} else if let l = svs?[W.listDictSectionKey] as? [String: Any] {
			// Only the dict-form section: the list options are taken from it, never left at the factory values (the rule
			// `GlobalDefaultsWriter.plannedValues` and `StoreEditor.apply` use too).
			listArray.merge(ViewRecordCodec.arrayForm(ofList: ViewRecordCodec.sanitizeListPlist(l))) { _, new in new }
		}
		self.init(preferredViewStyle: viewStyle.flatMap(ViewStyle.init(rawValue:)), iconPlist: icon, listArrayPlist: listArray)
	}
}

import Foundation

/// Read-only access to Finder's global view defaults (`com.apple.finder`).
public struct GlobalDefaults: @unchecked Sendable {
	public var preferredViewStyle: ViewStyle?
	public var iconPlist: [String: Any]
	public var listArrayPlist: [String: Any]
	public var listDictPlist: [String: Any]

	public init(preferredViewStyle: ViewStyle? = nil,
	            iconPlist: [String: Any] = ViewRecordCodec.factoryIconPlist,
	            listArrayPlist: [String: Any] = ViewRecordCodec.factoryListPlist,
	            listDictPlist: [String: Any]? = nil) {
		self.preferredViewStyle = preferredViewStyle
		self.iconPlist = iconPlist
		self.listArrayPlist = listArrayPlist
		self.listDictPlist = listDictPlist ?? ViewRecordCodec.dictForm(ofList: listArrayPlist)
	}

	/// The effective settings a folder without explicit records gets. No grouping: whether Finder shows a folder without a
	/// `GRP0` record with its global `FXPreferredGroupBy` is unverified, so a preset's grouping is compared
	/// with the folder's own record only, and written to every folder that does not hold it yet.
	public var effectiveSettings: ViewSettings {
		ViewSettings(viewStyle: preferredViewStyle, icon: ViewRecordCodec.decodeIcon(iconPlist), list: ViewRecordCodec.decodeList(listArrayPlist))
	}

	public var recordBases: RecordBases {
		RecordBases(icon: iconPlist, listArray: listArrayPlist, listDict: listDictPlist)
	}

	public static let factory = GlobalDefaults()

	/// Reads the current user's Finder defaults. Never writes.
	public static func readCurrent() -> GlobalDefaults {
		typealias W = GlobalDefaultsWriter
		guard let d = UserDefaults(suiteName: W.finderDomain) else { return .factory }
		let style = (d.string(forKey: W.viewStyleKey)).flatMap(ViewStyle.init(rawValue:))
		let svs = d.dictionary(forKey: W.standardViewSettingsKey) ?? [:]
		var icon = ViewRecordCodec.factoryIconPlist
		if let i = svs[W.iconSectionKey] as? [String: Any] { icon.merge(ViewRecordCodec.sanitizeIconPlist(i)) { _, new in new } }
		var listArray = ViewRecordCodec.factoryListPlist
		if let l = svs[W.listArraySectionKey] as? [String: Any] { listArray.merge(ViewRecordCodec.sanitizeListPlist(l)) { _, new in new } }
		var listDict: [String: Any]? = nil
		if let l = svs[W.listDictSectionKey] as? [String: Any] { listDict = ViewRecordCodec.sanitizeListPlist(l) }
		return GlobalDefaults(preferredViewStyle: style, iconPlist: icon, listArrayPlist: listArray, listDictPlist: listDict)
	}
}

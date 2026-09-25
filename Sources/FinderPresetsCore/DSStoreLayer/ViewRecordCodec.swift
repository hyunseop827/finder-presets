import Foundation

/// Converts between the plist payloads inside `icvp` / `lsvC` / `lsvp` / `lsvP` records and `ViewSettings`.
/// Encoding merges at the plist-key level so keys this app does not know about are preserved.
public enum ViewRecordCodec {
	// MARK: Defaults (Finder's factory values, used only when no global default is available)

	nonisolated(unsafe) public static let factoryIconPlist: [String: Any] = [
		"viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": 64.0, "textSize": 12.0,
		"labelOnBottom": true, "showItemInfo": false, "showIconPreview": true, "gridSpacing": 54.0,
		"gridOffsetX": 0.0, "gridOffsetY": 0.0, "backgroundType": 0,
		"backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0
	]

	nonisolated(unsafe) public static let factoryListColumns: [[String: Any]] = [
		["identifier": "name", "width": 300, "ascending": true, "visible": true],
		["identifier": "dateModified", "width": 181, "ascending": false, "visible": true],
		["identifier": "dateCreated", "width": 181, "ascending": false, "visible": false],
		["identifier": "size", "width": 97, "ascending": false, "visible": true],
		["identifier": "kind", "width": 115, "ascending": true, "visible": true],
		["identifier": "label", "width": 100, "ascending": true, "visible": false],
		["identifier": "version", "width": 75, "ascending": true, "visible": false],
		["identifier": "comments", "width": 300, "ascending": true, "visible": false],
		["identifier": "dateLastOpened", "width": 200, "ascending": false, "visible": false],
		["identifier": "dateAdded", "width": 181, "ascending": false, "visible": false]
	]

	public static var factoryListPlist: [String: Any] {
		["viewOptionsVersion": 1, "iconSize": 16.0, "textSize": 13.0, "showIconPreview": true,
		 "useRelativeDates": true, "calculateAllSizes": false, "sortColumn": "name", "columns": factoryListColumns]
	}

	// MARK: Plist helpers

	public static func plist(from data: Data) -> [String: Any]? {
		(try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
	}

	public static func data(from plist: [String: Any]) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
	}

	static func double(_ v: Any?) -> Double? {
		switch v {
		case let d as Double: d
		case let i as Int: Double(i)
		case let n as NSNumber: n.doubleValue
		case let s as String: Double(s)          // CFPreferences hands Finder's numbers back as strings
		default: nil
		}
	}

	static func bool(_ v: Any?) -> Bool? {
		switch v {
		case let b as Bool: b
		case let n as NSNumber: n.boolValue
		case let s as String: s == "1" || s.lowercased() == "true" ? true : (s == "0" || s.lowercased() == "false" ? false : nil)
		default: nil
		}
	}

	static func int(_ v: Any?) -> Int? {
		switch v {
		case let i as Int: i
		case let n as NSNumber: n.intValue
		case let s as String: Int(s)
		default: nil
		}
	}

	// MARK: Type sanitizing (values read from com.apple.finder via CFPreferences arrive as strings)

	static let iconBoolKeys: Set<String> = ["labelOnBottom", "showItemInfo", "showIconPreview"]
	static let iconIntKeys: Set<String> = ["viewOptionsVersion", "backgroundType"]
	static let iconDoubleKeys: Set<String> = ["iconSize", "textSize", "gridSpacing", "gridOffsetX", "gridOffsetY", "backgroundColorRed", "backgroundColorGreen", "backgroundColorBlue", "scrollPositionX", "scrollPositionY"]
	static let listBoolKeys: Set<String> = ["showIconPreview", "useRelativeDates", "calculateAllSizes"]
	static let listIntKeys: Set<String> = ["viewOptionsVersion"]
	static let listDoubleKeys: Set<String> = ["iconSize", "textSize", "scrollPositionX", "scrollPositionY"]

	public static func sanitizeIconPlist(_ p: [String: Any]) -> [String: Any] {
		var out = p
		for (k, v) in p {
			if iconBoolKeys.contains(k), let b = bool(v) { out[k] = b }
			else if iconIntKeys.contains(k), let i = int(v) { out[k] = i }
			else if iconDoubleKeys.contains(k), let d = double(v) { out[k] = d }
		}
		return out
	}

	public static func sanitizeListPlist(_ p: [String: Any]) -> [String: Any] {
		var out = p
		for (k, v) in p {
			if listBoolKeys.contains(k), let b = bool(v) { out[k] = b }
			else if listIntKeys.contains(k), let i = int(v) { out[k] = i }
			else if listDoubleKeys.contains(k), let d = double(v) { out[k] = d }
		}
		func column(_ c: [String: Any]) -> [String: Any] {
			var o = c
			if let w = int(c["width"]) { o["width"] = w }
			if let i = int(c["index"]) { o["index"] = i }
			if let a = bool(c["ascending"]) { o["ascending"] = a }
			if let v = bool(c["visible"]) { o["visible"] = v }
			return o
		}
		if let arr = p["columns"] as? [[String: Any]] { out["columns"] = arr.map(column) }
		else if let dict = p["columns"] as? [String: [String: Any]] { out["columns"] = dict.mapValues(column) }
		return out
	}

	// MARK: Decode

	public static func decodeIcon(_ plist: [String: Any]) -> IconViewSettings {
		IconViewSettings(
			iconSize: double(plist["iconSize"]),
			textSize: double(plist["textSize"]),
			labelOnBottom: bool(plist["labelOnBottom"]),
			showItemInfo: bool(plist["showItemInfo"]),
			showIconPreview: bool(plist["showIconPreview"]),
			arrangeBy: (plist["arrangeBy"] as? String).flatMap(SortKey.init(rawValue:)),
			gridSpacing: double(plist["gridSpacing"])
		)
	}

	/// Handles both the array-form `columns` (lsvC / lsvP) and the dict-form (lsvp).
	/// A sort column this app does not know (e.g. `shareOwner`, `ubiquity` on shared folders) yields neither
	/// `sortColumn` nor `sortAscending`: the direction can only be written together with its column.
	public static func decodeList(_ plist: [String: Any]) -> ListViewSettings {
		let sortColumn = plist["sortColumn"] as? String
		let column = sortColumn.flatMap(ListColumn.init(rawValue:))
		var ascending: Bool?
		if let sortColumn, column != nil {
			if let array = plist["columns"] as? [[String: Any]] {
				ascending = array.first { ($0["identifier"] as? String) == sortColumn }.flatMap { bool($0["ascending"]) }
			} else if let dict = plist["columns"] as? [String: [String: Any]] {
				ascending = dict[sortColumn].flatMap { bool($0["ascending"]) }
			}
		}
		return ListViewSettings(
			textSize: double(plist["textSize"]),
			iconSize: double(plist["iconSize"]),
			sortColumn: column,
			sortAscending: ascending,
			showIconPreview: bool(plist["showIconPreview"]),
			useRelativeDates: bool(plist["useRelativeDates"]),
			calculateAllSizes: bool(plist["calculateAllSizes"])
		)
	}

	/// Decodes a managed record set into the explicit settings it contains.
	public static func decode(_ set: ManagedRecordSet) -> ViewSettings {
		var out = ViewSettings()
		if let vstl = set["vstl"]?.fourCCValue { out.viewStyle = ViewStyle(rawValue: vstl) }
		// A grouping this app does not offer (e.g. one Finder writes for tags) yields none: it is kept as stored.
		if let group = set["GRP0"]?.stringValue { out.groupBy = GroupBy(rawValue: group) }
		if let d = set["icvp"]?.dataValue, let p = plist(from: d) { out.icon = decodeIcon(p) }
		// Finder prefers lsvC when several list records exist.
		for code in ["lsvC", "lsvP", "lsvp"] {
			if let d = set[code]?.dataValue, let p = plist(from: d) { out.list = decodeList(p); break }
		}
		return out
	}

	// MARK: Encode (merge into existing plist)

	public static func mergeIcon(_ s: IconViewSettings, into existing: [String: Any]?, base: [String: Any]) -> [String: Any] {
		var p = existing ?? base
		if p["viewOptionsVersion"] == nil { p["viewOptionsVersion"] = 1 }
		if let v = s.iconSize { p["iconSize"] = v }
		if let v = s.textSize { p["textSize"] = v }
		if let v = s.labelOnBottom { p["labelOnBottom"] = v }
		if let v = s.showItemInfo { p["showItemInfo"] = v }
		if let v = s.showIconPreview { p["showIconPreview"] = v }
		if let v = s.arrangeBy { p["arrangeBy"] = v.rawValue }
		if let v = s.gridSpacing { p["gridSpacing"] = v }
		return p
	}

	public static func mergeList(_ s: ListViewSettings, into existing: [String: Any]?, base: [String: Any]) -> [String: Any] {
		var p = existing ?? base
		if p["viewOptionsVersion"] == nil { p["viewOptionsVersion"] = 1 }
		if let v = s.textSize { p["textSize"] = v }
		if let v = s.iconSize { p["iconSize"] = v }
		if let v = s.showIconPreview { p["showIconPreview"] = v }
		if let v = s.useRelativeDates { p["useRelativeDates"] = v }
		if let v = s.calculateAllSizes { p["calculateAllSizes"] = v }
		if let col = s.sortColumn {
			p["sortColumn"] = col.rawValue
			if let asc = s.sortAscending {
				if var array = p["columns"] as? [[String: Any]] {
					if let i = array.firstIndex(where: { ($0["identifier"] as? String) == col.rawValue }) {
						array[i]["ascending"] = asc
					} else {
						array.append(["identifier": col.rawValue, "width": 181, "ascending": asc, "visible": true])
					}
					p["columns"] = array
				} else if var dict = p["columns"] as? [String: [String: Any]] {
					var entry = dict[col.rawValue] ?? ["index": dict.count, "width": 181, "visible": true]
					entry["ascending"] = asc
					dict[col.rawValue] = entry
					p["columns"] = dict
				}
			}
		}
		return p
	}

	/// An array-form list plist (lsvC, `ExtendedListViewSettingsV2`) in dict form (lsvp, `ListViewSettings`): the same
	/// values, with the columns converted (`dictColumns(fromArray:)`).
	static func dictForm(ofList list: [String: Any]) -> [String: Any] {
		var d = list
		if let cols = list["columns"] as? [[String: Any]] { d["columns"] = dictColumns(fromArray: cols) }
		return d
	}

	/// Converts array-form columns (lsvC) to dict-form (lsvp) so both records stay in sync.
	public static func dictColumns(fromArray array: [[String: Any]]) -> [String: [String: Any]] {
		var out: [String: [String: Any]] = [:]
		for (i, c) in array.enumerated() {
			guard let id = c["identifier"] as? String else { continue }
			out[id] = ["index": i, "width": c["width"] ?? 100, "ascending": c["ascending"] ?? true, "visible": c["visible"] ?? false]
		}
		return out
	}

	/// The inverse of `dictColumns(fromArray:)`: dict-form columns ordered by their `index`.
	public static func arrayColumns(fromDict dict: [String: [String: Any]]) -> [[String: Any]] {
		dict.sorted { (int($0.value["index"]) ?? Int.max, $0.key) < (int($1.value["index"]) ?? Int.max, $1.key) }
			.map { id, c in ["identifier": id, "width": c["width"] ?? 100, "ascending": c["ascending"] ?? true, "visible": c["visible"] ?? false] }
	}
}

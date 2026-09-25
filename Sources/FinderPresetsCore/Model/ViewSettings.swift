import Foundation

/// Finder view style. Raw values are the `vstl` four-char codes Finder 26 writes.
public enum ViewStyle: String, Codable, CaseIterable, Sendable, Hashable {
	case icon = "icnv"
	case list = "Nlsv"
	case column = "clmv"
	case gallery = "glyv"
}

/// Icon-view sort key. Raw values are the `icvp.arrangeBy` strings, in the order of Finder's "정렬" menu. `grid` is
/// Finder's "자동 격자 정렬" (Snap to Grid): no order, the icons keep their places on the grid.
public enum SortKey: String, Codable, CaseIterable, Sendable, Hashable {
	case none
	case grid
	case name
	case kind
	case dateModified
	case dateCreated
	case dateAdded
	case dateLastOpened
	case size
	case label
}

/// Finder's "그룹 기준" (Group By) of one folder: the `GRP0` record (`ustr`) the parent `.DS_Store` holds for it, next to
/// the view records. Raw values are the strings Finder reads there (case-sensitive). Finder 26.4 honoured each of these
/// written by another program in a folder it had not shown yet, in icon and list view, over its global `FXPreferredGroupBy`.
/// Values it showed no grouping for ("Name", "Tags", an unknown string) or could not open a window with
/// ("Label") are not offered. The gallery view shows no groups. Finder's own "None" is `.none`.
public enum GroupBy: String, Codable, CaseIterable, Sendable, Hashable {
	case none = "None"
	case kind = "Kind"
	case application = "Application"
	case dateLastOpened = "Date Last Opened"
	case dateAdded = "Date Added"
	case dateModified = "Date Modified"
	case dateCreated = "Date Created"
	case size = "Size"
}

/// List-view column identifiers Finder 26 uses.
public enum ListColumn: String, Codable, CaseIterable, Sendable, Hashable {
	case name, dateModified, dateCreated, dateAdded, dateLastOpened, size, kind, label, version, comments
}

/// `nil` means "leave the folder's current value alone".
public struct IconViewSettings: Codable, Equatable, Sendable, Hashable {
	public var iconSize: Double?
	public var textSize: Double?
	public var labelOnBottom: Bool?
	public var showItemInfo: Bool?
	public var showIconPreview: Bool?
	public var arrangeBy: SortKey?
	public var gridSpacing: Double?

	public init(iconSize: Double? = nil, textSize: Double? = nil, labelOnBottom: Bool? = nil, showItemInfo: Bool? = nil, showIconPreview: Bool? = nil, arrangeBy: SortKey? = nil, gridSpacing: Double? = nil) {
		self.iconSize = iconSize
		self.textSize = textSize
		self.labelOnBottom = labelOnBottom
		self.showItemInfo = showItemInfo
		self.showIconPreview = showIconPreview
		self.arrangeBy = arrangeBy
		self.gridSpacing = gridSpacing
	}

	public var isEmpty: Bool { self == IconViewSettings() }
}

public struct ListViewSettings: Codable, Equatable, Sendable, Hashable {
	public var textSize: Double?
	public var iconSize: Double?          // 16 or 32
	public var sortColumn: ListColumn?
	public var sortAscending: Bool?
	public var showIconPreview: Bool?
	public var useRelativeDates: Bool?
	public var calculateAllSizes: Bool?

	public init(textSize: Double? = nil, iconSize: Double? = nil, sortColumn: ListColumn? = nil, sortAscending: Bool? = nil, showIconPreview: Bool? = nil, useRelativeDates: Bool? = nil, calculateAllSizes: Bool? = nil) {
		self.textSize = textSize
		self.iconSize = iconSize
		self.sortColumn = sortColumn
		self.sortAscending = sortAscending
		self.showIconPreview = showIconPreview
		self.useRelativeDates = useRelativeDates
		self.calculateAllSizes = calculateAllSizes
	}

	private enum CodingKeys: String, CodingKey {
		case textSize, iconSize, sortColumn, sortAscending, showIconPreview, useRelativeDates, calculateAllSizes
	}

	/// A sort direction is stored inside the sort column's entry (`columns[…].ascending`), so it can only be
	/// written together with `sortColumn`. A file that carries `sortAscending` alone (hand-edited JSON, an
	/// older export) is read without it; otherwise the value could never be applied but would always be verified.
	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let column = try c.decodeIfPresent(ListColumn.self, forKey: .sortColumn)
		self.init(
			textSize: try c.decodeIfPresent(Double.self, forKey: .textSize),
			iconSize: try c.decodeIfPresent(Double.self, forKey: .iconSize),
			sortColumn: column,
			sortAscending: column == nil ? nil : try c.decodeIfPresent(Bool.self, forKey: .sortAscending),
			showIconPreview: try c.decodeIfPresent(Bool.self, forKey: .showIconPreview),
			useRelativeDates: try c.decodeIfPresent(Bool.self, forKey: .useRelativeDates),
			calculateAllSizes: try c.decodeIfPresent(Bool.self, forKey: .calculateAllSizes)
		)
	}

	public var isEmpty: Bool { self == ListViewSettings() }

	/// True when `sortAscending` is set without `sortColumn` — a value that cannot be written (see `init(from:)`).
	public var hasDanglingSortDirection: Bool { sortAscending != nil && sortColumn == nil }

	/// `self` without a dangling sort direction.
	public func normalized() -> ListViewSettings {
		var out = self
		if hasDanglingSortDirection { out.sortAscending = nil }
		return out
	}
}

/// The set of Finder view properties this app understands. Every field is optional.
public struct ViewSettings: Codable, Equatable, Sendable, Hashable {
	public var viewStyle: ViewStyle?
	public var icon: IconViewSettings
	public var list: ListViewSettings
	/// The folder's grouping (`GRP0`), for every view style. Optional in the JSON: presets written before it existed decode
	/// without it ("유지").
	public var groupBy: GroupBy?

	public init(viewStyle: ViewStyle? = nil, icon: IconViewSettings = .init(), list: ListViewSettings = .init(), groupBy: GroupBy? = nil) {
		self.viewStyle = viewStyle
		self.icon = icon
		self.list = list
		self.groupBy = groupBy
	}

	public var isEmpty: Bool { viewStyle == nil && icon.isEmpty && list.isEmpty && groupBy == nil }

	/// The part Finder's global defaults hold (`FXPreferredViewStyle`, `StandardViewSettings`): everything but the grouping.
	/// The app writes a grouping only into folders (`GRP0`), never into Finder's `FXPreferredGroupBy`: whether Finder uses
	/// that value for folders without a `GRP0` record is unverified, and Finder changes it on its own
	/// whenever a folder's grouping is changed in a window.
	public var globalDefaultsPart: ViewSettings {
		var out = self
		out.groupBy = nil
		return out
	}

	/// `self` with values that can never be written removed (currently: a list sort direction without a sort column).
	public func normalized() -> ViewSettings {
		var out = self
		out.list = list.normalized()
		return out
	}

	/// Returns `self` with every nil field filled from `base`.
	public func filling(from base: ViewSettings) -> ViewSettings {
		var out = self
		out.viewStyle = viewStyle ?? base.viewStyle
		out.groupBy = groupBy ?? base.groupBy
		out.icon.iconSize = icon.iconSize ?? base.icon.iconSize
		out.icon.textSize = icon.textSize ?? base.icon.textSize
		out.icon.labelOnBottom = icon.labelOnBottom ?? base.icon.labelOnBottom
		out.icon.showItemInfo = icon.showItemInfo ?? base.icon.showItemInfo
		out.icon.showIconPreview = icon.showIconPreview ?? base.icon.showIconPreview
		out.icon.arrangeBy = icon.arrangeBy ?? base.icon.arrangeBy
		out.icon.gridSpacing = icon.gridSpacing ?? base.icon.gridSpacing
		out.list.textSize = list.textSize ?? base.list.textSize
		out.list.iconSize = list.iconSize ?? base.list.iconSize
		out.list.sortColumn = list.sortColumn ?? base.list.sortColumn
		out.list.sortAscending = list.sortAscending ?? base.list.sortAscending
		out.list.showIconPreview = list.showIconPreview ?? base.list.showIconPreview
		out.list.useRelativeDates = list.useRelativeDates ?? base.list.useRelativeDates
		out.list.calculateAllSizes = list.calculateAllSizes ?? base.list.calculateAllSizes
		return out
	}
}

/// One differing property between a folder's current state and a target. `field` is the property's name in the model
/// ("icon.iconSize"); the values are written as the model prints them. No display text: the caller words it.
public struct FieldDiff: Codable, Equatable, Sendable, Hashable {
	public let field: String
	/// Nil when the current state has no value for the property.
	public let current: String?
	public let target: String

	public init(field: String, current: String?, target: String) {
		self.field = field
		self.current = current
		self.target = target
	}

	/// "icon.iconSize: 미설정 ≠ 64" — the form `finder-presets` prints (Korean, like the rest of `finder-presets`).
	public var text: String { "\(field): \(current ?? "미설정") ≠ \(target)" }
}

extension ViewSettings {
	/// Lists every property that `target` specifies (non-nil) and that differs from `self`.
	/// Properties belonging to a view style other than `target.viewStyle` are still compared,
	/// because Finder keeps icon and list options independently per folder.
	public func differences(to target: ViewSettings) -> [FieldDiff] {
		var out: [FieldDiff] = []
		func cmp<T: Equatable>(_ name: String, _ cur: T?, _ tgt: T?) {
			guard let tgt else { return }
			if cur != tgt {
				out.append(FieldDiff(field: name, current: cur.map { "\($0)" }, target: "\(tgt)"))
			}
		}
		cmp("viewStyle", viewStyle, target.viewStyle)
		cmp("groupBy", groupBy.map(\.rawValue), target.groupBy.map(\.rawValue))
		cmp("icon.iconSize", icon.iconSize, target.icon.iconSize)
		cmp("icon.textSize", icon.textSize, target.icon.textSize)
		cmp("icon.labelOnBottom", icon.labelOnBottom, target.icon.labelOnBottom)
		cmp("icon.showItemInfo", icon.showItemInfo, target.icon.showItemInfo)
		cmp("icon.showIconPreview", icon.showIconPreview, target.icon.showIconPreview)
		cmp("icon.arrangeBy", icon.arrangeBy, target.icon.arrangeBy)
		cmp("icon.gridSpacing", icon.gridSpacing, target.icon.gridSpacing)
		cmp("list.textSize", list.textSize, target.list.textSize)
		cmp("list.iconSize", list.iconSize, target.list.iconSize)
		cmp("list.sortColumn", list.sortColumn, target.list.sortColumn)
		// The direction lives in the sort column's entry: without a target column it cannot be written, so it is not compared
		// (otherwise a plan would stay "willChange" and a global apply would fail verification forever).
		if target.list.sortColumn != nil { cmp("list.sortAscending", list.sortAscending, target.list.sortAscending) }
		cmp("list.showIconPreview", list.showIconPreview, target.list.showIconPreview)
		cmp("list.useRelativeDates", list.useRelativeDates, target.list.useRelativeDates)
		cmp("list.calculateAllSizes", list.calculateAllSizes, target.list.calculateAllSizes)
		return out
	}
}

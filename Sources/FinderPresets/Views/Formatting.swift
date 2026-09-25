import SwiftUI
import AppKit
import FinderPresetsCore

enum Fmt {
	/// A view style's name ("유지" when the preset leaves it alone). Also the preset editor's segments.
	static func style(_ s: ViewStyle?) -> String {
		switch s {
		case .icon?: String(localized: "아이콘")
		case .list?: String(localized: "목록")
		case .column?: String(localized: "컬럼")
		case .gallery?: String(localized: "갤러리")
		case nil: keep
		}
	}
	static func sort(_ k: SortKey?) -> String {
		switch k {
		case .none?: String(localized: "없음")
		case .grid: String(localized: "자동 격자 정렬")
		case .name: String(localized: "이름")
		case .kind: String(localized: "종류")
		case .dateModified: String(localized: "수정일")
		case .dateCreated: String(localized: "생성일")
		case .dateAdded: String(localized: "추가일")
		case .dateLastOpened: String(localized: "마지막 열람일")
		case .size: String(localized: "크기")
		case .label: String(localized: "태그")
		case nil: keep
		}
	}
	/// A grouping's name (Finder's "그룹 기준"), with the same words as the sort keys where Finder uses the same attribute.
	static func group(_ g: GroupBy?) -> String {
		switch g {
		case .none?: String(localized: "없음")
		case .kind: String(localized: "종류")
		case .application: String(localized: "응용 프로그램")
		case .dateLastOpened: String(localized: "마지막 열람일")
		case .dateAdded: String(localized: "추가일")
		case .dateModified: String(localized: "수정일")
		case .dateCreated: String(localized: "생성일")
		case .size: String(localized: "크기")
		case nil: keep
		}
	}
	static func column(_ c: ListColumn?) -> String {
		switch c {
		case .name: String(localized: "이름")
		case .dateModified: String(localized: "수정일")
		case .dateCreated: String(localized: "생성일")
		case .dateAdded: String(localized: "추가일")
		case .dateLastOpened: String(localized: "마지막 열람일")
		case .size: String(localized: "크기")
		case .kind: String(localized: "종류")
		case .label: String(localized: "태그")
		case .version: String(localized: "버전")
		case .comments: String(localized: "설명")
		case nil: keep
		}
	}
	/// An option the preset leaves alone.
	static var keep: String { String(localized: "유지") }
	static var on: String { String(localized: "켬") }
	static var off: String { String(localized: "끔") }
	static func num(_ d: Double?) -> String { d.map(number) ?? keep }
	/// "48", "48.5". A whole number beyond what `Int` holds (a preset file can hold any number) is written as it is:
	/// `Int(_:)` would stop the app there.
	static func number(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }
	static func onOff(_ b: Bool?) -> String { b.map { $0 ? on : off } ?? keep }
	/// A name the user chose (a preset, a folder, a file) inside a status text: set apart with invisible Unicode isolates
	/// (U+2068 … U+2069), so the status line judges its tone by the app's own words only (`StatusBar.tone`) — a preset
	/// called "Failed takes" never turns a finished apply into a warning. Isolate marks already in the name are dropped.
	static func name(_ text: String) -> String {
		"\u{2068}" + String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) })) + "\u{2069}"
	}
	/// The first `limit` names, "A, B 외 3개" when there are more.
	static func firstNames(_ names: [String], limit: Int) -> String {
		let shown = names.prefix(limit).joined(separator: ", ")
		return names.count > limit ? String(localized: "\(shown) 외 \(names.count - limit)개") : shown
	}
	/// The folders' names ("Documents, Music"), as one `name`.
	static func folderNames(_ paths: [String]) -> String {
		name(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
	}
	/// `text`, shortened in the middle with "…" until it fits `width` in `font`. For an AppKit-backed label (the folder
	/// rows' preset menu), which does not truncate its title and would grow past its frame instead.
	static func fitted(_ text: String, width: CGFloat, font: NSFont) -> String {
		let attributes: [NSAttributedString.Key: Any] = [.font: font]
		func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attributes).width <= width }
		guard !fits(text) else { return text }
		let characters = Array(text)
		func shortened(keeping n: Int) -> String {
			let head = String(characters.prefix(n - n / 2)).trimmingCharacters(in: .whitespaces)
			let tail = String(characters.suffix(n / 2)).trimmingCharacters(in: .whitespaces)
			return head + "…" + tail
		}
		var low = 0, high = characters.count - 1   // characters kept around the "…"
		while low < high {
			let mid = (low + high + 1) / 2
			if fits(shortened(keeping: mid)) { low = mid } else { high = mid - 1 }
		}
		return shortened(keeping: low)
	}
	static func abbreviate(_ path: String) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
	}
}

/// The preset's values in a 3×2 grid of short names ("보기 아이콘  정렬 종류" …); "유지" (the option is left alone) is
/// dimmed. Each cell shows the options a folder shows most; the other options of its view are counted as "+N" there
/// (the grouping, which every view shows, in "보기"; grid spacing in "아이콘"; the list view's text and icon size,
/// preview, relative dates and all sizes in "목록"). The
/// tooltip and what VoiceOver reads name every option the preset sets (`details`). Every name and value is localized (`Fmt`).
struct SettingsSummary: View {
	let settings: ViewSettings

	typealias Item = (short: String, long: String, value: String, kept: Bool)

	/// Row by row: 보기 | 정렬, 아이콘 | 목록, 레이블 | 정보·미리보기.
	static func items(_ s: ViewSettings) -> [Item] {
		func pair(_ a: String, _ b: String, kept: Bool) -> String { kept ? Fmt.keep : "\(a) / \(b)" }
		let iconMain = s.icon.iconSize == nil && s.icon.textSize == nil ? nil : "\(Fmt.num(s.icon.iconSize)) / \(Fmt.num(s.icon.textSize))"
		let iconValue = more(iconMain, s.icon.gridSpacing == nil ? 0 : 1, alone: String(localized: "격자 \(Fmt.num(s.icon.gridSpacing))"))
		let listMain = s.list.sortColumn.map { Fmt.column($0) + sortDirection(s.list) }
		let listOthers = listExtras(s.list)
		let listValue = more(listMain, listOthers, alone: String(localized: "옵션 \(listOthers)개"))
		let infoKept = s.icon.showItemInfo == nil && s.icon.showIconPreview == nil
		let label = s.icon.labelOnBottom.map { $0 ? String(localized: "하단") : String(localized: "오른쪽") } ?? Fmt.keep
		let styleValue = more(s.viewStyle.map { Fmt.style($0) }, s.groupBy == nil ? 0 : 1, alone: String(localized: "그룹 \(Fmt.group(s.groupBy))"))
		return [
			(String(localized: "보기"), String(localized: "보기 방식"), styleValue, s.viewStyle == nil && s.groupBy == nil),
			(String(localized: "정렬"), String(localized: "정렬 기준"), Fmt.sort(s.icon.arrangeBy), s.icon.arrangeBy == nil),
			(String(localized: "아이콘"), String(localized: "아이콘 보기"), iconValue, iconMain == nil && s.icon.gridSpacing == nil),
			(String(localized: "목록"), String(localized: "목록 보기"), listValue, listMain == nil && listOthers == 0),
			(String(localized: "레이블"), String(localized: "레이블 위치"), label, s.icon.labelOnBottom == nil),
			(String(localized: "정보·미리보기"), String(localized: "항목 정보 / 미리보기"), pair(Fmt.onOff(s.icon.showItemInfo), Fmt.onOff(s.icon.showIconPreview), kept: infoKept), infoKept)
		]
	}

	/// " ↑" / " ↓" after the list's sort column ("" without a direction).
	static func sortDirection(_ l: ListViewSettings) -> String { l.sortAscending.map { $0 ? " ↑" : " ↓" } ?? "" }

	/// The list options the "목록" cell only counts: text size, icon size, preview, relative dates, all sizes.
	static func listExtras(_ l: ListViewSettings) -> Int {
		[l.textSize != nil, l.iconSize != nil, l.showIconPreview != nil, l.useRelativeDates != nil, l.calculateAllSizes != nil].filter { $0 }.count
	}

	/// A cell's value: its main value with "+N" for the other options of its view, or — without a main value — `alone`.
	static func more(_ main: String?, _ others: Int, alone: @autoclosure () -> String) -> String {
		if let main { return others > 0 ? main + " +\(others)" : main }
		return others > 0 ? alone() : Fmt.keep
	}

	/// Every option the preset sets, as "name: value", then how many it leaves alone: the tooltip of the summaries (this
	/// grid, a preset row's line) and what VoiceOver reads.
	static func details(_ s: ViewSettings) -> [String] {
		let icon = String(localized: "아이콘 보기"), list = String(localized: "목록 보기")
		let label = s.icon.labelOnBottom.map { $0 ? String(localized: "하단") : String(localized: "오른쪽") }
		let all: [(String, String?)] = [
			(String(localized: "보기 방식"), s.viewStyle.map { Fmt.style($0) }),
			(String(localized: "그룹 기준"), s.groupBy.map { Fmt.group($0) }),
			(icon + " · " + String(localized: "아이콘 크기"), s.icon.iconSize.map(Fmt.number)),
			(icon + " · " + String(localized: "텍스트 크기"), s.icon.textSize.map(Fmt.number)),
			(icon + " · " + String(localized: "정렬 기준"), s.icon.arrangeBy.map { Fmt.sort($0) }),
			(icon + " · " + String(localized: "레이블 위치"), label),
			(icon + " · " + String(localized: "항목 정보"), s.icon.showItemInfo.map { Fmt.onOff($0) }),
			(icon + " · " + String(localized: "아이콘 미리보기"), s.icon.showIconPreview.map { Fmt.onOff($0) }),
			(icon + " · " + String(localized: "격자 간격"), s.icon.gridSpacing.map(Fmt.number)),
			(list + " · " + String(localized: "정렬 열"), s.list.sortColumn.map { Fmt.column($0) + sortDirection(s.list) }),
			(list + " · " + String(localized: "텍스트 크기"), s.list.textSize.map(Fmt.number)),
			(list + " · " + String(localized: "아이콘 크기"), s.list.iconSize.map(Fmt.number)),
			(list + " · " + String(localized: "아이콘 미리보기"), s.list.showIconPreview.map { Fmt.onOff($0) }),
			(list + " · " + String(localized: "상대적 날짜"), s.list.useRelativeDates.map { Fmt.onOff($0) }),
			(list + " · " + String(localized: "모든 크기 계산"), s.list.calculateAllSizes.map { Fmt.onOff($0) })
		]
		let set = all.compactMap { name, value in value.map { "\(name): \($0)" } }
		let kept = all.count - set.count
		if set.isEmpty { return [String(localized: "모든 옵션 유지")] }
		return kept > 0 ? set + [String(localized: "나머지 옵션 \(kept)개는 유지")] : set
	}

	/// How many options the preset sets (the view style and the grouping included; the list's sort direction goes with its
	/// column).
	static func setCount(_ s: ViewSettings) -> Int {
		let i = s.icon, l = s.list
		return [s.viewStyle != nil, s.groupBy != nil, i.iconSize != nil, i.textSize != nil, i.arrangeBy != nil, i.labelOnBottom != nil, i.showItemInfo != nil,
		        i.showIconPreview != nil, i.gridSpacing != nil, l.sortColumn != nil].filter { $0 }.count + listExtras(l)
	}

	var body: some View {
		let items = Self.items(settings)
		let spoken = Self.details(settings).joined(separator: "\n")
		Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
			ForEach(0..<3, id: \.self) { row in
				GridRow {
					cells(items[row * 2])
					cells(items[row * 2 + 1], leading: 8)
				}
			}
		}
		.font(.subheadline)
		.help(spoken)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(spoken)
	}

	@ViewBuilder private func cells(_ item: Item, leading: CGFloat = 0) -> some View {
		Text(item.short).foregroundStyle(.secondary).lineLimit(1).padding(.leading, leading)
		Text(item.value)
			.fontWeight(item.kept ? .regular : .medium)
			.foregroundStyle(item.kept ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
			.lineLimit(1)
	}
}

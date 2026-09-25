import Foundation
import FinderPresetsCore

// The preset editor's live preview (the "미리보기" window beside the main window, Views/PresetPreviewWindow.swift): what
// it draws, worked out here without AppKit or SwiftUI so it can be tested. The input is the editor's draft (as
// `ViewSettings`, the last valid value of each number), Finder's current defaults (for every option the draft leaves
// "유지"), the app's locale and a fixed "now"; the output is the sample items in order with their groups and positions,
// the strings to draw and the honesty notes. Nothing here reads the disk: the sample folder is made up and fixed.
//
// Rules:
// - "유지" is drawn with ONE source, Finder's current defaults (`AppModel.globals`, `GlobalDefaults.effectiveSettings`);
//   the editor's dimmed sliders rest on the same values (`PresetDraft.restPositions`). A kept sort direction comes from
//   the chosen column's own entry in those defaults. A kept grouping is drawn without groups (Finder's global
//   `FXPreferredGroupBy` is not known to apply to folders).
// - The icon scale depends on the icon size only (`iconScale`): text size and grid spacing never shrink icons; they
//   change the pitch, so the number of columns, like a narrower or wider Finder window. Text is drawn at its real size.
// - What is drawn is what a Finder window scrolled to its top shows (`pick`): the first rows (or groups, each one row
//   that scrolls sideways) in the order the options give. At least one folder and one image are always visible: only
//   when that top part has none, its last rows give way to the first later one that has it, after a "⋯". The preview
//   says how many of the samples it shows.
// - The list view always shows name, date modified, size and kind (plus the sort column when it is another one); the
//   name, date and size columns are as wide as their longest text (dates fall back to a shorter format, like Finder);
//   only the kind column may be cut.
// - Name order keeps folders on top when Finder's "Keep folders on top when sorting by name" is on (`foldersFirst`).

// MARK: Samples

/// The file types of the samples. Their icons are the system's icons for the type (never a user file's).
enum PreviewFileType: String, CaseIterable, Sendable {
	case folder, pdf, jpeg, png, text, zip, movie

	/// The Uniform Type Identifier the view asks `NSWorkspace` an icon for.
	var typeIdentifier: String {
		switch self {
		case .folder: "public.folder"
		case .pdf: "com.adobe.pdf"
		case .jpeg: "public.jpeg"
		case .png: "public.png"
		case .text: "public.plain-text"
		case .zip: "public.zip-archive"
		case .movie: "com.apple.quicktime-movie"
		}
	}

	/// The "종류" column's words (the app's own, in the app's language; `UTType.localizedDescription` would follow the
	/// system's language).
	var kindName: String {
		switch self {
		case .folder: String(localized: "폴더")
		case .pdf: String(localized: "PDF 문서")
		case .jpeg: String(localized: "JPEG 이미지")
		case .png: String(localized: "PNG 이미지")
		case .text: String(localized: "일반 텍스트 문서")
		case .zip: String(localized: "ZIP 아카이브")
		case .movie: String(localized: "QuickTime 동영상")
		}
	}
}

/// The drawn picture of a sample while icon previews are on (the view draws them in code: no image file).
enum PreviewThumbnail: String, Sendable {
	case trip, beach, walk, screenshot, movie, pdf, text

	/// Width ÷ height of the picture.
	var aspect: Double {
		switch self {
		case .trip, .beach: 4.0 / 3.0
		case .walk: 3.0 / 4.0
		case .screenshot: 16.0 / 10.0
		case .movie: 16.0 / 9.0
		case .pdf, .text: 0.77
		}
	}
}

enum PreviewTag: String, Sendable {
	case red, blue

	/// Finder's tag order (red, orange, yellow, green, blue, purple, gray).
	var rank: Int { self == .red ? 0 : 4 }
	var name: String { self == .red ? String(localized: "빨간색") : String(localized: "파란색") }
}

struct PreviewSample: Identifiable, Equatable, Sendable {
	var id: String
	var name: String
	var type: PreviewFileType
	var bytes: Int64
	var itemCount: Int?
	var pixels: (width: Int, height: Int)?
	var duration: Int?
	var modified: Date
	var created: Date
	var added: Date
	var lastOpened: Date?
	var tags: [PreviewTag] = []
	var thumbnail: PreviewThumbnail?
	/// Its place while the icon view is arranged by "없음" (Finder's free positions; fixed here).
	var freeSlot: Int
	/// Which samples stay when not all fit: a folder and an image first.
	var priority: Int

	var isFolder: Bool { type == .folder }

	static func == (a: PreviewSample, b: PreviewSample) -> Bool {
		a.id == b.id && a.name == b.name && a.type == b.type && a.bytes == b.bytes && a.itemCount == b.itemCount
			&& a.pixels?.width == b.pixels?.width && a.pixels?.height == b.pixels?.height && a.duration == b.duration
			&& a.modified == b.modified && a.created == b.created && a.added == b.added && a.lastOpened == b.lastOpened
			&& a.tags == b.tags && a.thumbnail == b.thumbnail && a.freeSlot == b.freeSlot && a.priority == b.priority
	}

	/// The sample folder: two folders, two images, a movie, a PDF, a text and an archive, with distinct modified,
	/// created, added and last opened dates (relative to `now`: whole days back at a clock time of their own, so the
	/// list does not show one time everywhere; "today" stays today and not later than `now`), sizes, tags, an item count,
	/// pixel sizes and a duration, so every sort, grouping and item info differs.
	static func folder(now: Date, calendar: Calendar) -> [PreviewSample] {
		let at = SampleClock(now: now, calendar: calendar)
		func today(_ h: Int, _ m: Int) -> Date { at.today(h, m) }
		func ago(_ days: Int, _ h: Int, _ m: Int) -> Date { at.ago(days, h, m) }
		return [
			PreviewSample(id: "photos", name: String(localized: "사진"), type: .folder, bytes: 240_000_000, itemCount: 12,
			              modified: ago(3, 18, 12), created: ago(250, 10, 4), added: ago(250, 10, 5), lastOpened: today(11, 20), tags: [.blue],
			              freeSlot: 0, priority: 0),
			PreviewSample(id: "trip", name: String(localized: "여행 사진.jpg"), type: .jpeg, bytes: 3_400_000, pixels: (4032, 3024),
			              modified: ago(40, 16, 48), created: ago(40, 16, 47), added: ago(12, 21, 3), lastOpened: ago(40, 17, 30), thumbnail: .trip,
			              freeSlot: 2, priority: 1),
			PreviewSample(id: "projects", name: String(localized: "프로젝트"), type: .folder, bytes: 18_400_000, itemCount: 4,
			              modified: today(12, 41), created: ago(400, 9, 15), added: ago(400, 9, 16), lastOpened: ago(1, 22, 10), freeSlot: 3, priority: 2),
			PreviewSample(id: "screenshot", name: String(localized: "스크린샷.png"), type: .png, bytes: 820_000, pixels: (1440, 900),
			              modified: today(9, 26), created: today(9, 26), added: today(9, 26), lastOpened: nil,
			              thumbnail: .screenshot, freeSlot: 7, priority: 3),
			PreviewSample(id: "talk", name: String(localized: "발표 영상.mov"), type: .movie, bytes: 120_000_000, duration: 134,
			              modified: ago(200, 15, 2), created: ago(200, 14, 55), added: ago(6, 8, 37), lastOpened: ago(8, 19, 44), thumbnail: .movie,
			              freeSlot: 4, priority: 4),
			PreviewSample(id: "report", name: String(localized: "보고서.pdf"), type: .pdf, bytes: 1_200_000,
			              modified: ago(1, 17, 5), created: ago(20, 11, 30), added: ago(20, 11, 31), lastOpened: ago(2, 9, 58), tags: [.red], thumbnail: .pdf,
			              freeSlot: 5, priority: 5),
			PreviewSample(id: "notes", name: String(localized: "메모.txt"), type: .text, bytes: 2_000,
			              modified: ago(560, 23, 18), created: ago(700, 7, 45), added: ago(600, 13, 9), lastOpened: ago(45, 20, 26), thumbnail: .text,
			              freeSlot: 1, priority: 6),
			PreviewSample(id: "archive", name: String(localized: "자료 모음.zip"), type: .zip, bytes: 48_000_000,
			              modified: ago(9, 14, 20), created: ago(9, 14, 19), added: ago(2, 10, 12), lastOpened: nil, freeSlot: 6, priority: 7)
		]
	}

	/// What the "사진" folder holds (the column view's second column).
	static func photos(now: Date, calendar: Calendar) -> [PreviewSample] {
		let at = SampleClock(now: now, calendar: calendar)
		func ago(_ days: Int, _ h: Int, _ m: Int) -> Date { at.ago(days, h, m) }
		return [
			PreviewSample(id: "photos-2025", name: "2025", type: .folder, bytes: 96_000_000, itemCount: 30,
			              modified: ago(120, 13, 2), created: ago(300, 9, 40), added: ago(300, 9, 41), lastOpened: ago(90, 21, 7), freeSlot: 0, priority: 2),
			PreviewSample(id: "photos-beach", name: String(localized: "바다.jpg"), type: .jpeg, bytes: 2_800_000, pixels: (4032, 3024),
			              modified: ago(3, 16, 22), created: ago(3, 16, 22), added: ago(3, 16, 23), lastOpened: ago(3, 18, 0), thumbnail: .beach, freeSlot: 1, priority: 0),
			PreviewSample(id: "photos-walk", name: String(localized: "산책.jpg"), type: .jpeg, bytes: 2_100_000, pixels: (3024, 4032),
			              modified: ago(5, 7, 51), created: ago(5, 7, 51), added: ago(5, 7, 52), lastOpened: nil, thumbnail: .walk, freeSlot: 2, priority: 1)
		]
	}
}

/// The samples' dates: a number of whole days before `now` at a clock time (so the day, which decides every order and
/// group, never depends on the time of day), and today's times never later than `now` (just after midnight they are
/// midnight, keeping their order).
struct SampleClock {
	var now: Date
	var calendar: Calendar

	func ago(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
		let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
		return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
	}

	/// The latest clock time a sample has today (12:41); before it, every time today is squeezed into the day so far.
	static let latestToday: TimeInterval = 13 * 3600

	/// Today at a time: at most `now`, and always in the order of the times.
	func today(_ hour: Int, _ minute: Int) -> Date {
		let start = calendar.startOfDay(for: now)
		let seconds = TimeInterval(hour * 3600 + minute * 60)
		let elapsed = now.timeIntervalSince(start)
		if elapsed >= Self.latestToday { return start.addingTimeInterval(seconds) }
		// Early in the day: all of today's times scaled into the time so far (one rule for all, so the order stays).
		return start.addingTimeInterval(elapsed * seconds / Self.latestToday)
	}
}

// MARK: Defaults ("유지")

/// Finder's current defaults as the preview uses them for "유지": the default view, the effective icon and list values,
/// and each list column's own sort direction.
struct PreviewDefaults: Equatable, Sendable {
	var viewStyle: ViewStyle?
	var settings: ViewSettings
	var columnAscending: [ListColumn: Bool]
	/// Finder's "Keep folders on top: In windows when sorting by name" (`_FXSortFoldersFirst`, read by the app).
	var foldersFirst: Bool

	init(_ globals: GlobalDefaults, foldersFirst: Bool = false) {
		self.foldersFirst = foldersFirst
		viewStyle = globals.preferredViewStyle
		settings = globals.effectiveSettings
		var ascending: [ListColumn: Bool] = [:]
		for column in ListColumn.allCases {
			// The column's own entry, read the way a folder's is (the sort column's entry holds the direction).
			for plist in [globals.listArrayPlist, ViewRecordCodec.factoryListPlist] {
				var p = plist
				p["sortColumn"] = column.rawValue
				if let a = ViewRecordCodec.decodeList(p).sortAscending { ascending[column] = a; break }
			}
		}
		columnAscending = ascending
	}

	static let factory = PreviewDefaults(GlobalDefaults.factory)

	/// The direction a folder sorted by `column` gets when the preset leaves the direction alone: that column's own entry.
	func ascending(for column: ListColumn) -> Bool {
		columnAscending[column] ?? ![.dateModified, .dateCreated, .dateAdded, .dateLastOpened, .size].contains(column)
	}
}

// MARK: Following the editor

/// What the preview draws from the editor's draft: its valid values (a typed number as it is saved, clamped: "1" on the
/// way to "128" draws 16), where a text that is not a number ("abc", "12x") keeps the last valid value instead of falling
/// back to "유지" and back.
struct PreviewTracker: Equatable, Sendable {
	private(set) var name: String
	private(set) var settings: ViewSettings

	init(_ draft: PresetDraft) {
		name = draft.name
		settings = draft.previewSettings
	}

	mutating func follow(_ draft: PresetDraft) {
		let before = settings
		var next = draft.previewSettings
		for number in PresetDraft.Number.allCases {
			guard case .failure = draft.value(number) else { continue }
			switch number {
			case .iconSize: next.icon.iconSize = before.icon.iconSize
			case .iconTextSize: next.icon.textSize = before.icon.textSize
			case .gridSpacing: next.icon.gridSpacing = before.icon.gridSpacing
			case .listTextSize: next.list.textSize = before.list.textSize
			}
		}
		name = draft.name
		settings = next
	}
}

// MARK: Measuring text

/// Width of a text in the system font of a size. The app passes AppKit's measurement; tests and the fallback use this
/// estimate (Hangul and other wide characters about one em, Latin about half).
enum PreviewText {
	static func estimate(_ text: String, _ size: Double) -> Double {
		var width = 0.0
		for scalar in text.unicodeScalars {
			let v = scalar.value
			switch v {
			case 0x1100...0x11FF, 0x3000...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF00...0xFF60: width += 0.95
			case 0x20: width += 0.28
			case 0x30...0x39: width += 0.58
			case 0x41...0x5A: width += 0.66
			case 0x2E, 0x2C, 0x3A, 0x2F, 0x6C, 0x69: width += 0.3
			default: width += 0.53
			}
		}
		return width * size
	}
}

// MARK: The preview

struct PresetPreview: Equatable {
	/// The content area below the header and above the footer of the preview window (Views/PresetPreviewWindow.swift).
	static let contentSize = CGSize(width: 520, height: 392)
	/// The largest icon side drawn at its real size (Finder's default icon size).
	static let largestRealIcon = 64.0
	/// The side drawn for the largest icon size (512). Chosen so that two groups one below the other (label below, two
	/// lines of 16pt text, item info, grid spacing 100) still show a folder and an image; a layout that still does not fit
	/// (the two groups apart, with the gap between them) is drawn with smaller icons (`iconGrid`).
	static let largestDrawnIcon = 96.0
	static let largestIconSize = 512.0

	/// The side an icon of `iconSize` is drawn with: its size up to `largestRealIcon`, then growing more slowly (evenly
	/// per doubling) up to `largestDrawnIcon` at 512, so every step of the slider still changes the picture.
	static func drawnIconSide(_ iconSize: Double) -> Double {
		guard iconSize.isFinite, iconSize > 0 else { return largestRealIcon }
		guard iconSize > largestRealIcon else { return iconSize }
		let doublings = log2(min(iconSize, largestIconSize) / largestRealIcon) / log2(largestIconSize / largestRealIcon)
		return largestRealIcon + (largestDrawnIcon - largestRealIcon) * doublings
	}

	/// The icon view's scale: 1 up to `largestRealIcon`, smaller beyond it. Depends on the icon size only.
	static func iconScale(_ iconSize: Double) -> Double {
		guard iconSize.isFinite, iconSize > 0 else { return 1 }
		return min(1, drawnIconSide(iconSize) / iconSize)
	}

	struct Item: Equatable, Identifiable {
		var id: String
		var name: String
		var type: PreviewFileType
		var thumbnail: PreviewThumbnail?
		var tags: [PreviewTag]
		/// The icon view's item info (blue line): folders their item count, images their pixels, movies their duration.
		var info: String?
	}

	struct Header: Equatable, Identifiable {
		var id: String
		var title: String
		var frame: CGRect
		/// Not a header Finder was seen to show: the wording or the assignment is the app's guess.
		var approximate: Bool
		/// Items of the group its row does not show (Finder draws a group as one row that scrolls sideways).
		var hidden: Int = 0
		/// The row is scrolled sideways (it starts after the group's first items) to show a folder or an image.
		var scrolled = false
	}

	struct IconCell: Equatable, Identifiable {
		var item: Item
		/// The whole item; `icon`, `label` and `info` are in the content area's coordinates too.
		var frame: CGRect
		var icon: CGRect
		var label: CGRect
		var labelLines: Int
		var info: CGRect?
		var id: String { item.id }
	}

	struct IconGrid: Equatable {
		var cells: [IconCell]
		var headers: [Header]
		/// Side of the drawn icons (the icon size × `scale`).
		var iconSide: Double
		var iconSize: Double
		var scale: Double
		var textSize: Double
		var labelOnBottom: Bool
		var showPreview: Bool
		var columns: Int
		/// "⋯" lines: rows or groups skipped in the order before the next one (see `PresetPreview.pick`).
		var gaps: [CGRect] = []
	}

	struct ListColumnSpec: Equatable, Identifiable {
		var id: ListColumn
		var title: String
		var x: Double
		var width: Double
		var trailing: Bool
		/// Nil: not the sort column; else its direction (▲ ascending, ▼ descending).
		var ascending: Bool?
	}

	struct ListRow: Equatable, Identifiable {
		var item: Item
		var y: Double
		/// One text per column, the name's first.
		var cells: [String]
		var stripe: Bool
		var id: String { item.id }
	}

	struct ListTable: Equatable {
		var columns: [ListColumnSpec]
		var rows: [ListRow]
		var headers: [Header]
		var headerHeight: Double
		var rowHeight: Double
		var textSize: Double
		var iconSide: Double
		var showPreview: Bool
		var dateFormat: DateFormat
		/// "⋯" lines: rows skipped in the order before the next one.
		var gaps: [CGRect] = []
	}

	struct ColumnRow: Equatable, Identifiable {
		var id: String
		var item: Item?
		var header: String?
		var y: Double
		var selected: Bool
		var isFolder: Bool
	}

	struct ColumnPane: Equatable {
		var x: Double
		var width: Double
		var rows: [ColumnRow]
	}

	struct ColumnBrowser: Equatable {
		var panes: [ColumnPane]
		var rowHeight: Double
		var previewX: Double
		var preview: Item
		var previewLines: [String]
	}

	struct Gallery: Equatable {
		var selected: Item
		var lines: [String]
		var strip: [Item]
		/// Shown over the picture when the preset groups: Finder's gallery view shows no groups.
		var note: String?
	}

	enum Content: Equatable {
		case icon(IconGrid)
		case list(ListTable)
		case column(ColumnBrowser)
		case gallery(Gallery)
	}

	enum DateFormat: Int, CaseIterable, Sendable { case full, medium, short }

	/// The view drawn: the draft's, or Finder's default view when the draft leaves it alone.
	var view: ViewStyle
	var viewKept: Bool
	var content: Content
	var shownItems: Int
	var totalItems: Int
	/// "실제 크기의 75%" while icons are drawn smaller than their size.
	var scaleBadge: String?
	/// "8개 중 6개" while not every sample fits.
	var countBadge: String?
	var footerLeading: String
	var footerTrailing: String
	/// The footer's tooltip: the "유지" values with what is drawn for them, and what is approximate.
	var details: [String]
	/// The window's one accessibility element.
	var summary: String

	// MARK: Making

	static func make(settings: ViewSettings, globals: GlobalDefaults, locale: Locale, now: Date,
	                 calendar: Calendar = .current, measure: (String, Double) -> Double = PreviewText.estimate) -> PresetPreview {
		make(settings: settings, defaults: PreviewDefaults(globals), locale: locale, now: now, calendar: calendar, measure: measure)
	}

	/// `locale`: the app's language (dates, numbers, month names); the texts themselves come from the app's tables.
	/// `calendar`: its time zone decides "today". `measure`: text width (see `PreviewText`).
	static func make(settings draft: ViewSettings, defaults: PreviewDefaults, locale: Locale, now: Date,
	                 calendar: Calendar = .current, measure: (String, Double) -> Double = PreviewText.estimate) -> PresetPreview {
		var calendar = calendar
		calendar.locale = locale
		let format = PreviewFormat(locale: locale, calendar: calendar, now: now)
		let resolved = resolve(draft, defaults)
		let view = draft.viewStyle ?? defaults.viewStyle ?? .icon
		let samples = PreviewSample.folder(now: now, calendar: calendar)
		let foldersFirst = defaults.foldersFirst
		var kept: [(String, String)] = []   // (option, value drawn)
		var details: [String] = []
		var approximateHeaders: [String] = []
		let content: Content
		var shown = samples.count
		var scaleBadge: String?
		var skipped = false

		switch view {
		case .icon:
			let i = draft.icon, r = resolved.icon
			if i.arrangeBy == nil { kept.append((String(localized: "정렬 기준"), Fmt.sort(r.arrangeBy ?? SortKey.none))) }
			if i.iconSize == nil { kept.append((String(localized: "아이콘 크기"), Fmt.number(r.iconSize ?? 64))) }
			if i.gridSpacing == nil { kept.append((String(localized: "격자 간격"), Fmt.number(r.gridSpacing ?? 54))) }
			if i.textSize == nil { kept.append((String(localized: "텍스트 크기"), Fmt.number(r.textSize ?? 12))) }
			if i.labelOnBottom == nil {
				kept.append((String(localized: "레이블 위치"), r.labelOnBottom == false ? String(localized: "오른쪽") : String(localized: "아래")))
			}
			if i.showItemInfo == nil { kept.append((String(localized: "항목 정보"), Fmt.onOff(r.showItemInfo ?? false))) }
			if i.showIconPreview == nil { kept.append((String(localized: "아이콘 미리보기"), Fmt.onOff(r.showIconPreview ?? true))) }
			let grid = iconGrid(samples, resolved, format: format, foldersFirst: foldersFirst, measure: measure)
			content = .icon(grid)
			shown = grid.cells.count
			skipped = !grid.gaps.isEmpty
			approximateHeaders = grid.headers.filter(\.approximate).map(\.title)
			if grid.scale < 1 {
				let percent = Int((grid.scale * 100).rounded())
				scaleBadge = String(localized: "실제 크기의 \(percent)%")
				details.append(String(localized: "아이콘 \(Fmt.number(grid.iconSize))을(를) 실제 크기의 \(percent)%로 줄여 그렸습니다. 글자는 실제 크기입니다."))
			}
			if grid.headers.contains(where: \.scrolled) { skipped = true }
			if grid.headers.contains(where: { $0.hidden > 0 }) {
				details.append(String(localized: "묶음마다 한 줄로 그렸습니다(Finder는 그 줄을 옆으로 넘겨 봅니다). 머리글 오른쪽의 수는 그 줄에 보이지 않는 항목입니다."))
			}
			details.append(String(localized: "근사: 항목 간격(격자 간격), 레이블 줄바꿈, 항목 정보, 아이콘 미리보기 그림, 정렬 \"없음\"의 자리(고정)."))
		case .list:
			let l = draft.list, r = resolved.list
			if l.sortColumn == nil { kept.append((String(localized: "정렬 열"), Fmt.column(r.sortColumn ?? .name))) }
			if l.sortAscending == nil {
				kept.append((String(localized: "정렬 방향"), r.sortAscending == false ? String(localized: "내림차순") : String(localized: "오름차순")))
			}
			if l.iconSize == nil { kept.append((String(localized: "아이콘 크기"), Fmt.number(r.iconSize ?? 16))) }
			if l.textSize == nil { kept.append((String(localized: "텍스트 크기"), Fmt.number(r.textSize ?? 13))) }
			if l.useRelativeDates == nil { kept.append((String(localized: "상대적 날짜"), Fmt.onOff(r.useRelativeDates ?? true))) }
			if l.calculateAllSizes == nil { kept.append((String(localized: "모든 크기 계산"), Fmt.onOff(r.calculateAllSizes ?? false))) }
			if l.showIconPreview == nil { kept.append((String(localized: "아이콘 미리보기"), Fmt.onOff(r.showIconPreview ?? true))) }
			let table = listTable(samples, resolved, format: format, foldersFirst: foldersFirst, measure: measure)
			content = .list(table)
			shown = table.rows.count
			skipped = !table.gaps.isEmpty
			approximateHeaders = table.headers.filter(\.approximate).map(\.title)
			details.append(String(localized: "근사: 열 너비와 날짜 형식, 행 높이, 상대적 날짜, 모든 크기 계산, 아이콘 미리보기 그림."))
		case .column:
			let browser = columnBrowser(samples, resolved, format: format, foldersFirst: foldersFirst)
			content = .column(browser)
			approximateHeaders = browser.panes.flatMap(\.rows).compactMap(\.header).filter { !observedHeaders.contains($0) || !format.isKorean }
			details.append(String(localized: "컬럼 보기: 이름순으로 그렸습니다(이 보기의 정렬은 프리셋에 없음). 묶음 머리글은 근사입니다."))
		case .gallery:
			content = .gallery(gallery(samples, groupBy: resolved.groupBy, format: format, foldersFirst: foldersFirst))
			details.append(String(localized: "갤러리 보기: Finder는 묶음을 보이지 않습니다. 이름순으로 그렸습니다(이 보기의 정렬은 프리셋에 없음)."))
		}
		if draft.groupBy == nil && view != .gallery {
			kept.append((String(localized: "그룹 기준"), String(localized: "묶지 않음")))
			details.append(String(localized: "그룹 기준 유지: 폴더마다 다르므로 묶지 않고 그렸습니다."))
		}
		if foldersFirst {
			details.append(String(localized: "Finder 설정 \"이름순 정렬 시 폴더를 위에 유지\"가 켜져 있어 이름순에서 폴더를 먼저 그렸습니다."))
		}
		if !approximateHeaders.isEmpty {
			details.append(String(localized: "근사한 묶음(머리글이나 들어간 항목): \(approximateHeaders.joined(separator: ", "))"))
		}
		var countBadge: String?
		if shown < samples.count {
			countBadge = String(localized: "\(samples.count)개 중 \(shown)개")
			details.append(String(localized: "예시 항목 \(samples.count)개 중 \(shown)개만 그렸습니다: Finder 창을 맨 위에서 본 모습입니다."))
		}
		if skipped {
			details.append(String(localized: "\"⋯\": 폴더와 이미지가 늘 보이도록 순서상 그 사이의 항목을 건너뛰었습니다."))
		}
		for (option, value) in kept.reversed() {
			details.insert(String(localized: "\(option) 유지(폴더마다 지금 값 그대로) · 그린 값: \(value)"), at: 0)
		}
		if draft.viewStyle == nil {
			details.insert(String(localized: "보기 방식 유지: Finder 기본 보기(\(EditorText.viewTitle(view)))로 그렸습니다."), at: 0)
		}

		// The view style counts as one kept value too; each is drawn with Finder's current defaults.
		let keptCount = kept.count + (draft.viewStyle == nil ? 1 : 0)
		let keptText = String(localized: "유지 \(keptCount)개: Finder 기본값으로 그림")
		var leading = EditorText.viewTitle(view)
		if keptCount > 0 { leading += " · " + keptText }
		let trailing = String(localized: "예시 · 실제 Finder와 다를 수 있음")

		// The window's accessibility value (its label is "미리보기").
		var summary = [EditorText.viewTitle(view)]
		if draft.viewStyle == nil { summary.append(String(localized: "보기 방식 유지, Finder 기본 보기")) }
		summary.append(contentsOf: optionSummary(view, resolved))
		if let scaleBadge { summary.append(scaleBadge) }
		if keptCount > 0 { summary.append(keptText) }
		if let countBadge { summary.append(String(localized: "예시 항목 \(countBadge)")) }
		summary.append(trailing)

		return PresetPreview(view: view, viewKept: draft.viewStyle == nil, content: content, shownItems: shown, totalItems: samples.count,
		                     scaleBadge: scaleBadge, countBadge: countBadge, footerLeading: leading, footerTrailing: trailing,
		                     details: details, summary: summary.joined(separator: ", "))
	}

	/// The draft over Finder's defaults. A sort column set without a direction takes that column's own direction; a
	/// kept grouping stays nil (not grouped).
	static func resolve(_ draft: ViewSettings, _ defaults: PreviewDefaults) -> ViewSettings {
		var r = draft.filling(from: defaults.settings)
		r.groupBy = draft.groupBy
		let column = draft.list.sortColumn ?? defaults.settings.list.sortColumn ?? .name
		r.list.sortColumn = column
		if let ascending = draft.list.sortAscending, draft.list.sortColumn != nil {
			r.list.sortAscending = ascending
		} else if draft.list.sortColumn != nil {
			r.list.sortAscending = defaults.ascending(for: column)
		} else {
			r.list.sortAscending = defaults.settings.list.sortAscending ?? defaults.ascending(for: column)
		}
		return r
	}

	private static func optionSummary(_ view: ViewStyle, _ r: ViewSettings) -> [String] {
		var out: [String] = []
		switch view {
		case .icon:
			out.append(String(localized: "아이콘 크기") + " " + Fmt.number(r.icon.iconSize ?? 64))
			out.append(String(localized: "텍스트 크기") + " " + Fmt.number(r.icon.textSize ?? 12))
			out.append(String(localized: "격자 간격") + " " + Fmt.number(r.icon.gridSpacing ?? 54))
			out.append(String(localized: "정렬 기준") + " " + Fmt.sort(r.icon.arrangeBy ?? SortKey.none))
			out.append(String(localized: "레이블 위치") + " " + (r.icon.labelOnBottom == false ? String(localized: "오른쪽") : String(localized: "아래")))
			out.append(String(localized: "항목 정보") + " " + Fmt.onOff(r.icon.showItemInfo ?? false))
			out.append(String(localized: "아이콘 미리보기") + " " + Fmt.onOff(r.icon.showIconPreview ?? true))
		case .list:
			out.append(String(localized: "정렬 열") + " " + Fmt.column(r.list.sortColumn ?? .name) + " "
			           + (r.list.sortAscending == false ? String(localized: "내림차순") : String(localized: "오름차순")))
			out.append(String(localized: "아이콘 크기") + " " + Fmt.number(r.list.iconSize ?? 16))
			out.append(String(localized: "텍스트 크기") + " " + Fmt.number(r.list.textSize ?? 13))
			out.append(String(localized: "상대적 날짜") + " " + Fmt.onOff(r.list.useRelativeDates ?? true))
			out.append(String(localized: "모든 크기 계산") + " " + Fmt.onOff(r.list.calculateAllSizes ?? false))
			out.append(String(localized: "아이콘 미리보기") + " " + Fmt.onOff(r.list.showIconPreview ?? true))
		case .column, .gallery:
			break
		}
		if view != .gallery, let group = r.groupBy, group != .none { out.append(String(localized: "그룹 기준") + " " + Fmt.group(group)) }
		return out
	}

	// MARK: Order and groups

	/// Folders before files, each keeping its order: Finder's "Keep folders on top when sorting by name".
	static func foldersOnTop(_ items: [PreviewSample]) -> [PreviewSample] {
		items.filter(\.isFolder) + items.filter { !$0.isFolder }
	}

	/// The icon view's order for an arrangement: name A→Z (folders first with `foldersFirst`), kind then name, dates
	/// newest first (never opened last), size largest first (folders, whose size the icon view does not show, last),
	/// tags in Finder's tag order then untagged by name, "없음" and "자동 격자 정렬" Finder's free positions (fixed here: the
	/// sample has no places of its own, and snapping them to the grid does not change their order).
	static func iconOrder(_ items: [PreviewSample], by key: SortKey, locale: Locale, foldersFirst: Bool = false) -> [PreviewSample] {
		func name(_ a: PreviewSample, _ b: PreviewSample) -> Bool { compareNames(a.name, b.name, locale) == .orderedAscending }
		func newest(_ x: Date?, _ y: Date?, _ a: PreviewSample, _ b: PreviewSample) -> Bool {
			switch (x, y) {
			case let (x?, y?) where x != y: x > y
			case (_?, nil): true
			case (nil, _?): false
			default: name(a, b)
			}
		}
		switch key {
		case .none, .grid: return items.sorted { $0.freeSlot < $1.freeSlot }
		case .name:
			let sorted = items.sorted(by: name)
			return foldersFirst ? foldersOnTop(sorted) : sorted
		case .kind:
			return items.sorted { a, b in
				let k = compareNames(a.type.kindName, b.type.kindName, locale)
				return k == .orderedSame ? name(a, b) : k == .orderedAscending
			}
		case .dateModified: return items.sorted { newest($0.modified, $1.modified, $0, $1) }
		case .dateCreated: return items.sorted { newest($0.created, $1.created, $0, $1) }
		case .dateAdded: return items.sorted { newest($0.added, $1.added, $0, $1) }
		case .dateLastOpened: return items.sorted { newest($0.lastOpened, $1.lastOpened, $0, $1) }
		case .size:
			return items.sorted { a, b in
				if a.isFolder != b.isFolder { return !a.isFolder }
				return a.bytes == b.bytes ? name(a, b) : a.bytes > b.bytes
			}
		case .label:
			return items.sorted { a, b in
				let x = a.tags.map(\.rank).min() ?? 99, y = b.tags.map(\.rank).min() ?? 99
				return x == y ? name(a, b) : x < y
			}
		}
	}

	/// The list view's order: ascending is A→Z, oldest first, smallest first (folders without a calculated size first);
	/// descending is the reverse. Columns every sample has empty (version, comments) keep the name order. By name with
	/// `foldersFirst`, folders stay on top in both directions.
	static func listOrder(_ items: [PreviewSample], column: ListColumn, ascending: Bool, calculateSizes: Bool, locale: Locale,
	                      foldersFirst: Bool = false) -> [PreviewSample] {
		func name(_ a: PreviewSample, _ b: PreviewSample) -> ComparisonResult { compareNames(a.name, b.name, locale) }
		func date(_ d: Date?) -> Date { d ?? .distantPast }
		func primary(_ a: PreviewSample, _ b: PreviewSample) -> ComparisonResult {
			func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
			switch column {
			case .name: return .orderedSame
			case .dateModified: return cmp(a.modified, b.modified)
			case .dateCreated: return cmp(a.created, b.created)
			case .dateAdded: return cmp(a.added, b.added)
			case .dateLastOpened: return cmp(date(a.lastOpened), date(b.lastOpened))
			case .size:
				func size(_ s: PreviewSample) -> Int64 { s.isFolder && !calculateSizes ? -1 : s.bytes }
				return cmp(size(a), size(b))
			case .kind: return compareNames(a.type.kindName, b.type.kindName, locale)
			case .label: return cmp(a.tags.map(\.rank).min() ?? 99, b.tags.map(\.rank).min() ?? 99)
			case .version, .comments: return .orderedSame
			}
		}
		let order: [PreviewSample]
		if ascending {
			order = items.sorted { a, b in
				let p = primary(a, b)
				return p == .orderedSame ? name(a, b) == .orderedAscending : p == .orderedAscending
			}
		} else {
			// Descending reverses the column; items equal in it stay in name order.
			order = items.sorted { a, b in
				let p = primary(a, b)
				if p == .orderedSame { return column == .name ? name(a, b) == .orderedDescending : name(a, b) == .orderedAscending }
				return p == .orderedDescending
			}
		}
		return column == .name && foldersFirst ? foldersOnTop(order) : order
	}

	static func compareNames(_ a: String, _ b: String, _ locale: Locale) -> ComparisonResult {
		a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: locale)
	}

	/// The headers Finder 26 was seen showing (Korean): kind "폴더", "문서", "이미지", "기타"; application
	/// "기타", "미리보기"; dates "오늘", "더 이전 날짜" and years; size "1MB에서 10MB까지", "100바이트 미만".
	static let observedHeaders: Set<String> = ["폴더", "문서", "이미지", "기타", "미리보기", "오늘", "더 이전 날짜", "1MB에서 10MB까지", "100바이트 미만"]   // l10n-exempt
	/// The file types seen grouped (a folder, text files, a PNG image; the 3MB file had no known kind): only
	/// their assignments to a header were seen. A PDF, a JPEG, a movie or an archive under a header is the app's guess.
	static let observedTypes: Set<PreviewFileType> = [.folder, .text, .png]

	struct Group: Equatable {
		var title: String
		var rank: Int
		/// The header or one of its items' assignment is the app's guess.
		var approximate: Bool
		var items: [PreviewSample]
	}

	/// The samples in groups for a grouping (nil or "없음": one group without a header), groups in Finder's order,
	/// items in the order they came. `calculateSizes`: the view shows folder sizes (the list with "모든 크기 계산").
	static func groups(_ items: [PreviewSample], by group: GroupBy?, format: PreviewFormat, calculateSizes: Bool = false) -> [Group] {
		guard let group, group != .none else { return [Group(title: "", rank: 0, approximate: false, items: items)] }
		var out: [String: Group] = [:]
		var order: [String] = []
		for item in items {
			let key = groupKey(item, group, format: format, calculateSizes: calculateSizes)
			if out[key.title] == nil {
				out[key.title] = Group(title: key.title, rank: key.rank, approximate: false, items: [])
				order.append(key.title)
			}
			out[key.title]?.items.append(item)
			if key.approximate { out[key.title]?.approximate = true }
		}
		return order.compactMap { out[$0] }.sorted { a, b in
			a.rank == b.rank ? compareNames(a.title, b.title, format.locale) == .orderedAscending : a.rank < b.rank
		}
	}

	/// The header of a sample for a grouping. `approximate`: Finder was not seen putting such a file under such a
	/// header.
	static func groupKey(_ item: PreviewSample, _ group: GroupBy, format: PreviewFormat, calculateSizes: Bool = false)
		-> (title: String, rank: Int, approximate: Bool) {
		func observed(_ title: String, _ tested: Bool = true) -> Bool { format.isKorean && tested && observedHeaders.contains(title) }
		let tested = observedTypes.contains(item.type)
		switch group {
		case .none:
			return ("", 0, false)
		case .kind:
			// Spotlight's kinds (Finder also showed "개발자"): a PDF has a kind of its own there.
			let (title, rank): (String, Int) = switch item.type {
			case .folder: (String(localized: "폴더"), 0)
			case .text: (String(localized: "문서"), 1)
			case .pdf: (String(localized: "PDF 문서"), 2)
			case .jpeg, .png: (String(localized: "이미지"), 3)
			case .movie: (String(localized: "동영상"), 4)
			case .zip: (String(localized: "기타"), 9)
			}
			return (title, rank, !observed(title, tested))
		case .application:
			let title: String = switch item.type {
			case .folder: String(localized: "기타")
			case .pdf, .jpeg, .png: String(localized: "미리보기")
			case .text: String(localized: "텍스트 편집기")
			case .zip: String(localized: "압축 해제 유틸리티")
			case .movie: "QuickTime Player"
			}
			return (title, item.isFolder ? 9 : 0, !observed(title, item.type == .folder || item.type == .png))
		case .dateModified, .dateCreated, .dateAdded, .dateLastOpened:
			let date: Date? = switch group {
			case .dateModified: item.modified
			case .dateCreated: item.created
			case .dateAdded: item.added
			default: item.lastOpened
			}
			let bucket = format.dateGroup(date)
			return (bucket.title, bucket.rank, !(format.isKorean && bucket.observed))
		case .size:
			// A folder whose size the view does not show ("--") has no size to group by: one last group, a guess.
			if item.isFolder && !calculateSizes { return ("--", 1_000, true) }
			let buckets: [(Int64, String)] = [
				(100_000_000, String(localized: "100MB에서 1GB까지")), (10_000_000, String(localized: "10MB에서 100MB까지")),
				(1_000_000, String(localized: "1MB에서 10MB까지")), (100_000, String(localized: "100KB에서 1MB까지")),
				(1_000, String(localized: "1KB에서 100KB까지")), (100, String(localized: "100바이트에서 1KB까지")),
				(0, String(localized: "100바이트 미만"))
			]
			let index = buckets.firstIndex { item.bytes >= $0.0 } ?? buckets.count - 1
			return (buckets[index].1, index, !observed(buckets[index].1, !item.isFolder))
		}
	}

	// MARK: What is visible

	/// What the preview must always show: a folder and an image.
	enum Need: CaseIterable, Sendable { case folder, image }

	static func needs(_ items: [PreviewSample]) -> Set<Need> {
		var out: Set<Need> = []
		for s in items {
			if s.isFolder { out.insert(.folder) }
			if s.type == .jpeg || s.type == .png { out.insert(.image) }
		}
		return out
	}

	/// One unit drawn: a row or a group (by its index in the full order); `focus`: a group row scrolled sideways to
	/// show that need (its first items do not have it).
	struct Pick: Equatable, Sendable {
		var index: Int
		var focus: Need?
	}

	/// The units a Finder window scrolled to its top shows: the longest prefix of the order that `fits`. Only when that
	/// prefix has no folder or no image, the first later unit that has it follows after a "⋯" (a pick whose index does
	/// not follow the previous one), and the prefix's last units that are not needed give way until it fits. A group
	/// whose row hides the need (`any` but not `visible`) is scrolled sideways to it (`focus`) instead.
	static func pick(count: Int, visible: (Int) -> Set<Need>, any: (Int) -> Set<Need>, fits: ([Pick]) -> Bool) -> [Pick] {
		var prefix = 0
		while prefix < count, fits((0...prefix).map { Pick(index: $0) }) { prefix += 1 }
		var picks = (0..<prefix).map { Pick(index: $0) }
		func has(_ picks: [Pick]) -> Set<Need> {
			picks.reduce(into: Set<Need>()) { $0.formUnion($1.focus.map { [$0] } ?? visible($1.index)) }
		}
		for need in Need.allCases where !has(picks).contains(need) {
			if let j = (prefix..<count).first(where: { visible($0).contains(need) }) {
				if !picks.contains(where: { $0.index == j }) { picks.append(Pick(index: j)) }
			} else if let j = (0..<count).first(where: { any($0).contains(need) }) {
				if let i = picks.firstIndex(where: { $0.index == j }) { picks[i].focus = need } else { picks.append(Pick(index: j, focus: need)) }
			}
		}
		picks.sort { $0.index < $1.index }
		while !fits(picks) {
			let needed = has(picks)
			guard let r = picks.lastIndex(where: { p in p.index < prefix && p.focus == nil && has(picks.filter { $0 != p }) == needed }) else { break }
			picks.remove(at: r)
		}
		return picks
	}

	static func item(_ s: PreviewSample, format: PreviewFormat) -> Item {
		Item(id: s.id, name: s.name, type: s.type, thumbnail: s.thumbnail, tags: s.tags, info: format.info(s))
	}

	/// A tag's dot after a name, joined to it by a no-break space (never wrapped onto a line of its own).
	static let tagMark = "\u{00A0}●"   // l10n-exempt

	/// A label as it is drawn and measured: the name, then a dot per tag.
	static func labelText(_ name: String, tags: Int) -> String { name + String(repeating: tagMark, count: tags) }

	// MARK: Icon view

	/// `iconSide`: the largest side to draw the icons with (nil: `drawnIconSide`). When what the preview must show (a
	/// folder and an image) does not fit the box at that side — two groups that are not next to each other, with long
	/// labels and item info under 512pt icons — it is laid out again with smaller icons (down to 16pt), so nothing is
	/// ever drawn past the box; the footer's scale says how much smaller. The text keeps its real size.
	static func iconGrid(_ samples: [PreviewSample], _ r: ViewSettings, format: PreviewFormat, foldersFirst: Bool = false,
	                     measure: (String, Double) -> Double, iconSide: Double? = nil) -> IconGrid {
		let size = contentSize
		let iconSize = r.icon.iconSize.map { $0.isFinite && $0 > 0 ? $0 : 64 } ?? 64
		let natural = (iconSize * iconScale(iconSize)).rounded()
		let icon = min(natural, iconSide ?? natural)
		let scale = icon == natural ? iconScale(iconSize) : icon / iconSize
		let text = min(32, max(6, r.icon.textSize ?? 12))
		let spacing = min(200, max(0, r.icon.gridSpacing ?? 54))
		let bottom = r.icon.labelOnBottom != false
		let showInfo = r.icon.showItemInfo == true
		let line = (text * 1.25).rounded(.up)
		let infoHeight = showInfo ? line : 0
		let margin = 12.0, top = 10.0
		// Grid spacing is the room between items: from about 2pt (1) to 52pt (100) across, 4–14pt down.
		let gapX = (2 + spacing * 0.5).rounded()
		let gapY = (4 + spacing * 0.1).rounded()
		let labelWidth = bottom ? max(icon + 8, (text * 6).rounded()) : (text * 9).rounded()
		let cellWidth = bottom ? labelWidth : icon + 6 + labelWidth
		let columns = max(1, Int((size.width - 2 * margin + gapX) / (cellWidth + gapX)))
		let headerHeight = 20.0
		let separator = 14.0

		/// One line or two: the label is drawn 2pt inside its box on each side (`labelInset`), so it wraps exactly there.
		func lines(_ s: PreviewSample) -> Int { measure(labelText(s.name, tags: s.tags.count), text) > labelWidth - 2 * labelInset ? 2 : 1 }
		/// A row is as tall as its tallest label (one or two lines), like Finder's rows.
		func rowHeight(_ items: [PreviewSample]) -> Double {
			let most = Double(items.map(lines).max() ?? 1)
			return bottom ? icon + 4 + most * line + infoHeight : max(icon, most * line + infoHeight)
		}
		func cell(_ s: PreviewSample, x: Double, y: Double, height: Double) -> IconCell {
			let frame = CGRect(x: x, y: y, width: cellWidth, height: height)
			let lines = lines(s)
			if bottom {
				let iconRect = CGRect(x: x + (cellWidth - icon) / 2, y: y, width: icon, height: icon)
				let label = CGRect(x: x, y: iconRect.maxY + 4, width: cellWidth, height: Double(lines) * line)
				let info = showInfo ? CGRect(x: x, y: label.maxY, width: cellWidth, height: line) : nil
				return IconCell(item: item(s, format: format), frame: frame, icon: iconRect, label: label, labelLines: lines, info: info)
			}
			let block = Double(lines) * line + infoHeight
			let iconRect = CGRect(x: x, y: y + (height - icon) / 2, width: icon, height: icon)
			let label = CGRect(x: iconRect.maxX + 6, y: y + (height - block) / 2, width: labelWidth, height: Double(lines) * line)
			let info = showInfo ? CGRect(x: label.minX, y: label.maxY, width: labelWidth, height: line) : nil
			return IconCell(item: item(s, format: format), frame: frame, icon: iconRect, label: label, labelLines: lines, info: info)
		}

		struct Laid { var cells: [IconCell] = []; var headers: [Header] = []; var gaps: [CGRect] = []; var bottom = 0.0 }
		func row(_ items: [PreviewSample], y: Double, into laid: inout Laid) -> Double {
			let h = rowHeight(items)
			for (i, s) in items.enumerated() { laid.cells.append(cell(s, x: margin + Double(i) * (cellWidth + gapX), y: y, height: h)) }
			laid.bottom = max(laid.bottom, y + h)
			return y + h
		}
		func gap(_ y: Double, into laid: inout Laid) -> Double {
			laid.gaps.append(CGRect(x: margin, y: y, width: size.width - 2 * margin, height: separator))
			return y + separator
		}
		let limit = size.height - 2

		let ordered = iconOrder(samples, by: r.icon.arrangeBy ?? SortKey.none, locale: format.locale, foldersFirst: foldersFirst)
		let groups = self.groups(ordered, by: r.groupBy, format: format)
		var laid = Laid()
		if groups.count == 1 && groups[0].title.isEmpty {
			// Rows of `columns` items, in order, from the top.
			let rows = stride(from: 0, to: ordered.count, by: columns).map { Array(ordered[$0..<min(ordered.count, $0 + columns)]) }
			func layOut(_ picks: [Pick]) -> Laid {
				var laid = Laid()
				var y = top, previous = -1
				for p in picks {
					if p.index != previous + 1 { y = gap(y, into: &laid) }
					y = row(rows[p.index], y: y, into: &laid) + gapY
					previous = p.index
				}
				return laid
			}
			laid = layOut(pick(count: rows.count, visible: { needs(rows[$0]) }, any: { needs(rows[$0]) }, fits: { layOut($0).bottom <= limit }))
		} else {
			// Finder draws a group as one row under its header, scrolling sideways: the row shows `columns` items.
			func shown(_ g: Group, focus: Need?) -> (items: [PreviewSample], scrolled: Bool) {
				var start = 0
				if let focus, let i = g.items.firstIndex(where: { needs([$0]).contains(focus) }) { start = max(0, min(i, g.items.count - columns)) }
				return (Array(g.items[start..<min(g.items.count, start + columns)]), start > 0)
			}
			func layOut(_ picks: [Pick]) -> Laid {
				var laid = Laid()
				var y = 4.0, previous = -1
				for p in picks {
					if p.index != previous + 1 { y = gap(y, into: &laid) }
					let g = groups[p.index]
					let (items, scrolled) = shown(g, focus: p.focus)
					let header = Header(id: "h-" + g.title, title: g.title, frame: CGRect(x: margin, y: y, width: size.width - 2 * margin, height: headerHeight),
					                    approximate: g.approximate, hidden: g.items.count - items.count, scrolled: scrolled)
					laid.headers.append(header)
					laid.bottom = max(laid.bottom, header.frame.maxY)
					y = row(items, y: y + headerHeight + 4, into: &laid) + gapY
					previous = p.index
				}
				return laid
			}
			laid = layOut(pick(count: groups.count, visible: { needs(Array(groups[$0].items.prefix(columns))) }, any: { needs(groups[$0].items) },
			                   fits: { layOut($0).bottom <= limit }))
		}
		if laid.bottom > limit, icon > 16 {
			return iconGrid(samples, r, format: format, foldersFirst: foldersFirst, measure: measure, iconSide: max(16, (icon * 0.85).rounded(.down)))
		}
		return IconGrid(cells: laid.cells, headers: laid.headers, iconSide: icon, iconSize: iconSize, scale: scale, textSize: text,
		                labelOnBottom: bottom, showPreview: r.icon.showIconPreview ?? true,
		                columns: columns, gaps: laid.gaps)
	}

	/// The room left and right of an icon view label inside its box (the view draws it with this padding).
	static let labelInset = 2.0

	// MARK: List view

	/// The columns: name, date modified, the sort column when it is none of the four, size, kind.
	static func listColumns(sortColumn: ListColumn) -> [ListColumn] {
		var columns: [ListColumn] = [.name, .dateModified]
		if ![ListColumn.name, .dateModified, .size, .kind].contains(sortColumn) { columns.append(sortColumn) }
		columns += [.size, .kind]
		return columns
	}

	/// The list view's cell padding (each side) and the space between a row's icon and its name.
	static let listPadding = 8.0
	static let listIconSpacing = 6.0

	static func listTable(_ samples: [PreviewSample], _ r: ViewSettings, format: PreviewFormat, foldersFirst: Bool = false,
	                      measure: (String, Double) -> Double) -> ListTable {
		let size = contentSize
		let text = min(32, max(6, r.list.textSize ?? 13))
		let iconSide: Double = (r.list.iconSize ?? 16) >= 24 ? 32 : 16
		let relative = r.list.useRelativeDates ?? true
		let calculate = r.list.calculateAllSizes ?? false
		let sortColumn = r.list.sortColumn ?? .name
		let ascending = r.list.sortAscending ?? true
		let columnIDs = listColumns(sortColumn: sortColumn)
		let headerHeight = 24.0, groupHeight = 24.0, separator = 12.0
		let headerFont = 11.0
		let rowHeight = max(iconSide + 6, (text * 1.25).rounded(.up) + 8)
		let padding = 2 * listPadding

		func cellText(_ s: PreviewSample, _ column: ListColumn, _ style: DateFormat) -> String {
			switch column {
			case .name: return s.name
			case .dateModified: return format.date(s.modified, style, relative: relative)
			case .dateCreated: return format.date(s.created, style, relative: relative)
			case .dateAdded: return format.date(s.added, style, relative: relative)
			case .dateLastOpened: return s.lastOpened.map { format.date($0, style, relative: relative) } ?? "--"
			case .size: return s.isFolder && !calculate ? "--" : format.size(s.bytes)
			case .kind: return s.type.kindName
			case .label: return s.tags.map(\.name).joined(separator: ", ")
			case .version: return "--"
			case .comments: return ""
			}
		}
		func title(_ c: ListColumn) -> String { Fmt.column(c) }
		// The name column is as wide as its widest label (with its tag dots): names are never cut. The dates take the
		// longest format that leaves the kind column whole (like Finder, which shortens its dates in a narrow column);
		// then the kind column gives way, down to `kindMinimum`, cut at its end.
		let widestName = samples.map { measure(labelText($0.name, tags: $0.tags.count), text) }.max() ?? 0
		let nameMinimum = (padding + iconSide + listIconSpacing + widestName + 4).rounded(.up)
		let kindMinimum = 50.0
		var chosen: (DateFormat, [ListColumn: Double]) = (.short, [:])
		for style in DateFormat.allCases {
			var widths: [ListColumn: Double] = [:]
			for c in columnIDs where c != .name {
				let texts = samples.map { cellText($0, c, style) }
				let content = (texts.map { measure($0, text) }.max() ?? 0).rounded(.up)
				// The sort column's title is drawn semibold with its chevron.
				let header = (measure(title(c), headerFont) * (c == sortColumn ? 1.08 : 1) + (c == sortColumn ? 16 : 0)).rounded(.up)
				widths[c] = max(content, header) + padding
			}
			chosen = (style, widths)
			if widths.values.reduce(0, +) + nameMinimum <= size.width { break }
		}
		var widths = chosen.1
		// The kind column gives way first (Finder cuts it at its end); names, dates and sizes are never cut.
		let fixed = widths.filter { $0.key != .kind }.values.reduce(0, +)
		let kind = widths[.kind] ?? 0
		widths[.kind] = max(kindMinimum, min(kind, size.width - nameMinimum - fixed))
		let nameWidth = size.width - widths.values.reduce(0, +)
		var x = 0.0
		var columns: [ListColumnSpec] = []
		for c in columnIDs {
			let w = c == .name ? nameWidth : (widths[c] ?? 60)
			columns.append(ListColumnSpec(id: c, title: title(c), x: x, width: w, trailing: c == .size, ascending: c == sortColumn ? ascending : nil))
			x += w
		}

		let ordered = listOrder(samples, column: sortColumn, ascending: ascending, calculateSizes: calculate, locale: format.locale,
		                        foldersFirst: foldersFirst)
		let groups = self.groups(ordered, by: r.groupBy, format: format, calculateSizes: calculate)
		let grouped = !(groups.count == 1 && groups[0].title.isEmpty)
		// Every row in the full order, with its group and its place in the group.
		let flat: [(sample: PreviewSample, group: Int, index: Int)] = groups.enumerated().flatMap { g, group in
			group.items.enumerated().map { (sample: $0.element, group: g, index: $0.offset) }
		}
		struct Laid { var rows: [ListRow] = []; var headers: [Header] = []; var gaps: [CGRect] = []; var bottom = 0.0 }
		func layOut(_ picks: [Pick]) -> Laid {
			var laid = Laid()
			var y = headerHeight, previous = -1, group = -1
			for p in picks {
				let e = flat[p.index]
				if p.index != previous + 1 {
					laid.gaps.append(CGRect(x: 0, y: y, width: size.width, height: separator))
					y += separator
					group = -1   // after a "⋯" the row's group header is drawn again
				}
				if grouped && e.group != group {
					let g = groups[e.group]
					laid.headers.append(Header(id: "h-" + g.title, title: g.title, frame: CGRect(x: 0, y: y, width: size.width, height: groupHeight),
					                           approximate: g.approximate))
					y += groupHeight
					group = e.group
				}
				laid.rows.append(ListRow(item: item(e.sample, format: format), y: y, cells: columnIDs.map { cellText(e.sample, $0, chosen.0) },
				                         stripe: e.index % 2 == 1))
				y += rowHeight
				previous = p.index
			}
			laid.bottom = y
			return laid
		}
		let laid = layOut(pick(count: flat.count, visible: { needs([flat[$0].sample]) }, any: { needs([flat[$0].sample]) },
		                       fits: { layOut($0).bottom <= size.height + 0.5 }))
		return ListTable(columns: columns, rows: laid.rows, headers: laid.headers, headerHeight: headerHeight, rowHeight: rowHeight,
		                 textSize: text, iconSide: iconSide, showPreview: r.list.showIconPreview ?? true, dateFormat: chosen.0, gaps: laid.gaps)
	}

	// MARK: Column and gallery view

	static func columnBrowser(_ samples: [PreviewSample], _ r: ViewSettings, format: PreviewFormat, foldersFirst: Bool = false) -> ColumnBrowser {
		let rowHeight = 22.0
		let paneWidth = 172.0
		func rows(_ items: [PreviewSample], selected: String, grouped: Bool) -> [ColumnRow] {
			let ordered = iconOrder(items, by: .name, locale: format.locale, foldersFirst: foldersFirst)
			let groups = grouped ? self.groups(ordered, by: r.groupBy, format: format) : [Group(title: "", rank: 0, approximate: false, items: ordered)]
			var out: [ColumnRow] = []
			var y = 4.0
			for g in groups {
				if !g.title.isEmpty {
					out.append(ColumnRow(id: "h-" + g.title, item: nil, header: g.title, y: y, selected: false, isFolder: false))
					y += rowHeight
				}
				for s in g.items {
					out.append(ColumnRow(id: s.id, item: item(s, format: format), header: nil, y: y, selected: s.id == selected, isFolder: s.isFolder))
					y += rowHeight
				}
			}
			return out
		}
		let photos = PreviewSample.photos(now: format.now, calendar: format.calendar)
		let beach = photos.first { $0.id == "photos-beach" } ?? photos[0]
		let lines = [beach.type.kindName + " · " + format.size(beach.bytes), format.info(beach) ?? "",
		             String(localized: "수정일") + " " + format.day(beach.modified)]
		return ColumnBrowser(panes: [ColumnPane(x: 0, width: paneWidth, rows: rows(samples, selected: "photos", grouped: true)),
		                             ColumnPane(x: paneWidth, width: paneWidth, rows: rows(photos, selected: beach.id, grouped: false))],
		                     rowHeight: rowHeight, previewX: paneWidth * 2, preview: item(beach, format: format), previewLines: lines)
	}

	static func gallery(_ samples: [PreviewSample], groupBy: GroupBy?, format: PreviewFormat, foldersFirst: Bool = false) -> Gallery {
		let ordered = iconOrder(samples, by: .name, locale: format.locale, foldersFirst: foldersFirst)
		let selected = samples.first { $0.id == "trip" } ?? samples[0]
		let lines = [selected.type.kindName + " · " + format.size(selected.bytes), format.info(selected) ?? ""]
		let note = groupBy.map { $0 != .none } == true ? String(localized: "갤러리 보기는 묶음을 보이지 않습니다") : nil
		return Gallery(selected: item(selected, format: format), lines: lines, strip: ordered.map { item($0, format: format) }, note: note)
	}
}

// MARK: Strings

/// Dates, sizes and item info in the app's language, relative to a fixed "now".
struct PreviewFormat {
	var locale: Locale
	var calendar: Calendar
	var now: Date
	/// Formatters made once per preview (a slider drag makes a preview per step).
	private let cache = Cache()

	init(locale: Locale, calendar: Calendar, now: Date) {
		self.locale = locale
		self.calendar = calendar
		self.now = now
	}

	private final class Cache {
		var dates: [String: DateFormatter] = [:]
		var number: NumberFormatter?
	}

	var isKorean: Bool { locale.language.languageCode?.identifier == "ko" }

	private func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style, template: String? = nil) -> DateFormatter {
		let key = "\(date.rawValue)-\(time.rawValue)-\(template ?? "")"
		if let f = cache.dates[key] { return f }
		let f = DateFormatter()
		f.locale = locale
		f.calendar = calendar
		f.timeZone = calendar.timeZone
		if let template {
			f.setLocalizedDateFormatFromTemplate(template)
		} else {
			f.dateStyle = date
			f.timeStyle = time
		}
		cache.dates[key] = f
		return f
	}

	/// Finder's list dates: "2026년 8월 10일 오후 2:30" (full), "2026. 8. 10. 오후 2:30" (medium), "26. 8. 10." (short);
	/// with relative dates today and yesterday are "오늘 오후 2:02", "어제 …" ("오늘" alone in the short form).
	func date(_ d: Date, _ style: PresetPreview.DateFormat, relative: Bool) -> String {
		if relative {
			let time = formatter(.none, .short).string(from: d)
			if calendar.isDate(d, inSameDayAs: now) { return style == .short ? String(localized: "오늘") : String(localized: "오늘 \(time)") }
			if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: yesterday) {
				return style == .short ? String(localized: "어제") : String(localized: "어제 \(time)")
			}
		}
		switch style {
		case .full: return formatter(.long, .short).string(from: d)
		case .medium: return formatter(.medium, .short).string(from: d)
		case .short: return formatter(.short, .none).string(from: d)
		}
	}

	/// A day without the time ("2026. 9. 16.", "Sep 16, 2026").
	func day(_ d: Date) -> String { formatter(.medium, .none).string(from: d) }

	/// Sizes the way Finder writes them (powers of 1000): "820KB", "18.4MB", "240MB".
	func size(_ bytes: Int64) -> String {
		let b = Double(bytes)
		let value: Double
		let unit: Int
		switch b {
		case 1_000_000_000...: (value, unit) = (b / 1_000_000_000, 3)
		case 1_000_000...: (value, unit) = (b / 1_000_000, 2)
		case 1_000...: (value, unit) = (b / 1_000, 1)
		default: (value, unit) = (b, 0)
		}
		let f = cache.number ?? NumberFormatter()
		cache.number = f
		f.locale = locale
		f.numberStyle = .decimal
		f.minimumFractionDigits = 0
		f.maximumFractionDigits = unit > 0 && value < 100 ? 1 : 0
		let n = f.string(from: NSNumber(value: value)) ?? String(value)
		switch unit {
		case 3: return String(localized: "\(n)GB")
		case 2: return String(localized: "\(n)MB")
		case 1: return String(localized: "\(n)KB")
		default: return String(localized: "\(n)바이트")
		}
	}

	/// The icon view's item info: folders "12개 항목", images "4032×3024", movies "02:14"; nothing for the others.
	func info(_ s: PreviewSample) -> String? {
		if let count = s.itemCount { return String(localized: "\(count)개 항목") }
		if let p = s.pixels { return "\(p.width)×\(p.height)" }
		if let d = s.duration { return String(format: "%02d:%02d", d / 60, d % 60) }
		return nil
	}

	/// Finder's date groups: today, yesterday, the previous 7 and 30 days, the months of this year, earlier years, and
	/// "더 이전 날짜" for no date. `observed`: Finder was seen showing it.
	func dateGroup(_ d: Date?) -> (title: String, rank: Int, observed: Bool) {
		guard let d else { return (String(localized: "더 이전 날짜"), 10_000, true) }
		let start = calendar.startOfDay(for: now)
		let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: start).day ?? 0
		if days <= 0 { return (String(localized: "오늘"), 0, true) }
		if days == 1 { return (String(localized: "어제"), 1, false) }
		if days <= 7 { return (String(localized: "지난 7일"), 2, false) }
		if days <= 30 { return (String(localized: "지난 30일"), 3, false) }
		let year = calendar.component(.year, from: d)
		if year == calendar.component(.year, from: now) {
			let month = calendar.component(.month, from: d)
			return (formatter(.none, .none, template: "LLLL").string(from: d), 100 - month, false)
		}
		return (String(year), 1000 + (3000 - year), true)
	}
}

import Foundation
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// The preset editor's preview model (PresetPreview.swift) outside the UI: order per sort key and direction, groups,
/// the visible-sample guarantee, the icon scale, the list columns, the strings. A fixed "now" in a fixed time zone; the
/// texts are the Korean keys (no app bundle here).
@MainActor @Suite struct PresetPreviewTests {
	static let calendar: Calendar = {
		var c = Calendar(identifier: .gregorian)
		c.timeZone = TimeZone(identifier: "Asia/Seoul")!
		return c
	}()
	/// 2026-09-19 14:30 in Seoul.
	static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 30))!
	static let ko = Locale(identifier: "ko_KR")
	static let en = Locale(identifier: "en_US")
	static var format: PreviewFormat { PreviewFormat(locale: ko, calendar: calendar, now: now) }
	static var samples: [PreviewSample] { PreviewSample.folder(now: now, calendar: calendar) }

	static func make(_ settings: ViewSettings, defaults: PreviewDefaults = .factory, locale: Locale = ko) -> PresetPreview {
		PresetPreview.make(settings: settings, defaults: defaults, locale: locale, now: now, calendar: calendar)
	}

	static func ids(_ items: [PreviewSample]) -> [String] { items.map(\.id) }

	static func grid(_ p: PresetPreview) -> PresetPreview.IconGrid? { if case .icon(let g) = p.content { g } else { nil } }
	static func table(_ p: PresetPreview) -> PresetPreview.ListTable? { if case .list(let t) = p.content { t } else { nil } }
	/// The options the footer's tooltip lists as "유지" (`details`: "<option> 유지(폴더마다 지금 값 그대로) · 그린 값: …").
	static func kept(_ p: PresetPreview) -> [String] {
		p.details.compactMap { line in line.range(of: " 유지(폴더마다 지금 값 그대로)").map { String(line[..<$0.lowerBound]) } }
	}

	// MARK: Order

	@Test func iconViewOrderForEverySortKey() {
		let s = Self.samples
		let expected: [SortKey: [String]] = [
			.none: ["photos", "notes", "trip", "projects", "talk", "report", "archive", "screenshot"],
			// "자동 격자 정렬" orders nothing either: the icons keep their places, snapped to the grid.
			.grid: ["photos", "notes", "trip", "projects", "talk", "report", "archive", "screenshot"],
			.name: ["notes", "talk", "report", "photos", "screenshot", "trip", "archive", "projects"],
			// Korean collation: Hangul kinds ("일반 텍스트 문서", "폴더") before Latin ones ("JPEG 이미지", …).
			.kind: ["notes", "photos", "projects", "trip", "report", "screenshot", "talk", "archive"],
			.dateModified: ["projects", "screenshot", "report", "photos", "archive", "trip", "talk", "notes"],
			.dateCreated: ["screenshot", "archive", "report", "trip", "talk", "photos", "projects", "notes"],
			.dateAdded: ["screenshot", "archive", "talk", "trip", "report", "photos", "projects", "notes"],
			.dateLastOpened: ["photos", "projects", "report", "talk", "trip", "notes", "screenshot", "archive"],
			.size: ["talk", "archive", "trip", "report", "screenshot", "notes", "photos", "projects"],
			.label: ["report", "photos", "notes", "talk", "screenshot", "trip", "archive", "projects"]
		]
		for key in SortKey.allCases {
			#expect(Self.ids(PresetPreview.iconOrder(s, by: key, locale: Self.ko)) == expected[key], "\(key)")
		}
		// Every key that sorts gives another order, so each choice visibly changes the preview ("없음" and "자동 격자 정렬"
		// both keep the free places).
		#expect(Set(expected.values.map { $0.joined(separator: ",") }).count == SortKey.allCases.count - 1)
	}

	@Test func listOrderFollowsColumnAndDirection() {
		let s = Self.samples
		func order(_ c: ListColumn, _ up: Bool, calc: Bool = false) -> [String] {
			Self.ids(PresetPreview.listOrder(s, column: c, ascending: up, calculateSizes: calc, locale: Self.ko))
		}
		let byName = ["notes", "talk", "report", "photos", "screenshot", "trip", "archive", "projects"]
		#expect(order(.name, true) == byName)
		#expect(order(.name, false) == byName.reversed())
		let newest = ["projects", "screenshot", "report", "photos", "archive", "trip", "talk", "notes"]
		#expect(order(.dateModified, false) == newest)
		#expect(order(.dateModified, true) == newest.reversed())
		// Folders without a calculated size sort as the smallest, with one as their size.
		#expect(order(.size, true) == ["photos", "projects", "notes", "screenshot", "report", "trip", "archive", "talk"])
		#expect(order(.size, false, calc: true) == ["photos", "talk", "archive", "projects", "trip", "report", "screenshot", "notes"])
		// Never opened is the oldest.
		#expect(order(.dateLastOpened, true).prefix(2) == ["screenshot", "archive"])
		#expect(order(.kind, true) == ["notes", "photos", "projects", "trip", "report", "screenshot", "talk", "archive"])
		#expect(order(.label, true).prefix(2) == ["report", "photos"])
		// Columns no sample has keep the name order either way.
		#expect(order(.version, true) == byName && order(.comments, false) == byName)
	}

	/// A sort column set without a direction takes that column's own direction from Finder's defaults — never the
	/// direction of Finder's own sort column.
	@Test func keptDirectionComesFromTheChosenColumn() throws {
		// Factory: sorted by name (ascending); the size column's own entry is descending.
		let factory = PreviewDefaults.factory
		#expect(factory.settings.list.sortColumn == .name && factory.settings.list.sortAscending == true)
		#expect(factory.ascending(for: .size) == false && factory.ascending(for: .kind) == true && factory.ascending(for: .dateModified) == false)
		let bySize = Self.make(ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .size)))
		let table = try #require(Self.table(bySize))
		#expect(table.columns.first { $0.id == .size }?.ascending == false)
		#expect(table.columns.filter { $0.ascending != nil }.map(\.id) == [.size])
		#expect(Self.kept(bySize).contains("정렬 방향") && !Self.kept(bySize).contains("정렬 열"))
		#expect(table.rows.first?.item.id == "talk", "largest file first: \(table.rows.map(\.item.id))")

		// Defaults whose kind column is descending, while their own sort column (date added) is ascending.
		var columns = ViewRecordCodec.factoryListColumns
		for i in columns.indices {
			if columns[i]["identifier"] as? String == "kind" { columns[i]["ascending"] = false }
			if columns[i]["identifier"] as? String == "dateAdded" { columns[i]["ascending"] = true }
		}
		var list = ViewRecordCodec.factoryListPlist
		list["columns"] = columns
		list["sortColumn"] = "dateAdded"
		let custom = PreviewDefaults(GlobalDefaults(preferredViewStyle: .list, listArrayPlist: list))
		#expect(custom.settings.list.sortAscending == true && custom.ascending(for: .kind) == false)
		let byKind = try #require(Self.table(Self.make(ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .kind)), defaults: custom)))
		#expect(byKind.columns.first { $0.id == .kind }?.ascending == false)
		#expect(byKind.rows.map(\.item.id) == ["archive", "talk", "screenshot", "report", "trip", "photos", "projects", "notes"], "kind descending")
		// All kept: Finder's own column and direction.
		let kept = try #require(Self.table(Self.make(ViewSettings(viewStyle: .list), defaults: custom)))
		#expect(kept.columns.first { $0.ascending != nil }?.id == .dateAdded && kept.columns.first { $0.id == .dateAdded }?.ascending == true)
		// A direction set with its column wins.
		let set = try #require(Self.table(Self.make(ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .kind, sortAscending: true)), defaults: custom)))
		#expect(set.columns.first { $0.id == .kind }?.ascending == true)
	}

	// MARK: Groups

	@Test func groupHeaders() {
		let f = Self.format
		func titles(_ g: GroupBy, _ order: [PreviewSample]? = nil) -> [String] {
			PresetPreview.groups(order ?? Self.samples, by: g, format: f).map(\.title)
		}
		#expect(titles(.kind) == ["폴더", "문서", "PDF 문서", "이미지", "동영상", "기타"])
		let kind = PresetPreview.groups(Self.samples, by: .kind, format: f)
		// Observed: a folder, a text file and a PNG under their headers. A PDF's own group, a JPEG with
		// the images, the movie and the archive are guesses.
		#expect(kind.map(\.approximate) == [false, false, true, true, true, true])
		#expect(kind[0].items.map(\.id) == ["photos", "projects"], "items keep the order they came in")
		#expect(titles(.dateModified) == ["오늘", "어제", "지난 7일", "지난 30일", "8월", "3월", "2025"])
		let modified = PresetPreview.groups(Self.samples, by: .dateModified, format: f)
		#expect(modified.map(\.approximate) == [false, true, true, true, true, true, false])
		#expect(titles(.dateLastOpened).last == "더 이전 날짜")
		// Folder sizes not shown (the icon view; the list without "모든 크기 계산"): the folders in one last, guessed group,
		// like their "--"; with sizes calculated they go by their size, still a guess.
		let files = ["100MB에서 1GB까지", "10MB에서 100MB까지", "1MB에서 10MB까지", "100KB에서 1MB까지", "1KB에서 100KB까지"]
		#expect(titles(.size) == files + ["--"])
		let bySize = PresetPreview.groups(Self.samples, by: .size, format: f)
		#expect(bySize.last?.items.map(\.id) == ["photos", "projects"] && bySize.last?.approximate == true)
		#expect(bySize[2].approximate == false && bySize[0].items.map(\.id) == ["talk"])
		let calculated = PresetPreview.groups(Self.samples, by: .size, format: f, calculateSizes: true)
		#expect(calculated.map(\.title) == files && calculated[0].items.map(\.id) == ["photos", "talk"] && calculated[0].approximate)
		#expect(calculated[1].items.map(\.id) == ["projects", "archive"] && calculated[2].approximate == false)
		#expect(titles(.application) == ["미리보기", "압축 해제 유틸리티", "텍스트 편집기", "QuickTime Player", "기타"])
		#expect(titles(.none) == [""] && PresetPreview.groups(Self.samples, by: nil, format: f).count == 1)
		// In English every header is the app's guess (only the Korean ones were seen in Finder).
		let english = PreviewFormat(locale: Self.en, calendar: Self.calendar, now: Self.now)
		#expect(PresetPreview.groups(Self.samples, by: .kind, format: english).allSatisfy { $0.approximate })

		// Drawn: the icon view has one header per group, the items sorted inside it.
		let small = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 16, textSize: 10, labelOnBottom: false, arrangeBy: .name, gridSpacing: 1), groupBy: .kind)
		let grid = Self.grid(Self.make(small))
		#expect(grid?.headers.map(\.title) == ["폴더", "문서", "PDF 문서", "이미지", "동영상", "기타"])
		#expect(grid?.cells.map(\.id) == ["photos", "projects", "notes", "report", "screenshot", "trip", "talk", "archive"])
		#expect(grid?.gaps.isEmpty == true && grid?.headers.allSatisfy { $0.hidden == 0 } == true)
		// A kept grouping is drawn without groups (Finder's global grouping is not known to apply).
		#expect(Self.grid(Self.make(ViewSettings(viewStyle: .icon)))?.headers.isEmpty == true)
		#expect(Self.kept(Self.make(ViewSettings(viewStyle: .icon))).contains("그룹 기준"))
		// The gallery view never groups.
		if case .gallery(let g) = Self.make(ViewSettings(viewStyle: .gallery, groupBy: .kind)).content { #expect(g.strip.count == 8) } else { Issue.record("not a gallery") }
	}

	// MARK: Visible samples, scale, bounds

	/// The dates the tests also try (the date groups change with the time of year: early January shares a year group
	/// with the previous autumn, the end of February, the last day of the year).
	static let nows: [Date] = [
		calendar.date(from: DateComponents(year: 2027, month: 1, day: 5, hour: 9, minute: 5))!,
		calendar.date(from: DateComponents(year: 2027, month: 2, day: 28, hour: 23, minute: 50))!,
		now,
		calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 0, minute: 20))!
	]

	static func make(_ settings: ViewSettings, at now: Date, measure: (String, Double) -> Double = PreviewText.estimate) -> PresetPreview {
		PresetPreview.make(settings: settings, defaults: .factory, locale: ko, now: now, calendar: calendar, measure: measure)
	}

	/// Checks one icon view preview: a folder and an image, everything inside the content area, the count badge, and
	/// what is drawn is the top of the order (see `drawnIsTheTopOfTheOrder`).
	static func checkIcon(_ s: ViewSettings, at now: Date, _ label: String,
	                      measure: (String, Double) -> Double = PreviewText.estimate) throws {
		let box = CGRect(origin: .zero, size: PresetPreview.contentSize).insetBy(dx: -0.5, dy: -0.5)
		let p = make(s, at: now, measure: measure)
		let grid = try #require(Self.grid(p))
		let types = Set(grid.cells.map(\.item.type))
		#expect(types.contains(.folder) && (types.contains(.jpeg) || types.contains(.png)), Comment(rawValue: label))
		for cell in grid.cells {
			let inside = box.contains(cell.frame) && box.contains(cell.icon) && box.contains(cell.label) && (cell.info.map(box.contains) ?? true)
			#expect(inside, "\(cell.id) \(cell.frame) at \(label)")
		}
		for header in grid.headers { #expect(box.contains(header.frame), "\(header.title) at \(label)") }
		for gap in grid.gaps { #expect(box.contains(gap), "gap at \(label)") }
		#expect(Set(grid.cells.map(\.id)).count == grid.cells.count)
		#expect(p.shownItems == grid.cells.count && (p.countBadge != nil) == (grid.cells.count < 8), Comment(rawValue: label))
		try drawnIsTheTopOfTheOrder(s, grid: grid, now: now, label)
	}

	/// The rows (or group rows) before the first "⋯" are the first ones of the full order, each group row its first
	/// items; after it come later units in order (at most two: the ones with the folder or the image).
	static func drawnIsTheTopOfTheOrder(_ s: ViewSettings, grid: PresetPreview.IconGrid, now: Date, _ label: String) throws {
		let format = PreviewFormat(locale: ko, calendar: calendar, now: now)
		let samples = PreviewSample.folder(now: now, calendar: calendar)
		let ordered = PresetPreview.iconOrder(samples, by: s.icon.arrangeBy ?? SortKey.none, locale: ko)
		let groups = PresetPreview.groups(ordered, by: s.groupBy, format: format)
		let cut = grid.gaps.first?.minY ?? .infinity
		let before = grid.cells.filter { $0.frame.minY < cut }.map(\.id)
		if groups.count == 1 && groups[0].title.isEmpty {
			#expect(before == Array(ordered.map(\.id).prefix(before.count)), "not the top rows: \(before) at \(label)")
			#expect(before.count % grid.columns == 0 || grid.gaps.isEmpty, "a row cut before the gap at \(label)")
		} else {
			let titles = grid.headers.filter { $0.frame.minY < cut }.map(\.title)
			#expect(titles == Array(groups.map(\.title).prefix(titles.count)), "not the first groups: \(titles) at \(label)")
			// A row scrolled sideways (to show the folder or the image its first items hide) shows later items.
			let scrolled = Set(grid.headers.filter(\.scrolled).map(\.title))
			let expected = groups.prefix(titles.count).filter { !scrolled.contains($0.title) }.flatMap { $0.items.prefix(grid.columns).map(\.id) }
			let drawnFirst = before.filter { id in !groups.contains { scrolled.contains($0.title) && $0.items.contains { $0.id == id } } }
			#expect(drawnFirst == expected, "group rows not their first items: \(before) vs \(expected) at \(label)")
			#expect(scrolled.count <= 2)
			let after = grid.headers.filter { $0.frame.minY >= cut }.map(\.title)
			let rest = groups.dropFirst(titles.count).map(\.title)
			#expect(after.count <= 2 && after.allSatisfy(rest.contains) && after == rest.filter(after.contains), "after the gap: \(after) at \(label)")
			for h in grid.headers {
				let total = groups.first { $0.title == h.title }?.items.count ?? 0
				let drawn = grid.cells.filter { c in groups.first { $0.title == h.title }?.items.contains { $0.id == c.id } == true }.count
				#expect(h.hidden == total - drawn, "hidden count of \(h.title) at \(label)")
			}
		}
		#expect(grid.gaps.count <= 2)
	}

	@Test func aFolderAndAnImageAreAlwaysVisible() throws {
		var checked = 0
		let groupings: [GroupBy?] = [nil] + GroupBy.allCases.map(Optional.init)
		for size in [16.0, 32, 64, 96, 128, 256, 512] {
			for text in [10.0, 16] {
				for spacing in [1.0, 100] {
					for bottom in [true, false] {
						for info in [true, false] {
							for group in groupings {
								for key in [SortKey.none, .name, .size, .dateAdded] {
									let s = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: size, textSize: text, labelOnBottom: bottom, showItemInfo: info,
									                                                                   arrangeBy: key, gridSpacing: spacing), groupBy: group)
									try Self.checkIcon(s, at: Self.now, "\(size) \(text) \(spacing) \(bottom) \(info) \(String(describing: group)) \(key)")
									checked += 1
								}
							}
						}
					}
				}
			}
		}
		#expect(checked > 4000)
		// Other times of the year, every grouping (the date groups differ), the tightest sizes.
		for now in Self.nows {
			for group in groupings {
				for size in [64.0, 96, 512] {
					for bottom in [true, false] {
						for key in [SortKey.name, .dateCreated, .dateAdded] {
							let s = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: size, textSize: 16, labelOnBottom: bottom, showItemInfo: true,
							                                                                   arrangeBy: key, gridSpacing: 100), groupBy: group)
							try Self.checkIcon(s, at: now, "\(now) \(size) \(bottom) \(String(describing: group)) \(key)")
						}
					}
				}
			}
		}
		for now in Self.nows {
			for text in [10.0, 13, 16] {
				for icon in [16.0, 32] {
					for group in groupings {
						for column in ListColumn.allCases {
							let s = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: text, iconSize: icon, sortColumn: column, sortAscending: false,
							                                                               calculateAllSizes: true), groupBy: group)
							let label = "\(now) \(text) \(icon) \(String(describing: group)) \(column)"
							let table = try #require(Self.table(Self.make(s, at: now)))
							let types = Set(table.rows.map(\.item.type))
							#expect(types.contains(.folder) && (types.contains(.jpeg) || types.contains(.png)), Comment(rawValue: label))
							#expect((table.rows.last.map { $0.y + table.rowHeight } ?? 0) <= PresetPreview.contentSize.height + 0.5)
							// The rows before a "⋯" are the first ones of the order (groups in their order).
							let format = PreviewFormat(locale: Self.ko, calendar: Self.calendar, now: now)
							let ordered = PresetPreview.listOrder(PreviewSample.folder(now: now, calendar: Self.calendar), column: column, ascending: false,
							                                      calculateSizes: true, locale: Self.ko)
							let full = PresetPreview.groups(ordered, by: group, format: format, calculateSizes: true).flatMap { $0.items.map(\.id) }
							let cut = table.gaps.first?.minY ?? .infinity
							let before = table.rows.filter { $0.y < cut }.map(\.id)
							#expect(before == Array(full.prefix(before.count)), "\(before) at \(label)")
							let after = table.rows.filter { $0.y >= cut }.map(\.id)
							#expect(after.count <= 2 && after == full.filter(after.contains), "\(after) at \(label)")
						}
					}
				}
			}
		}
	}

	/// Every label two lines long (English names are longer than the Korean ones the other tests draw): with 512pt icons,
	/// item info and the widest spacing, the two groups that hold a folder and an image are not always next to each other,
	/// and the gap between them no longer fits at the usual icon side. The preview then draws the icons smaller — it never
	/// draws past its box — and still shows a folder and an image. (The layout probe found this in English, with Finder's
	/// defaults at icon 512, text 16, grid 100, item info on, and a preset grouping by size.)
	@Test func longLabelsNeverSpillOutOfTheBox() throws {
		let twoLines: (String, Double) -> Double = { _, _ in 1_000_000 }
		var shrunk = 0
		let groupings: [GroupBy?] = [nil] + GroupBy.allCases.map(Optional.init)
		for group in groupings {
			for key in SortKey.allCases {
				for bottom in [true, false] {
					let s = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 512, textSize: 16, labelOnBottom: bottom, showItemInfo: true,
					                                                               arrangeBy: key, gridSpacing: 100), groupBy: group)
					try Self.checkIcon(s, at: Self.now, "two lines, \(String(describing: group)) \(key) \(bottom)", measure: twoLines)
					let grid = try #require(Self.grid(Self.make(s, at: Self.now, measure: twoLines)))
					if grid.iconSide < PresetPreview.drawnIconSide(512) {
						shrunk += 1
						// The footer says how much smaller than the real icon it is drawn.
						#expect(Self.make(s, at: Self.now, measure: twoLines).scaleBadge == "실제 크기의 \(Int((grid.scale * 100).rounded()))%")
					}
				}
			}
		}
		#expect(shrunk > 0, "the worst case needs smaller icons somewhere")
	}

	/// The "⋯" substitution: sorted so the folders and images come last, the top rows lack one and the first later
	/// unit that has it follows a gap; nothing is skipped when the top already has both.
	@Test func skippedRowsAreMarked() throws {
		// Icon size 96, text 16, label right, grid 100: one item per row; by size the folders come last.
		let s = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 512, textSize: 16, labelOnBottom: false, showItemInfo: true,
		                                                                  arrangeBy: .size, gridSpacing: 100))
		let grid = try #require(Self.grid(Self.make(s)))
		#expect(grid.columns == 1 && !grid.gaps.isEmpty)
		let ids = grid.cells.map(\.id)
		#expect(ids.first == "talk" && ids.contains("trip") && ids.last == "photos", "\(ids)")
		let q = Self.make(s)
		#expect(q.details.contains { $0.contains("⋯") } && q.countBadge != nil)
		// Sorted by name everything needed is near the top: no gap.
		let byName = try #require(Self.grid(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, arrangeBy: .name)))))
		#expect(byName.gaps.isEmpty)
		// By name with 128: the first rows in name order (메모.txt first), not a fixed choice of samples.
		let big = try #require(Self.grid(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 128, arrangeBy: .name)))))
		#expect(big.cells.first?.id == "notes")
	}

	@Test func foldersOnTopWhenFinderSaysSo() throws {
		let s = Self.samples
		#expect(Self.ids(PresetPreview.iconOrder(s, by: .name, locale: Self.ko, foldersFirst: true)) == ["photos", "projects", "notes", "talk", "report", "screenshot", "trip", "archive"])
		#expect(Self.ids(PresetPreview.listOrder(s, column: .name, ascending: false, calculateSizes: false, locale: Self.ko, foldersFirst: true)).prefix(2) == ["projects", "photos"])
		// Other orders are not affected.
		#expect(PresetPreview.iconOrder(s, by: .size, locale: Self.ko, foldersFirst: true) == PresetPreview.iconOrder(s, by: .size, locale: Self.ko))
		var defaults = PreviewDefaults.factory
		defaults.foldersFirst = true
		let table = try #require(Self.table(Self.make(ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .name, sortAscending: true)), defaults: defaults)))
		#expect(table.rows.prefix(2).map(\.id) == ["photos", "projects"])
		#expect(Self.make(ViewSettings(viewStyle: .gallery), defaults: defaults).details.contains { $0.contains("폴더를 먼저") })
		if case .gallery(let g) = Self.make(ViewSettings(viewStyle: .gallery), defaults: defaults).content { #expect(g.strip.first?.id == "photos") }
	}

	@Test func iconScaleDependsOnIconSizeOnly() throws {
		#expect(PresetPreview.iconScale(16) == 1 && PresetPreview.iconScale(64) == 1 && PresetPreview.iconScale(96) < 1)
		#expect(PresetPreview.iconScale(512) == 0.1875 && PresetPreview.drawnIconSide(512) == 96)
		// Every step of the slider beyond the real size still draws a bigger icon (no flat range).
		let sides = [64.0, 72, 96, 128, 192, 256, 384, 512].map(PresetPreview.drawnIconSide)
		#expect(zip(sides, sides.dropFirst()).allSatisfy { $0 < $1 }, "\(sides)")
		#expect(sides.dropFirst().allSatisfy { $0 <= 96 })
		for size in [32.0, 64, 128, 512] {
			var scales: Set<Double> = []
			var sides: Set<Double> = []
			var columns: Set<Int> = []
			for text in [10.0, 12, 16] {
				for spacing in [1.0, 54, 100] {
					for bottom in [true, false] {
						let g = try #require(Self.grid(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: size, textSize: text, labelOnBottom: bottom, gridSpacing: spacing)))))
						scales.insert(g.scale)
						sides.insert(g.iconSide)
						columns.insert(g.columns)
						#expect(g.textSize == text, "text is drawn at its size")
					}
				}
			}
			#expect(scales.count == 1 && sides.count == 1, "\(size): \(scales) \(sides)")
			// Text size, grid spacing and label position change the number of columns instead.
			#expect(columns.count > 1, "\(size): \(columns)")
		}
		// Grid spacing: neighbours further apart, fewer columns; the icons stay the same size.
		let tight = try #require(Self.grid(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, gridSpacing: 1)))))
		let wide = try #require(Self.grid(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, gridSpacing: 100)))))
		func pitch(_ g: PresetPreview.IconGrid) -> Double { g.cells[1].frame.minX - g.cells[0].frame.minX }
		#expect(wide.columns > 1 && tight.columns > wide.columns && pitch(tight) < pitch(wide) && tight.iconSide == wide.iconSide)
		// Drawn smaller: the badge says so; 1:1 has none.
		#expect(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 128))).scaleBadge == "실제 크기의 58%")
		#expect(Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64))).scaleBadge == nil)
	}

	// MARK: List view

	@Test func listColumnsAreAlwaysThere() throws {
		for column in ListColumn.allCases {
			for relative in [true, false] {
				for text in [10.0, 16] {
					let s = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: text, sortColumn: column, useRelativeDates: relative, calculateAllSizes: true))
					let table = try #require(Self.table(Self.make(s)))
					let ids = table.columns.map(\.id)
					#expect(Array(ids.prefix(2)) == [.name, .dateModified] && Array(ids.suffix(2)) == [.size, .kind], "\(column): \(ids)")
					#expect(ids.contains(column) && table.columns.filter { $0.ascending != nil }.map(\.id) == [column])
					#expect(abs((table.columns.last.map { $0.x + $0.width } ?? 0) - PresetPreview.contentSize.width) < 0.5)
					// Sizes and dates are never cut: each column is as wide as its widest text.
					for spec in table.columns where spec.id != .name && spec.id != .kind {
						let index = try #require(ids.firstIndex(of: spec.id))
						let widest = table.rows.map { PreviewText.estimate($0.cells[index], table.textSize) }.max() ?? 0
						#expect(spec.width >= widest + 8, "\(spec.id) \(spec.width) < \(widest) at \(text)")
					}
				}
			}
		}
		// Names are never cut, with the widest text, 32pt icons, a fifth column and groups: the kind column gives way.
		for group in [GroupBy?.none, .dateModified, .kind] {
			for column in [ListColumn.dateAdded, .dateLastOpened, .label, .name] {
				let s = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 16, iconSize: 32, sortColumn: column, useRelativeDates: false,
				                                                               calculateAllSizes: true), groupBy: group)
				let table = try #require(Self.table(Self.make(s)))
				let name = try #require(table.columns.first)
				for row in table.rows {
					let label = PreviewText.estimate(PresetPreview.labelText(row.item.name, tags: row.item.tags.count), 16)
					#expect(name.width >= 2 * PresetPreview.listPadding + table.iconSide + PresetPreview.listIconSpacing + label, "\(row.id) cut at \(column) \(String(describing: group))")
				}
				#expect((table.columns.first { $0.id == .kind }?.width ?? 0) >= 50)
			}
		}
	}

	@Test func listStrings() throws {
		let f = Self.format
		let today = Self.now.addingTimeInterval(-2 * 3600)
		#expect(f.date(today, .medium, relative: true).hasPrefix("오늘 "))
		#expect(f.date(today, .short, relative: true) == "오늘")
		#expect(f.date(Self.now.addingTimeInterval(-86_400), .full, relative: true).hasPrefix("어제 "))
		let plain = f.date(today, .full, relative: false)
		#expect(plain.contains("2026") && plain.contains("9월 19일") && !plain.contains("오늘"), Comment(rawValue: plain))
		#expect(PreviewFormat(locale: Self.en, calendar: Self.calendar, now: Self.now).date(today, .full, relative: false).contains("September 19, 2026"))
		#expect(f.size(18_400_000) == "18.4MB" && f.size(240_000_000) == "240MB" && f.size(820_000) == "820KB" && f.size(2_000) == "2KB")
		#expect(f.size(48_000_000) == "48MB" && f.size(1_200_000) == "1.2MB")
		let s = Dictionary(uniqueKeysWithValues: Self.samples.map { ($0.id, $0) })
		#expect(f.info(s["photos"]!) == "12개 항목" && f.info(s["trip"]!) == "4032×3024" && f.info(s["talk"]!) == "02:14" && f.info(s["notes"]!) == nil)

		// Relative dates on and off, folder sizes with and without "모든 크기 계산".
		func cells(_ list: ListViewSettings) throws -> [String: [String]] {
			let t = try #require(Self.table(Self.make(ViewSettings(viewStyle: .list, list: list))))
			return Dictionary(uniqueKeysWithValues: t.rows.map { ($0.item.id, $0.cells) })
		}
		let on = try cells(ListViewSettings(useRelativeDates: true, calculateAllSizes: true))
		let off = try cells(ListViewSettings(useRelativeDates: false, calculateAllSizes: false))
		#expect(on["projects"]?[1].hasPrefix("오늘") == true && off["projects"]?[1].hasPrefix("오늘") == false)
		#expect(on["report"]?[1].hasPrefix("어제") == true)
		#expect(on["photos"]?[2] == "240MB" && off["photos"]?[2] == "--" && off["trip"]?[2] == "3.4MB")
		#expect(on["trip"]?[3] == "JPEG 이미지")
		// Each sample has a time of its own (not the clock time of "now" everywhere).
		let times = Self.samples.map { Self.calendar.dateComponents([.hour, .minute], from: $0.modified) }
		#expect(Set(times.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }).count == 8)
		// Just after midnight today's times are squeezed before "now", keeping their order.
		let early = Self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 0, minute: 30))!
		let clock = SampleClock(now: early, calendar: Self.calendar)
		#expect(clock.today(9, 26) < clock.today(12, 41) && clock.today(12, 41) <= early && Self.calendar.isDate(clock.today(9, 26), inSameDayAs: early))
	}

	// MARK: "유지", following the draft

	/// "유지" is drawn with Finder's defaults, and the editor's sliders rest on the same values.
	@Test func keptValuesUseFindersDefaultsLikeTheSliders() throws {
		var icon = ViewRecordCodec.factoryIconPlist
		icon["iconSize"] = 80.0
		icon["gridSpacing"] = 30.0
		icon["labelOnBottom"] = false
		let globals = GlobalDefaults(preferredViewStyle: .icon, iconPlist: icon)
		let defaults = PreviewDefaults(globals)
		let p = Self.make(ViewSettings(), defaults: defaults)
		#expect(p.view == .icon && p.viewKept)
		let grid = try #require(Self.grid(p))
		#expect(grid.iconSize == 80 && !grid.labelOnBottom)
		#expect(Self.kept(p).contains("아이콘 크기") && Self.kept(p).contains("레이블 위치"))
		#expect(p.footerLeading.contains("Finder") && p.details.contains { $0.contains("80") })
		// The sliders of the editor rest on the same values.
		var draft = PresetDraft(newName: "n")
		draft.restPositions = PresetDraft.restPositions(globals.effectiveSettings)
		#expect(draft.sliderPosition(.iconSize) == grid.iconSize && draft.sliderPosition(.gridSpacing) == 30)
		#expect(draft.sliderPosition(.iconTextSize) == grid.textSize)
		draft.setFromSlider(.iconSize, 80)   // the slider only reports where it rests: still "유지"
		#expect(draft.isKept(.iconSize))
		// Finder's default view is drawn for a kept view style; none known: icon view.
		#expect(Self.make(ViewSettings(), defaults: PreviewDefaults(GlobalDefaults(preferredViewStyle: .list))).view == .list)
		#expect(Self.make(ViewSettings(), defaults: .factory).view == .icon)
		// Nothing kept: no Finder default is mentioned.
		let full = PresetEditorTests.full
		var set = full
		set.groupBy = .kind
		let q = Self.make(set)
		#expect(Self.kept(q).isEmpty && !q.viewKept && !q.footerLeading.contains("Finder"))
	}

	@Test func previewFollowsTheDraftAndKeepsTheLastValidNumber() {
		var draft = PresetDraft(preset: Preset(name: "p", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64))))
		var t = PreviewTracker(draft)
		#expect(t.settings.icon.iconSize == 64 && t.name == "p")
		for typed in ["1", "12"] {        // on the way to 128: a number, drawn as it would be saved (clamped to 16)
			draft.iconSize = typed
			t.follow(draft)
			#expect(t.settings.icon.iconSize == 16)
		}
		draft.iconSize = "128"
		t.follow(draft)
		#expect(t.settings.icon.iconSize == 128)
		for typed in ["abc", "12x"] {     // not a number: the preview stays at the last valid value
			draft.iconSize = typed
			t.follow(draft)
			#expect(t.settings.icon.iconSize == 128)
		}
		draft.iconSize = ""                 // × : "유지"
		t.follow(draft)
		#expect(t.settings.icon.iconSize == nil)
		draft.name = "renamed"
		draft.selectView(.list)
		draft.groupBy = .kind
		draft.sortColumn = .size
		t.follow(draft)
		#expect(t.name == "renamed" && t.settings.viewStyle == .list && t.settings.groupBy == .kind && t.settings.list.sortColumn == .size)
		// A direction without its column is never drawn.
		draft.sortColumn = nil
		draft.sortAscending = false
		t.follow(draft)
		#expect(t.settings.list.sortAscending == nil)
	}

	@Test func columnAndGalleryViews() throws {
		guard case .column(let c) = Self.make(ViewSettings(viewStyle: .column, groupBy: .kind)).content else { Issue.record("not a column view"); return }
		#expect(c.panes.count == 2 && c.panes[0].rows.contains { $0.header == "폴더" } && c.panes[0].rows.contains { $0.selected && $0.id == "photos" })
		#expect(c.panes[1].rows.map(\.id) == ["photos-2025", "photos-beach", "photos-walk"] && c.preview.id == "photos-beach")
		#expect(c.panes.allSatisfy { ($0.rows.last?.y ?? 0) + c.rowHeight <= PresetPreview.contentSize.height })
		let g = Self.make(ViewSettings(viewStyle: .gallery, groupBy: .kind))
		#expect(g.details.contains { $0.contains("묶음을 보이지 않습니다") })
		// The gallery says so on the picture too, only when the preset groups.
		if case .gallery(let gallery) = g.content { #expect(gallery.note != nil) } else { Issue.record("not a gallery") }
		if case .gallery(let gallery) = Self.make(ViewSettings(viewStyle: .gallery, groupBy: GroupBy.none)).content { #expect(gallery.note == nil) }
	}

	@Test func accessibilitySummaryIsOneLineAboutTheOptions() {
		let p = Self.make(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 256, textSize: 14, arrangeBy: .kind), groupBy: .kind))
		#expect(p.summary.hasPrefix("아이콘 보기, 아이콘 크기 256"))
		#expect(p.summary.contains("256") && p.summary.contains("실제 크기의") && p.summary.contains("종류") && !p.summary.contains("\n"))
		#expect(!p.summary.contains("여행 사진"), "the samples are not read one by one")
	}

	@Test func windowPlacement() {
		let panel = CGSize(width: 520, height: 478)
		let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
		let right = PresetPreviewController.placement(panel: panel, main: CGRect(x: 100, y: 300, width: 720, height: 478), visible: visible)
		#expect(right.minX == 828 && right.maxY == 778)
		let left = PresetPreviewController.placement(panel: panel, main: CGRect(x: 700, y: 300, width: 720, height: 478), visible: visible)
		#expect(left.maxX == 692 && left.maxY == 778)
		// A screen narrower than both (720 + 8 + 520 = 1248): the preview overlaps, inside the screen.
		let narrow = CGRect(x: 0, y: 0, width: 1200, height: 800)
		let middle = CGRect(x: 240, y: 200, width: 720, height: 478)
		#expect(PresetPreviewController.roomMaking(panel: panel, main: middle, visible: narrow) == nil)
		let over = PresetPreviewController.placement(panel: panel, main: middle, visible: narrow)
		#expect(narrow.contains(over) && over.intersects(middle))
		// Wide enough for both, but a centred main window leaves neither side room (1440, 1512, 1728pt screens): the main
		// window slides the least distance, and the preview then sits beside it, not over it.
		for width in [1248.0, 1440, 1512, 1728] {
			let screen = CGRect(x: 0, y: 25, width: width, height: 875)
			for x in [(width - 720) / 2, 418, (width - 720) / 2 - 30, (width - 720) / 2 + 30] {
				let main = CGRect(x: x, y: 300, width: 720, height: 478)
				let fitsNow = main.maxX + 8 + 520 <= screen.maxX || main.minX - 8 - 520 >= screen.minX
				let slid = PresetPreviewController.roomMaking(panel: panel, main: main, visible: screen)
				#expect((slid == nil) == fitsNow, "\(width) \(x)")
				let final = slid ?? main
				#expect(final.size == main.size && final.minY == main.minY && screen.contains(final))
				let beside = PresetPreviewController.placement(panel: panel, main: final, visible: screen)
				#expect(!beside.intersects(final) && screen.contains(beside), "\(width) \(x): \(beside) \(final)")
			}
		}
		// Centred on 1440: slides 168pt left (the preview goes right).
		let centred = CGRect(x: 360, y: 300, width: 720, height: 478)
		#expect(PresetPreviewController.roomMaking(panel: panel, main: centred, visible: CGRect(x: 0, y: 0, width: 1440, height: 875))?.minX == 192)
	}
}

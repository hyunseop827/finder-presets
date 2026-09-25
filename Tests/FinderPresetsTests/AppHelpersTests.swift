import Foundation
import AppKit
import Testing
import FinderPresetsCore
import DSStore
@testable import FinderPresets

@MainActor @Suite struct AppHelpersTests {
	/// "시스템 전체에 적용" with "홈 폴더 포함", on a home folder of its own (a temporary folder, never the real home): the
	/// standard folders with every subfolder, and elsewhere only the folders with view settings of their own — never
	/// ~/Library, hidden folders, a folder without settings of its own, or the Desktop unless it is included.
	@Test func systemPlanCoversTheHomeFolder() throws {
		// The temporary folder by its real path (/private/var/…, as the scanner lists the folders in it).
		let tmp = FileManager.default.temporaryDirectory.path
		let home = URL(fileURLWithPath: (tmp.hasPrefix("/var/") ? "/private" : "") + tmp).appendingPathComponent("finder-presets-home-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: home) }
		for d in ["Documents/Sub", "Downloads", "Developer/Proj", "Developer/Plain", "Library/X", ".hidden/Y", "Desktop/D"] {
			try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
		}
		// Developer and Developer/Proj have settings of their own (Library/X and .hidden/Y too, which are never planned).
		let list = ViewSettings(viewStyle: .list)
		try StoreEditor.write(try StoreEditor.apply(list, to: "Developer", in: StoreEditor.apply(list, to: "Library", in: DSStore(), bases: RecordBases()),
		                                            bases: RecordBases()), to: home.appendingPathComponent(".DS_Store"))
		try StoreEditor.write(try StoreEditor.apply(list, to: "Proj", in: DSStore(), bases: RecordBases()),
		                      to: home.appendingPathComponent("Developer/.DS_Store"))
		try StoreEditor.write(try StoreEditor.apply(list, to: "X", in: DSStore(), bases: RecordBases()),
		                      to: home.appendingPathComponent("Library/.DS_Store"))
		let preset = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		func planned(desktop: Bool) -> (roots: [String], changes: Set<String>) {
			let system = AppModel.systemPlan(preset, globals: .factory, home: home, includeDesktop: desktop)
			let base = home.standardizedFileURL.path + "/"
			return (system.roots.map(\.lastPathComponent),
			        Set(system.plan.changes.map { String($0.folder.standardizedFileURL.path.dropFirst(base.count)) }))
		}
		let without = planned(desktop: false)
		#expect(without.roots == [home.lastPathComponent, "Documents", "Downloads"])
		#expect(without.changes == ["Documents", "Documents/Sub", "Downloads", "Developer", "Developer/Proj"], "\(without.changes)")
		let with = planned(desktop: true)
		#expect(with.roots.last == "Desktop" && with.changes == without.changes.union(["Desktop", "Desktop/D"]), "\(with.changes)")
	}

	/// When the system-wide apply writes Finder's defaults with a bigger icon size, a folder of the home folder without
	/// settings of its own follows them: where Finder stored icon positions in it, they are removed (positions only, no
	/// view change); a folder without positions, and every folder when the defaults are not written, is left out. The
	/// Desktop keeps its positions also as a standard folder.
	@Test func systemPlanResetsPositionsOfFoldersFollowingTheDefaults() throws {
		let tmp = FileManager.default.temporaryDirectory.path
		let home = URL(fileURLWithPath: (tmp.hasPrefix("/var/") ? "/private" : "") + tmp).appendingPathComponent("finder-presets-home-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: home) }
		for d in ["Documents", "Notes", "Plain", "Desktop"] {
			try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
		}
		var positions = DSStore()
		try positions.setIconPosition(for: "a.txt", x: 107, y: 102)
		for d in ["Notes", "Desktop"] { try StoreEditor.write(positions, to: home.appendingPathComponent("\(d)/.DS_Store")) }
		let preset = Preset(name: "Big", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 128)))
		func positionsOnly(writesDefaults: Bool) -> [String] {
			AppModel.systemPlan(preset, globals: .factory, home: home, includeDesktop: true, writesDefaults: writesDefaults)
				.plan.entries.filter { $0.category == .iconPositionsOnly }.map(\.folder.lastPathComponent)
		}
		let system = AppModel.systemPlan(preset, globals: .factory, home: home, includeDesktop: true, writesDefaults: true)
		#expect(positionsOnly(writesDefaults: true) == ["Notes"])
		#expect(system.plan.iconPositionResets == 1)
		#expect(!system.plan.changes.contains { $0.folder.lastPathComponent == "Notes" || $0.folder.lastPathComponent == "Plain" })
		#expect(system.plan.changes.first { $0.folder.lastPathComponent == "Desktop" }?.resetsIconPositions == false)
		#expect(positionsOnly(writesDefaults: false).isEmpty)
	}

	/// The writes of "시스템 전체에 적용" (`AppModel.systemApplyWrite`) against a throwaway defaults domain, a temporary
	/// folder and a fake Finder (`HistoryModelTests.FakeFinder`; never com.apple.finder, the real home or the real
	/// Finder): the home folders are written while Finder is down, and read back once Finder was launched and given a
	/// moment to settle — like the quick preset, "지금 다시 시작" and `finder-presets apply --relaunch`. What Finder
	/// writes while it settles is therefore reported as overwritten. Both ways: with Finder's defaults (`GlobalApplier.apply`)
	/// and with the home folders alone (`runWithFinderQuit`). A Finder that did not come back is not waited for, but the
	/// home folders are still read back (like the other three), and one that does not quit leaves everything unwritten.
	@Test func systemApplyReadsTheHomeFoldersBackOnceFinderHasSettled() throws {
		let domain = HistoryModelTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "Nlsv", standardViewSettings: [:], domain: domain.name)
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 72)))
		let finderList = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 13))
		func request(_ folder: URL) -> ApplyRequest {
			let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
			let plan = planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: [folder]), roots: [folder])
			return ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings)
		}
		func run(_ folder: String, writesDefaults: Bool, finder: HistoryModelTests.FakeFinder) -> SystemApplyRun {
			AppModel.systemApplyWrite(preset, writesDefaults: writesDefaults, folderRequest: request(env.root.appendingPathComponent(folder)),
			                          applier: Applier(operations: env.store, globals: env.globals),
			                          globalApplier: GlobalApplier(operations: env.store, domain: domain.name, finder: finder))
		}
		func shows(_ folder: String) -> String { QuickPresetTests.shows(env.root.appendingPathComponent(folder)) }

		// With Finder's defaults: Finder writes its own view of A as it settles, after the launch.
		let finder = HistoryModelTests.FakeFinder()
		finder.onQuit = { [unowned finder] in finder.note("quit sees \(shows("A"))") }
		finder.onLaunch = { [unowned finder] in finder.note("launch sees \(shows("A"))") }
		finder.onSettle = { try? QuickPresetTests.finderWrites(finderList, for: env.root.appendingPathComponent("A")) }
		let global = run("A", writesDefaults: true, finder: finder)
		#expect(finder.events == ["quit", "quit sees none", "launch", "launch sees icon 72", "settle"])
		#expect(global.flowError == nil && global.folderError == nil && global.relaunched == true && global.globalOpID != nil)
		#expect(global.folderOp?.summary.changed == 1 && global.overwritten == 1 && domain.style() == "icnv")

		// The home folders alone: the same wait before the read-back.
		let alone = HistoryModelTests.FakeFinder()
		alone.onSettle = { try? QuickPresetTests.finderWrites(finderList, for: env.root.appendingPathComponent("B")) }
		let folders = run("B", writesDefaults: false, finder: alone)
		#expect(alone.events == ["quit", "launch", "settle"])
		#expect(folders.flowError == nil && folders.relaunched == true && folders.globalOpID == nil)
		#expect(folders.folderOp?.summary.changed == 1 && folders.overwritten == 1)

		// Nothing Finder writes after it settled is seen; without a write after the launch, nothing is overwritten.
		try FileManager.default.createDirectory(at: env.root.appendingPathComponent("C"), withIntermediateDirectories: true)
		let clean = HistoryModelTests.FakeFinder()
		let written = run("C", writesDefaults: false, finder: clean)
		#expect(clean.events == ["quit", "launch", "settle"] && written.overwritten == 0 && shows("C") == "icon 72")

		// Finder does not come back: no wait, but still a read-back (the write stays, recorded). The fake writes its view
		// of D as its launch fails, so only a read-back counts it.
		try FileManager.default.createDirectory(at: env.root.appendingPathComponent("D"), withIntermediateDirectories: true)
		let gone = HistoryModelTests.FakeFinder()
		gone.launchSucceeds = false
		gone.onLaunch = { try? QuickPresetTests.finderWrites(finderList, for: env.root.appendingPathComponent("D")) }
		let down = run("D", writesDefaults: false, finder: gone)
		#expect(gone.events == ["quit", "launch"] && down.relaunched == false && down.folderOp?.summary.changed == 1)
		#expect(down.overwritten == 1)
		// The same without that write: read back, nothing overwritten.
		try FileManager.default.createDirectory(at: env.root.appendingPathComponent("F"), withIntermediateDirectories: true)
		let goneClean = HistoryModelTests.FakeFinder()
		goneClean.launchSucceeds = false
		let downClean = run("F", writesDefaults: false, finder: goneClean)
		#expect(goneClean.events == ["quit", "launch"] && downClean.overwritten == 0 && shows("F") == "icon 72")

		// Finder does not quit: nothing is written, launched or read back.
		try FileManager.default.createDirectory(at: env.root.appendingPathComponent("E"), withIntermediateDirectories: true)
		let stays = HistoryModelTests.FakeFinder()
		stays.quitSucceeds = false
		let refused = run("E", writesDefaults: true, finder: stays)
		#expect(stays.events == ["quit"] && refused.flowError != nil && refused.folderOp == nil && refused.relaunched == nil)
		#expect(shows("E") == "none")
	}

	/// A "완료" line that also reports a failure, an overwrite or unchanged home folders is a warning, not a success.
	@Test func statusToneChecksWarningsFirst() {
		let tone = { (s: String) in StatusBar.tone(status: s, working: false) }
		#expect(tone("완료: 3개 폴더 변경") == .success)
		#expect(tone("완료: 2개 폴더 변경 (A 1개 폴더, B 1개 폴더) · 프리셋이 없어 건너뜀: C") == .success)
		#expect(tone("Finder를 다시 시작했습니다. 폴더를 열어 확인하세요.") == .success)
		#expect(tone("완료: 0개 폴더 변경, 3개 실패") == .warning)
		#expect(tone("완료: Finder 기본 보기를 \"P\"(으)로 변경 · 5개 폴더 변경 · Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.") == .warning)
		#expect(tone("완료: Finder 기본 보기를 \"P\"(으)로 변경 · 5개 폴더 변경 (그중 2개는 Finder가 덮어씀 — 다시 적용하세요) · Finder를 다시 시작했습니다.") == .warning)
		#expect(tone("완료: Finder 기본 보기를 \"P\"(으)로 변경 · 홈 폴더 변경 안 됨 · Finder를 다시 시작했습니다.") == .warning)
		#expect(tone("중단: 권한 없음 · 홈 폴더는 바꾸지 않음") == .warning)
		#expect(tone(AppModel.staleNote) == .warning)
		#expect(tone("아무것도 바꾸지 않았습니다. 확인하는 동안 프리셋이나 선택이 바뀌었습니다.") == .warning)
		#expect(tone(AppModel.cancelNote) == .info)
		#expect(tone("변경할 폴더가 없습니다. 이미 동일 4개") == .info)
		#expect(StatusBar.tone(status: "완료: 0개 폴더 변경, 3개 실패", working: true) == .working)
	}

	/// Names the user chose (set apart with `Fmt.name`) never decide the tone: only the app's words do.
	@Test func statusToneIgnoresNames() {
		let tone = { (s: String) in StatusBar.tone(status: s, working: false) }
		let assigned = String(localized: "\(Fmt.name("Failed takes, 충돌 보고서"))에 프리셋 \"\(Fmt.name("Stopped"))\"을(를) 지정했습니다. \"적용…\"을 눌러야 폴더가 바뀝니다.")
		#expect(tone(assigned) == .info)
		#expect(tone(String(localized: "\(Fmt.name("완료"))의 보기 설정을 프리셋으로 저장했습니다.")) == .info)
		#expect(tone("완료: 2개 폴더 변경 (\(Fmt.name("failed")) 2개 폴더)") == .success)
		#expect(tone("완료: 2개 폴더 변경, 1개 실패 (\(Fmt.name("OK")) 2개 폴더)") == .warning)   // the app's own word still counts
		// Without the marks a name alone could turn it (what Fmt.name prevents).
		#expect(tone("충돌 보고서에 프리셋을 지정했습니다.") == .warning)
		// The marks are invisible isolates; marks inside a name are dropped, so a name cannot close its own.
		#expect(Fmt.name("a\u{2069}b") == "\u{2068}ab\u{2069}")
		#expect(StatusBar.withoutNames("x \(Fmt.name("y"))z") == "x z")
	}

	/// The undo commands in the guide must work when pasted: `$HOME` instead of a quoted `~`, shell characters escaped.
	@Test func shellQuotedPaths() {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		#expect(HelpSheet.shellQuoted(home + "/FinderPresets-Test/app data") == "\"$HOME/FinderPresets-Test/app data\"")
		#expect(HelpSheet.shellQuoted("/Volumes/X/a\"b$c`d\\e") == "\"/Volumes/X/a\\\"b\\$c\\`d\\\\e\"")
		#expect(HelpSheet.shellQuoted(home + "-other/x") == "\"\(home)-other/x\"")
	}

	/// The window has one fixed size, smaller than before (1080×700), with room for five preset rows and seven folder
	/// rows. The sheets fit inside the window's content. The areas are derived from `content`, so their sums are not
	/// checked here: the layout probe (`--layout-probe`) measures the real list heights against these values
	/// and checks that five presets and seven folders fit without scrolling.
	@Test func fixedLayoutBudget() throws {
		let c = UILayout.content
		#expect(c == CGSize(width: 720, height: 440))
		// The main window's toolbar: the title and the three labelled buttons ("기록", "사용법", "최신 버전") beside the
		// window buttons (≈78pt) and the space around them (48pt), in both languages. Each button: its text, the symbol
		// with the 4pt before the text (20) and the button's own padding (about 16); the layout probe measures the real
		// item views (their frames, no overlap, the title).
		let english = try LocalizationTests.strings("en", "Localizable")
		let body = NSFont.preferredFont(forTextStyle: .body)
		let title = ("Finder Presets" as NSString).size(withAttributes: [.font: NSFont.titleBarFont(ofSize: 0)]).width
		#expect(MainView.toolbarLabels == [MainView.historyLabel, MainView.helpLabel, ReleaseLink.buttonLabel])
		for labels in [MainView.toolbarLabels, try MainView.toolbarLabels.map { try #require(english[$0], "no English for \($0)") }] {
			let buttons = labels.reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: body]).width + 20 + 16 }
			#expect(78 + title + buttons + 48 <= c.width - 100, "toolbar: \(labels) \(Int(title + buttons))pt")
		}
		// The list heights the layout is designed for.
		#expect(UILayout.presetListHeight == 224)
		#expect(UILayout.targetListHeight == 308)
		// Exactly five presets or seven folders never scroll. Measured on macOS 26 (the rows size themselves; the layout
		// probe measures the real ones): the inset list style keeps 10pt above the first and below the last row, and every
		// row is 40pt with its insets — every folder row has two lines, the inherited or missing preset note taking the
		// path's place, so the rows never differ in height.
		let listMargin: CGFloat = 10, rowHeight: CGFloat = 40
		#expect(UILayout.presetListHeight >= listMargin * 2 + 5 * rowHeight)
		#expect(UILayout.targetListHeight >= listMargin * 2 + 7 * rowHeight)
		// The summary box's export and delete icons are whole-size buttons (macOS minimum 20×20), and its fixed height
		// holds them: 4 + 20 (name row) + 4 + 46 (three summary lines) + 4.
		#expect(PresetSummaryPanel.iconButton.width >= 20 && PresetSummaryPanel.iconButton.height >= 20)
		#expect(UILayout.summaryHeight >= 4 + PresetSummaryPanel.iconButton.height + 4 + 46 + 4)
		#expect(HelpSheet.size.width <= c.width - 40)
		#expect(HelpSheet.size.height <= c.height - 20)
		#expect(GlobalConfirmSheet.width <= c.width - 40)
		// The Settings window (its own window, not a sheet): the language, then the quick preset — its starred preset, the
		// shortcut macOS has given the service, and the two buttons that lead to it. 346 high:
		// 16 + picker 64 + (10 + caption 32) + divider 21 + relaunch row 34 + divider 21 + quick preset 132 + 16, where
		// the quick preset's 132 is the name row 22, the shortcut line 22, the button row 22 (6pt apart) and the 48pt
		// three-line caption.
		#expect(LanguageSettingsView.size == CGSize(width: 460, height: 346))
		// The walkthrough sheet ("단축키 설정 방법") opens on the Settings window. It is narrower than that window and
		// deliberately taller (like the history sheet on the main window): six steps, each with a drawing of the pane in
		// question. Its parts add up to its height, so nothing scrolls.
		#expect(ShortcutGuideSheet.size == CGSize(width: 440, height: 460))
		#expect(ShortcutGuideSheet.size.width <= LanguageSettingsView.size.width)
		#expect(ShortcutGuideSheet.size.height <= 560)   // with the small window behind it, still far inside a laptop screen
		#expect(ShortcutGuideSheet.steps.count == 6 && ShortcutGuideSheet.marks.count == ShortcutGuideSheet.steps.count)
		// 16 + header 34 + drawing + text (17 + 4 + 68) + action row 24 + dots 20 + divider 1 + bottom row 24 + 16, with
		// six 10pt gaps: the drawing gets the rest (176pt) and never less than the tallest of the six needs. The dots row
		// (only a position since the sheet no longer advances by itself) keeps the 20pt it had with the play button.
		let guideFixed: CGFloat = 32 + 34 + (17 + 4 + ShortcutGuideSheet.textHeight) + ShortcutGuideSheet.actionHeight + 20 + 1 + 24 + 6 * 10
		#expect(ShortcutGuideSheet.size.height - guideFixed >= ShortcutGuideSheet.drawingMinHeight)
		// That minimum is what the tallest drawing really needs — the services list of ④ and ⑤: `GuidePanel`'s title bar
		// 20, its divider 1 and its 10pt padding twice around a content of 123 (search row 18, "일반" 13, three 18pt rows
		// 7pt apart 68, three 8pt gaps 24). The layout probe measures each drawing's content against the box it gets.
		let tallestDrawing: CGFloat = 18 + 13 + 68 + 3 * 8
		#expect(tallestDrawing == 123 && ShortcutGuideSheet.drawingMinHeight == 20 + 1 + 20 + tallestDrawing)
		// The step's sentence gets four lines of `.callout` (16pt a line in both languages); the probe measures the
		// sentence's own height against this slot, so a longer text cannot be cut off unnoticed.
		#expect(ShortcutGuideSheet.textHeight >= 4 * 16)
		// The history sheet is the one sheet larger than the window: its details draw the applied preset the way the
		// editor's preview window does, beside the folders the operation changed. It keeps one fixed size (never
		// resizable) that still fits a laptop screen with the window behind it. 540 high: the details' sentences get
		// 100pt above the picture, which never moves whichever record is chosen (the layout probe checks both).
		#expect(HistorySheet.size == CGSize(width: 880, height: 540))
		#expect(HistorySheet.size.width <= 1000 && HistorySheet.size.height <= 700)
		// The details' pane: the preview's picture and a folder list at least 170pt wide fit side by side in it.
		let detail = HistorySheet.size.width - 32 - HistorySheet.listWidth - 10 - 20
		#expect(detail >= PreviewPicture.size.width + 10 + 170)
		// The middle row holds the picture, its heading (17) and the caption under it that says which view was drawn.
		#expect(HistorySheet.previewRowHeight >= PreviewPicture.size.height + 17 + HistorySheet.captionHeight)
		#expect(HistorySheet.captionHeight >= 26)
		// It fits in the pane with the sentences above it and "되돌리기…" below: the pane is the sheet without the header
		// row, the divider row and the two paddings (≈119, measured by the layout probe) and without its own 20.
		#expect(HistorySheet.size.height - 145 >= 70 + HistorySheet.previewRowHeight + 8 + UILayout.actionRowHeight)
	}

	/// The summary grid: six items in reading order (보기 | 정렬, 아이콘 | 목록, 레이블 | 정보·미리보기); a value the preset
	/// leaves alone reads "유지" and is dimmed. The options without a cell of their own are counted in their view's cell
	/// ("+N"), and the tooltip / VoiceOver text names every option the preset sets.
	@Test func settingsSummaryItems() {
		let empty = SettingsSummary.items(ViewSettings())
		#expect(empty.map(\.short) == ["보기", "정렬", "아이콘", "목록", "레이블", "정보·미리보기"])
		#expect(empty.allSatisfy { $0.value == "유지" && $0.kept })
		#expect(SettingsSummary.details(ViewSettings()) == ["모든 옵션 유지"])
		let icon = SettingsSummary.items(ViewSettings(
			viewStyle: .icon,
			icon: IconViewSettings(iconSize: 48, textSize: 10, labelOnBottom: false, showItemInfo: false, showIconPreview: true, arrangeBy: .kind),
			list: ListViewSettings(sortColumn: .dateModified, sortAscending: false)))
		#expect(icon.map(\.value) == ["아이콘", "종류", "48 / 10", "수정일 ↓", "오른쪽", "끔 / 켬"])
		#expect(icon.allSatisfy { !$0.kept })
		#expect(icon.map(\.long) == ["보기 방식", "정렬 기준", "아이콘 보기", "목록 보기", "레이블 위치", "항목 정보 / 미리보기"])

		// Only list options (no cell of their own): the "목록" cell counts them, the text names them all.
		let listOnly = ViewSettings(list: ListViewSettings(textSize: 14, useRelativeDates: false))
		let items = SettingsSummary.items(listOnly)
		#expect(items[3].value == "옵션 2개" && !items[3].kept)
		#expect(items.filter { !$0.kept }.count == 1)
		#expect(SettingsSummary.details(listOnly) == ["목록 보기 · 텍스트 크기: 14", "목록 보기 · 상대적 날짜: 끔", "나머지 옵션 13개는 유지"])
		#expect(PresetRow.summary(listOnly) == "보기 방식 유지 · 옵션 2개")
		// With a sort column and grid spacing: "+N" next to the value shown.
		let more = ViewSettings(icon: IconViewSettings(iconSize: 64, gridSpacing: 40), list: ListViewSettings(textSize: 12, sortColumn: .name, sortAscending: true, calculateAllSizes: true))
		let moreItems = SettingsSummary.items(more)
		#expect(moreItems[2].value == "64 / 유지 +1" && moreItems[3].value == "이름 ↑ +2")
		#expect(SettingsSummary.items(ViewSettings(icon: IconViewSettings(gridSpacing: 40)))[2].value == "격자 40")
		#expect(SettingsSummary.setCount(more) == 5)
		#expect(PresetRow.summary(more) == "보기 방식 유지 · 아이콘 64 · +4")
		#expect(PresetRow.summary(ViewSettings(viewStyle: .column, list: ListViewSettings(textSize: 12))) == "컬럼 · 옵션 1개")
		// The grouping, shown by every view, is counted in the "보기" cell and named in the details.
		let grouped = ViewSettings(viewStyle: .list, groupBy: .kind)
		#expect(SettingsSummary.items(grouped)[0].value == "목록 +1" && !SettingsSummary.items(grouped)[0].kept)
		#expect(SettingsSummary.items(ViewSettings(groupBy: .dateModified))[0].value == "그룹 수정일")
		#expect(SettingsSummary.items(ViewSettings(groupBy: GroupBy.none))[0].value == "그룹 없음")
		#expect(SettingsSummary.details(grouped) == ["보기 방식: 목록", "그룹 기준: 종류", "나머지 옵션 13개는 유지"])
		#expect(SettingsSummary.setCount(grouped) == 2)
		#expect(PresetRow.summary(grouped) == "목록 · 옵션 1개")
		#expect(PresetRow.summary(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 48), groupBy: .kind)) == "아이콘 · 아이콘 48 · +1")
		#expect(GroupBy.allCases.map { Fmt.group($0) } == ["없음", "종류", "응용 프로그램", "마지막 열람일", "추가일", "수정일", "생성일", "크기"])
		#expect(Fmt.group(nil) == "유지")
	}

	/// "종료" while a task writes or has Finder quit is put off and goes ahead when the task ends; the app launches Finder
	/// when it quits only if one of its tasks quit Finder and Finder did not come back (AppDelegate, `AppModel.terminateReply`).
	@Test func quitWaitsForWritesAndFinder() {
		var g = QuitGuard()
		var ok = g.requestQuit()
		#expect(ok)                                               // nothing running: quit at once
		g.begin(quitsFinder: false)
		ok = g.requestQuit()
		#expect(!ok && g.quitWhenDone && g.writing)
		ok = g.end(finderRunning: true)
		#expect(ok && g.quitting)                                 // the task ended: the quit goes ahead now (no new alert)
		#expect(!g.writing && !g.quitWhenDone && !g.relaunchOnQuit(finderRunning: false))
		g.dropQuit()                                              // an error to read, or a sheet in the way
		#expect(!g.quitting)
		g.begin(quitsFinder: true)
		ok = g.end(finderRunning: false)
		#expect(!ok && !g.quitting)                               // no quit was asked meanwhile
		#expect(g.relaunchOnQuit(finderRunning: false) && !g.relaunchOnQuit(finderRunning: true))
		g.begin(quitsFinder: true)
		ok = g.end(finderRunning: true)
		#expect(!ok && !g.relaunchOnQuit(finderRunning: false))  // Finder came back this time
		ok = g.end(finderRunning: true)
		#expect(!ok)                                              // ending again changes nothing
		g.begin(quitsFinder: false)
		ok = g.end(finderRunning: false)
		#expect(!ok && !g.relaunchOnQuit(finderRunning: false))  // a folder write never quits Finder
	}

	/// A number beyond what `Int` holds (a hand-edited or imported preset file) is shown, never a crash.
	@Test func hugeNumbersAreShownAsTheyAre() {
		let huge = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 1e19, textSize: -1e300, gridSpacing: 9.3e18),
		                        list: ListViewSettings(textSize: 1e19, iconSize: -9.3e18))
		#expect(Fmt.num(1e19) == "1e+19" && Fmt.num(64) == "64" && Fmt.num(12.5) == "12.5" && Fmt.num(-1e300) == "-1e+300")
		#expect(PresetRow.summary(huge).contains("1e+19"))
		#expect(SettingsSummary.items(huge)[2].value == "1e+19 / -1e+300 +1")
		#expect(SettingsSummary.details(huge).contains("목록 보기 · 아이콘 크기: -9.3e+18"))
		#expect(PresetDraft.text(1e19) == "1e+19")
	}

	/// Names in the folder rows' preset menu are shortened in the middle to its text slot; short ones stay as they are.
	@Test func fittedNames() {
		let font = NSFont.systemFont(ofSize: 11)
		func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
		#expect(Fmt.fitted("선택한 프리셋 사용", width: PresetTag.textWidth, font: font) == "선택한 프리셋 사용")
		let long = "긴 이름의 프리셋 1 아주 길게 아주 길게 아주 길게 아주 길게"
		let fitted = Fmt.fitted(long, width: PresetTag.textWidth, font: font)
		#expect(fitted.contains("…") && width(fitted) <= PresetTag.textWidth)
		#expect(fitted.hasPrefix("긴") && fitted.hasSuffix("길게"))
		#expect(Fmt.fitted(long, width: 1, font: font) == "…")
	}
}

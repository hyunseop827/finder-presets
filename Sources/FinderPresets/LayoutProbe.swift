#if DEBUG
import Foundation
import AppKit
import FinderPresetsCore

/// Debug builds only (`./scripts/build-app.sh` without `release`); a release build has no `--layout-probe`.
///
/// `FinderPresets --layout-probe` (with `FINDER_PRESETS_DATA_DIR`): checks in the running app that the window has its fixed
/// size (content 720×440 below the toolbar), that the user cannot resize it (no `.resizable`, zoom button disabled, no
/// full screen, no window tabs), and that nothing the content does changes that. It records the main window's frame,
/// then changes what the window shows — selection, the desktop warning, a long status line, many or no folders and
/// presets, exactly seven folders (with inherited, missing-preset and warning rows) and five presets, a folder added at
/// the end of a long list, a long preset name, a preset or folder that sorts first added and selected, a new preset in
/// the middle of a long list and the selected one deleted there, the error alert, the delete confirmation, the help
/// sheet, the apply confirmation, the whole-system sheet, the toolbar's three labelled buttons ("기록", "사용법", "최신 버전":
/// their text is not clipped, they lie inside the window, overlap neither each other nor the window title, and fit beside
/// it in this run's language), the preset editor (an existing preset, every value set with a
/// long name and values that cannot be saved, a duplicate name, a new preset, values kept from the preset outside what
/// the sliders offer, each on "유지" and each of the four views, then each segment of its view control clicked — in light
/// and dark; one fixed size for all, every option of the view inside it, no scroll area; its preview window beside the
/// main window at its fixed size, never key, no scroll area, everything it draws inside it, hidden and shown with the eye
/// button, closed with the editor, for every view with large, tiny, grouped and all-"유지" drafts in light and dark), the status line's "되돌리기…" shortcut, the Settings window (its fixed size, no scroll area, its parts inside it — the language and the quick preset with the line that says which shortcut macOS gave the service: "없음" and no shortcut in light, a starred preset with ⌃⌥⌘P in dark, then the same shortcut with the service switched off; the walkthrough sheet "단축키 설정 방법" on it — every step in light, ①·⑤·⑥ in dark, ⑥ with the service switched off — still on the step it was opened at once measured, "이전" off only on ① and "다음" only on ⑥), the history sheet (the
/// data folder's real records, then in memory a long list, a record of each state the details word — undoable, undone,
/// nothing to undo, an undo record, one being written and a leftover —, the undo confirmations with many conflicts, the
/// running state, a result and its "Finder를 다시 시작할까요?"; the details' sentences and its "되돌리기…" row stay inside
/// the right-hand pane, so nothing is clipped in either language), light and dark appearance — and after each step checks the
/// frame, the fixed-size settings, the scroll areas (exactly the two lists, 224 and 308pt high, inside the window,
/// neither bouncing nor scrolled away from their top while their rows fit), that seven folders and five presets fit
/// without scrolling, that a new or newly selected row of a long list is scrolled into view, and the frames of the
/// areas and of the whole-system bar's controls (inside the window, not overlapping). Prints `[layoutprobe] PASS` or
/// `FAIL: …` and exits 0/1.
///
/// Needs: the data folder must already hold presets, folders (`targets.json`) and recorded operations (made with the app
/// or `finder-presets`); the probe only reads them.
///
/// Safety: every change stays in memory. Assigning `targets` / `presets` / `quickPresetID` does not save them, the appearance is set on
/// this process only, and nothing that writes is called (`dismissHelp`, `confirmApply`, `confirmGlobalApply`,
/// `confirmDeletePreset`, `addFolders`, `importPreset`, `confirmUndo`, `setPinned`, `runRetention`, `savePresetEdit`).
/// The only model calls are `prepareApply`, which only reads the folders listed in the isolated data folder,
/// `requestDeletePreset`, which only asks, `openHistory`, which only reads the records, and `beginEditPreset` /
/// `beginNewPreset` / `cancelPresetEdit`, which only open and close the editor; both confirmations are closed with "취소", the error alert
/// with "확인", the history sheet's restart question with "나중에" (its undo states are set in memory, never
/// confirmed). The shortcut states of the Settings window come from a dictionary in memory
/// (`ServiceShortcut.Development`): no preference domain of the system is read, the `pbs` domain least of all, and the
/// walkthrough's "키보드 설정 열기…" is never pressed, so no System Settings opens. The window is taken out of
/// the saved window state.
@MainActor
enum LayoutProbe {
	/// How to start the probe; printed when `FINDER_PRESETS_DATA_DIR` is missing.
	static let usage = "FINDER_PRESETS_DATA_DIR=<folder> FinderPresets --layout-probe"

	static var isRequested: Bool { CommandLine.arguments.contains("--layout-probe") }

	/// Frames of the views marked with `probeFrame(_:)`, in SwiftUI's global (window) coordinates.
	static var frames: [String: CGRect] = [:]


	/// The preset editor sheet's own copy of the draft (it edits a copy; the model's is only written by "저장"), recorded
	/// by the sheet while the probe runs, so switching the view can be checked against what the sheet really holds.
	static var editorDraft: PresetDraft?

	/// What the preset editor's preview window draws now (Views/PresetPreviewWindow.swift), recorded while the probe or
	/// the self-test runs.
	static var previewModel: PresetPreview?

	@discardableResult
	static func runIfRequested(model: AppModel) -> Bool {
		guard isRequested else { return false }
		@MainActor func log(_ s: String) { print("[layoutprobe] \(s)"); fflush(stdout) }
		guard !(ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"] ?? "").isEmpty else {
			log("FAIL: FINDER_PRESETS_DATA_DIR 가 없습니다. 레이아웃 점검은 격리된 데이터 폴더로만 실행합니다. 사용법: \(usage)")
			exit(1)
		}
		Task { @MainActor in
			@MainActor func mainWindow() -> NSWindow? {
				NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.contentView != nil }
			}
			@MainActor func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }
			await settle(1000)
			guard let window = mainWindow() else { log("FAIL: 메인 창을 찾지 못했습니다"); exit(1) }
			// The language the bundle chose (to compare with the `-AppleLanguages` the probe was started with).
			log("language: \(AppLanguage.code)")
			window.isRestorable = false
			var failures: [String] = []
			let content = UILayout.content

			@MainActor func size(_ s: NSSize) -> String { "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))" }
			@MainActor func rect(_ r: CGRect) -> String {
				"(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))x\(Int(r.height.rounded())))"
			}

			/// Closes an alert the way a user does, with its button. Clearing the model state instead makes SwiftUI close
			/// the alert sheet from inside a layout pass, which crashes AppKit now and then (seen on macOS 26).
			/// `nested`: an alert on top of a sheet (the history sheet's restart question).
			@MainActor func pressAlertButton(_ title: String, nested: Bool = false, orElse clear: () -> Void) async {
				@MainActor func find(_ view: NSView) -> NSButton? {
					if let button = view as? NSButton, button.title == title { return button }
					for sub in view.subviews { if let found = find(sub) { return found } }
					return nil
				}
				let alert = nested ? window.attachedSheet?.attachedSheet : window.attachedSheet
				if let content = alert?.contentView, let button = find(content) {
					button.performClick(nil)
				} else {
					log("주의: 알림의 \"\(title)\" 버튼을 찾지 못해 상태를 직접 지웁니다")
					clear()
				}
				await settle()
			}

			/// The window settings that keep the user from resizing it. Empty = all in place.
			@MainActor func fixedProblems() -> [String] {
				var problems: [String] = []
				let c = window.contentLayoutRect.size
				if abs(c.width - content.width) > 1 || abs(c.height - content.height) > 1 {
					problems.append("콘텐츠가 \(size(content))이 아닙니다: \(size(c))")
				}
				if window.styleMask.contains(.resizable) { problems.append("사용자가 창 크기를 바꿀 수 있습니다") }
				if window.standardWindowButton(.zoomButton)?.isEnabled != false { problems.append("확대 버튼이 켜져 있습니다") }
				if !window.collectionBehavior.contains(.fullScreenNone) || window.collectionBehavior.contains(.fullScreenPrimary) {
					problems.append("전체 화면이 가능합니다")
				}
				// A tab bar (보기 > 탭 막대 보기) would make the window 28pt taller, and its "+" would open a second window.
				if window.tabbingMode != .disallowed { problems.append("창 탭이 허용됩니다") }
				if NSWindow.allowsAutomaticWindowTabbing { problems.append("보기 메뉴에 탭 막대 항목이 생깁니다(allowsAutomaticWindowTabbing)") }
				if let item = menuItem(in: NSApp.mainMenu, actions: [#selector(NSWindow.toggleTabBar(_:)), #selector(NSWindow.toggleTabOverview(_:))]) {
					problems.append("메뉴에 \"\(item.title)\" 항목이 있습니다")
				}
				return problems
			}

			/// The toolbar's three buttons ("기록", "사용법", "최신 버전"): each shows its name beside its symbol (its item is
			/// wide enough for the text in this run's language), each lies inside the window, no two overlap, none overlaps the
			/// window's title, and the title and the buttons fit the fixed 720pt width. Measured on the toolbar's own item
			/// views: the SwiftUI label inside a toolbar item is laid out more than once (a narrow copy lives off to the left
			/// on some Macs), so its own frame is not what the user sees. The title is the text field in the title bar that
			/// shows the window's title; when it cannot be found, only the width sum below stands for it (and the log says so).
			@MainActor func toolbarProblems(_ step: String) -> [String] {
				let labels = MainView.toolbarLabels
				let views = (window.toolbar?.items ?? []).compactMap(\.view)
				guard views.count == labels.count else {
					return ["\(step): 툴바 버튼을 찾지 못했습니다 (\(views.count)개, 기대 \(labels.count)개)"]
				}
				var problems: [String] = []
				let font = NSFont.preferredFont(forTextStyle: .body)
				var widths: CGFloat = 0
				// In the window's coordinates (origin at the bottom left, the title bar included).
				let bounds = CGRect(origin: .zero, size: window.frame.size).insetBy(dx: -0.5, dy: -0.5)
				var frames: [CGRect] = []
				for (text, view) in zip(labels, views) {
					// The text with its symbol (about 16pt) and the 4pt between them; the button's own padding is on top.
					let needed = (text as NSString).size(withAttributes: [.font: font]).width + 20
					let width = max(view.frame.width, view.fittingSize.width)
					if width + 1 < needed {
						problems.append("툴바 \"\(text)\" 버튼의 글자가 잘립니다: \(Int(width.rounded()))pt < \(Int(needed.rounded(.up)))pt")
					}
					if view.frame.height < 10 { problems.append("툴바 \"\(text)\" 버튼이 그려지지 않았습니다: \(rect(view.frame))") }
					let frame = view.convert(view.bounds, to: nil)
					if !bounds.contains(frame) { problems.append("툴바 \"\(text)\" 버튼이 창 밖입니다: \(rect(frame))") }
					frames.append(frame)
					widths += width
				}
				for i in frames.indices {
					for j in frames.indices where j > i && frames[i].insetBy(dx: 0.5, dy: 0.5).intersects(frames[j].insetBy(dx: 0.5, dy: 0.5)) {
						problems.append("툴바 \"\(labels[i])\"와 \"\(labels[j])\" 버튼이 겹칩니다: \(rect(frames[i])), \(rect(frames[j]))")
					}
				}
				// The title's own text field, when the title bar has one that shows it.
				func titleField(in view: NSView) -> NSTextField? {
					if let field = view as? NSTextField, field.stringValue == window.title, !field.isHidden, field.frame.width > 0 { return field }
					for sub in view.subviews { if let found = titleField(in: sub) { return found } }
					return nil
				}
				let titleText = (window.title as NSString).size(withAttributes: [.font: NSFont.titleBarFont(ofSize: 0)]).width
				var titleNote = "제목 뷰 없음(폭으로만 확인)"
				if let root = window.contentView?.superview, let field = titleField(in: root) {
					let title = field.convert(field.bounds, to: nil)
					// The text itself, not the field's whole width (a title field can be as wide as the space it is given).
					let text = CGRect(x: field.alignment == .center ? title.midX - titleText / 2 : title.minX, y: title.minY,
					                  width: min(titleText, title.width), height: title.height)
					titleNote = "제목 \(rect(text))"
					for (label, frame) in zip(labels, frames) where frame.insetBy(dx: 0.5, dy: 0.5).intersects(text) {
						problems.append("툴바 \"\(label)\" 버튼이 창 제목과 겹칩니다: \(rect(frame)), 제목 \(rect(text))")
					}
				}
				// The title, the buttons, the window buttons (≈78pt) and the space around them.
				let needed = 78 + titleText + widths + 48
				if needed > window.frame.width {
					problems.append("툴바가 좁습니다: 제목 \(Int(titleText.rounded())) + 버튼 \(Int(widths.rounded())) + 여백이 \(Int(window.frame.width))pt를 넘습니다")
				}
				let described = zip(labels, frames).map { "\"\($0)\" \(rect($1))" }.joined(separator: ", ")
				log("  \(step): 툴바 \(described), 제목 \"\(window.title)\" \(Int(titleText.rounded()))pt, \(titleNote)")
				return problems.map { "\(step): \($0)" }
			}

			/// Where the history sheet's fixed parts sat at the first step with a selected record: every later one must
			/// put them at exactly the same place (choosing another record never moves anything but the sentences).
			var historyLayout: [String: CGRect]?
			let historyFixedParts = ["historySheet", "historyDetailWell", "historyDetailText", "historyPreview", "historyFolders",
			                         "historyDetailActions", "historyBottomRow"]

			/// The history sheet: its panes are inside it, the details' sentences and the state fit the right-hand pane
			/// above its "되돌리기…" row (nothing clipped, whatever the language), and the sheet's own row is inside the
			/// sheet. Called only for a step with a selected operation (the frames of the details are recorded then).
			@MainActor func historyProblems(_ step: String) -> [String] {
				guard let root = frames["historySheet"], let bottom = frames["historyBottomRow"] else {
					return ["\(step): 기록 시트의 프레임이 기록되지 않았습니다 (\(frames.keys.filter { $0.hasPrefix("history") }.sorted()))"]
				}
				var problems: [String] = []
				let inside = root.insetBy(dx: -0.5, dy: -0.5)
				if abs(root.width - HistorySheet.size.width) > 0.5 || abs(root.height - HistorySheet.size.height) > 0.5 {
					problems.append("기록 시트 내용이 \(size(HistorySheet.size))이 아닙니다: \(rect(root))")
				}
				if !inside.contains(bottom) { problems.append("시트의 아래쪽 줄이 시트 밖입니다: \(rect(bottom))") }
				guard let well = frames["historyDetailWell"], let text = frames["historyDetailText"],
				      let actions = frames["historyDetailActions"] else {
					return problems.map { "\(step): \($0)" } + ["\(step): 자세한 내용의 프레임이 기록되지 않았습니다"]
				}
				let pane = well.insetBy(dx: -0.5, dy: -0.5)
				if !inside.contains(well) { problems.append("오른쪽 칸이 시트 밖입니다: \(rect(well))") }
				if !pane.contains(text) { problems.append("자세한 내용이 오른쪽 칸을 넘칩니다: \(rect(text)), 칸 \(rect(well))") }
				if !pane.contains(actions) { problems.append("되돌리기 줄이 오른쪽 칸을 넘칩니다: \(rect(actions)), 칸 \(rect(well))") }
				if text.maxY > actions.minY + 0.5 { problems.append("자세한 내용과 되돌리기 줄이 겹칩니다: \(rect(text)), \(rect(actions))") }
				if bottom.minY < well.maxY - 0.5 { problems.append("시트의 아래쪽 줄이 칸과 겹칩니다: \(rect(bottom)), \(rect(well))") }
				// The preset's picture and the folders beside it: inside the pane, below the sentences, above "되돌리기…".
				guard let preview = frames["historyPreview"], let folders = frames["historyFolders"] else {
					return problems.map { "\(step): \($0)" } + ["\(step): 미리보기·폴더 목록의 프레임이 기록되지 않았습니다"]
				}
				if !pane.contains(preview) { problems.append("프리셋 미리보기가 오른쪽 칸을 넘칩니다: \(rect(preview)), 칸 \(rect(well))") }
				if !pane.contains(folders) { problems.append("폴더 목록이 오른쪽 칸을 넘칩니다: \(rect(folders)), 칸 \(rect(well))") }
				if preview.maxX > folders.minX + 0.5 { problems.append("미리보기와 폴더 목록이 겹칩니다: \(rect(preview)), \(rect(folders))") }
				if text.maxY > preview.minY + 0.5 { problems.append("자세한 내용과 미리보기가 겹칩니다: \(rect(text)), \(rect(preview))") }
				if max(preview.maxY, folders.maxY) > actions.minY + 0.5 {
					problems.append("미리보기·폴더 목록과 되돌리기 줄이 겹칩니다: \(rect(preview)), \(rect(folders)), \(rect(actions))")
				}
				// The sentences fit their area in every state the probe shows (they only scroll for longer ones).
				if let content = frames["historyDetailTextContent"], content.height > text.height + 0.5 {
					problems.append("자세한 내용이 칸에 다 들어가지 않아 스크롤됩니다: 내용 \(Int(content.height))pt > 칸 \(Int(text.height))pt")
				}
				let layout = Dictionary(uniqueKeysWithValues: historyFixedParts.compactMap { key in frames[key].map { (key, $0) } })
				if let first = historyLayout {
					for key in historyFixedParts where first[key] != layout[key] {
						problems.append("\(key) 자리가 다른 기록을 골랐을 때와 다릅니다: \(first[key].map(rect) ?? "-") → \(layout[key].map(rect) ?? "-")")
					}
				} else {
					historyLayout = layout
				}
				log("  \(step): 시트 \(rect(root)), 오른쪽 칸 \(rect(well)), 내용 \(rect(text))(글 \(Int(frames["historyDetailTextContent"]?.height ?? 0))pt), 미리보기 \(rect(preview)), 폴더 \(rect(folders)), 되돌리기 줄 \(rect(actions)), 아래쪽 줄 \(rect(bottom))")
				return problems.map { "\(step): \($0)" }
			}

			@MainActor func menuItem(in menu: NSMenu?, actions: [Selector]) -> NSMenuItem? {
				for item in menu?.items ?? [] {
					if let action = item.action, actions.contains(action) { return item }
					if let found = menuItem(in: item.submenu, actions: actions) { return found }
				}
				return nil
			}

			@MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
				((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
			}

			/// The scroll areas from left to right: the preset list, then the folder list.
			@MainActor func lists() -> [NSScrollView] {
				guard let root = window.contentView else { return [] }
				return scrollViews(in: root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
			}

			@MainActor func overflow(_ scroll: NSScrollView) -> CGFloat {
				let insets = scroll.contentInsets
				return (scroll.documentView?.frame.height ?? 0) - (scroll.contentView.bounds.height - insets.top - insets.bottom)
			}

			/// List `index` (0 presets, 1 folders) shows all its rows without scrolling.
			@MainActor func fitProblem(list index: Int) -> String? {
				let all = lists()
				guard all.count > index else { return "목록 \(index + 1)을 찾지 못했습니다" }
				let over = overflow(all[index])
				return over <= 0.5 ? nil : "목록이 \(Int(over.rounded()))pt 넘쳐 스크롤됩니다"
			}

			/// Row `row` of list `index` (0 presets, 1 folders) is whole inside the list's visible area.
			@MainActor func rowProblem(list index: Int, row: Int) -> String? {
				let all = lists()
				guard all.count > index, let table = all[index].documentView as? NSTableView else { return "목록 \(index + 1)을 찾지 못했습니다" }
				guard row < table.numberOfRows else { return "목록에 \(row)번 행이 없습니다 (행 \(table.numberOfRows)개)" }
				let r = table.rect(ofRow: row)
				return table.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(r) ? nil
					: "\(row)번 행이 보이지 않습니다 (행 \(rect(r)), 보이는 영역 \(rect(table.visibleRect)))"
			}

			/// Exactly the two lists scroll: inside the window, never sideways, not at all while their rows fit.
			@MainActor func scrollProblems(_ step: String) -> [String] {
				guard let root = window.contentView else { return ["콘텐츠 뷰가 없습니다"] }
				let scrolls = scrollViews(in: root)
				var problems: [String] = []
				if scrolls.count != 2 {
					problems.append("스크롤 영역이 2개가 아닙니다: \(scrolls.count)개 (\(scrolls.map { String(describing: type(of: $0.documentView ?? $0)) }))")
				}
				let visible = window.contentLayoutRect.insetBy(dx: -1, dy: -1)
				// The lists take exactly the heights UILayout gives them (224 and 308).
				for (scroll, height) in zip(lists(), [UILayout.presetListHeight, UILayout.targetListHeight]) {
					let actual = scroll.convert(scroll.bounds, to: nil).height
					if abs(actual - height) > 0.5 { problems.append("목록 높이가 \(Int(height))이 아닙니다: \(Int(actual.rounded()))") }
				}
				for (i, scroll) in scrolls.enumerated() {
					let name = "스크롤 영역 \(i + 1)"
					if !(scroll.documentView is NSTableView) {
						problems.append("\(name)이 목록이 아닙니다: \(String(describing: scroll.documentView.map { type(of: $0) }))")
					}
					let frame = scroll.convert(scroll.bounds, to: nil)
					if !visible.contains(frame) { problems.append("\(name)이 창 밖으로 넘칩니다: \(rect(frame))") }
					if scroll.horizontalScrollElasticity != .none { problems.append("\(name)이 가로로 튕깁니다") }
					if !scroll.autohidesScrollers { problems.append("\(name)의 스크롤 막대가 늘 보입니다") }
					let documentHeight = scroll.documentView?.frame.height ?? 0
					let insets = scroll.contentInsets
					let visibleHeight = scroll.contentView.bounds.height - insets.top - insets.bottom
					let fits = documentHeight <= visibleHeight + 0.5
					if fits && scroll.verticalScrollElasticity != .none {
						problems.append("\(name)은 넘치지 않는데 세로로 튕깁니다 (문서 \(Int(documentHeight)), 보이는 높이 \(Int(visibleHeight)))")
					}
					// Its rows fit, so it must show them from the top (found: a preset that sorts first, imported and
					// selected, left the list 16pt scrolled with the first row cut).
					let offset = scroll.contentView.bounds.minY + insets.top
					if fits && abs(offset) > 0.5 {
						problems.append("\(name)은 넘치지 않는데 \(Int(offset.rounded()))pt 스크롤된 채입니다")
					}
					if !fits {
						log("  \(step): \(name) 문서 \(Int(documentHeight)) > 보이는 높이 \(Int(visibleHeight)), 세로 탄성 \(scroll.verticalScrollElasticity == .none ? "없음" : "있음")")
					}
				}
				return problems
			}

			/// The preset list (the left one of the two) shows its selected row whole.
			@MainActor func selectedRowProblem() -> String? {
				guard let table = lists().first?.documentView as? NSTableView else { return "프리셋 목록을 찾지 못했습니다" }
				guard let index = model.presets.firstIndex(where: { $0.id == model.selectedPresetID }) else { return "선택한 프리셋이 없습니다" }
				guard table.numberOfRows == model.presets.count else { return "목록 행 \(table.numberOfRows)개, 프리셋 \(model.presets.count)개" }
				if table.selectedRow != index { log("  주의: 목록의 선택 행 \(table.selectedRow), 선택한 프리셋 \(index)번") }
				return rowProblem(list: 0, row: index).map { "선택한 프리셋: \($0)" }
			}

			/// The areas stay inside the window's content and the whole-system bar's controls do not overlap.
			@MainActor func frameProblems() -> [String] {
				var problems: [String] = []
				let f = frames
				func need(_ id: String) -> CGRect? {
					if let r = f[id] { return r }
					problems.append("\(id) 프레임이 기록되지 않았습니다")
					return nil
				}
				guard let root = need("root") else { return problems }
				if abs(root.width - content.width) > 0.5 || abs(root.height - content.height) > 0.5 {
					problems.append("루트가 \(size(content))이 아닙니다: \(rect(root))")
				}
				let inside = root.insetBy(dx: -0.5, dy: -0.5)
				for id in ["presetSection", "targetSection", "systemBar", "statusBar"] {
					if let r = need(id), !inside.contains(r) { problems.append("\(id)이 창 밖으로 넘칩니다: \(rect(r))") }
				}
				// The preset list's "+" and the summary box's four icon buttons (빠른 적용 별표, 편집, 내보내기, 삭제): whole
				// 22×20 buttons in their areas, 4pt apart, never over the selected preset's name.
				let iconButton = PresetSummaryPanel.iconButton
				func isIconButton(_ r: CGRect) -> Bool { abs(r.width - iconButton.width) <= 0.5 && abs(r.height - iconButton.height) <= 0.5 }
				if let plus = need("newPreset"), let section = need("presetSection") {
					if !isIconButton(plus) { problems.append("새 프리셋 버튼이 \(size(iconButton))이 아닙니다: \(rect(plus))") }
					if !section.insetBy(dx: -0.5, dy: -0.5).contains(plus) { problems.append("새 프리셋 버튼이 프리셋 영역 밖입니다: \(rect(plus))") }
				}
				if let box = need("presetSummaryBox"), let name = need("summaryName"), let star = need("quickPreset"), let edit = need("editPreset"),
				   let export = need("exportPreset"), let delete = need("deletePreset") {
					for (id, r) in [("빠른 적용", star), ("편집", edit), ("내보내기", export), ("삭제", delete)] {
						if !isIconButton(r) { problems.append("선택한 프리셋 칸의 \(id) 버튼이 \(size(iconButton))이 아닙니다: \(rect(r))") }
						if !box.insetBy(dx: -0.5, dy: -0.5).contains(r) { problems.append("선택한 프리셋 칸의 \(id) 버튼이 칸 밖입니다: \(rect(r))") }
					}
					if abs(edit.minX - star.maxX - 4) > 0.5 || abs(export.minX - edit.maxX - 4) > 0.5 || abs(delete.minX - export.maxX - 4) > 0.5 {
						problems.append("선택한 프리셋 칸의 아이콘 버튼 사이가 4pt가 아닙니다: \(rect(star)) \(rect(edit)) \(rect(export)) \(rect(delete))")
					}
					if name.maxX > star.minX + 0.5 { problems.append("선택한 프리셋 칸: 이름과 빠른 적용 버튼이 겹칩니다") }
				}
				if let title = need("systemTitle"), let chip = need("systemPreset"), let options = need("systemOptions"),
				   let button = need("applySystem"), let bar = need("systemBar") {
					if title.maxX > chip.minX + 0.5 { problems.append("시스템 막대: 제목과 프리셋 칩이 겹칩니다") }
					if chip.maxX > options.minX + 0.5 { problems.append("시스템 막대: 프리셋 칩과 옵션이 겹칩니다") }
					if options.maxX + 8 > button.minX + 0.5 { problems.append("시스템 막대: 옵션과 버튼 사이가 8pt보다 좁습니다 (\(Int(button.minX - options.maxX)))") }
					if button.maxX > bar.maxX - UILayout.edge + 0.5 { problems.append("시스템 막대: 버튼이 오른쪽 여백을 넘습니다") }
					for r in [title, chip, options, button] where !(bar.insetBy(dx: -0.5, dy: -0.5).contains(r)) {
						problems.append("시스템 막대 밖의 컨트롤: \(rect(r))")
					}
				}
				return problems
			}

			let base = window.frame.size
			/// `sheetSize`: the sheet must have exactly this size (a fixed-size sheet, whatever it shows).
			/// `largerThanWindow`: this sheet is allowed to be larger than the window's content — only the history sheet is,
			/// and only the step that opened it may say so (never the measured size, which a later sheet could happen to share).
			@MainActor func check(_ step: String, sheet: Bool = false, sheetSize: CGSize? = nil, largerThanWindow: Bool = false) async {
				await settle()
				let now = window.frame.size
				log("\(step): 창 \(size(now)), 콘텐츠 \(size(window.contentLayoutRect.size))")
				var problems: [String] = []
				if now != base { problems.append("창 크기 \(size(base)) → \(size(now))") }
				problems += fixedProblems() + scrollProblems(step) + frameProblems()
				if sheet {
					if let attached = window.attachedSheet {
						// A sheet keeps one fixed size and never resizes the window. It usually fits the window's content;
						// the history sheet is larger, because it draws the applied preset beside the folder list, and then
						// only the screen bounds it.
						let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
						if attached.frame.width > visible.width - 40 || attached.frame.height > visible.height - 40 {
							problems.append("시트 \(size(attached.frame.size))가 화면 \(size(visible.size))에 들어가지 않습니다")
						}
						if !largerThanWindow,
						   attached.frame.height > window.contentLayoutRect.height + 0.5 || attached.frame.width > window.frame.width + 0.5 {
							problems.append("시트 \(size(attached.frame.size))가 창 콘텐츠 \(size(window.contentLayoutRect.size))보다 큽니다")
						}
						log("  시트: \(size(attached.frame.size))")
						if let expected = sheetSize, abs(attached.frame.width - expected.width) > 0.5 || abs(attached.frame.height - expected.height) > 0.5 {
							problems.append("시트가 고정 크기 \(size(expected))가 아닙니다: \(size(attached.frame.size))")
						}
					} else {
						problems.append("시트가 열리지 않았습니다")
					}
				}
				failures += problems.map { "\(step): \($0)" }
			}

			/// The preset editor's view control: the one segmented control of the sheet.
			@MainActor func viewControl() -> NSSegmentedControl? {
				@MainActor func segmented(_ v: NSView) -> [NSSegmentedControl] {
					((v as? NSSegmentedControl).map { [$0] } ?? []) + v.subviews.flatMap(segmented)
				}
				guard let content = window.attachedSheet?.contentView else { return nil }
				let all = segmented(content)
				return all.count == 1 ? all[0] : nil
			}

			/// The preset editor (its own window's coordinates): the header, the name row with the view control, the view's
			/// panel and the bottom row lie inside the sheet's 16pt padding, one below the other, with the panel's last row
			/// inside it — so every option of the view is shown and nothing needs scrolling — and the sheet has no scroll area
			/// at all. The view control is a segmented control with "유지" and the four views, the view style selected, drawn
			/// inside the name row after the name field and the caption, which are whole (neither overlaps the next).
			@MainActor func editorProblems(_ step: String, view: ViewStyle?) -> [String] {
				guard let sheet = window.attachedSheet else { return ["\(step): 편집 시트가 없습니다"] }
				var problems: [String] = []
				var control: CGRect?
				if let content = sheet.contentView {
					let scrolls = scrollViews(in: content)
					if !scrolls.isEmpty { problems.append("편집 시트에 스크롤 영역이 \(scrolls.count)개 있습니다") }
					if let switcher = viewControl() {
						let index = ViewSwitcher.index(view)
						if switcher.segmentCount != 5 || switcher.selectedSegment != index {
							problems.append("보기 버튼: 칸 \(switcher.segmentCount)개, 선택 \(switcher.selectedSegment) (기대 \(index))")
						}
						// The drawn control (its alignment rect): the view's frame reaches past it by the bezel's outset (2pt
						// on each side), which SwiftUI lays out beyond the row on purpose.
						let r = switcher.convert(switcher.alignmentRect(forFrame: switcher.bounds), to: nil)
						// AppKit's window coordinates start at the bottom; SwiftUI's global frames at the top.
						control = CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
					} else {
						problems.append("보기 버튼(분할 컨트롤)이 하나가 아닙니다")
					}
				}
				let f = frames
				guard let root = f["editorSheet"], let header = f["editorHeader"], let top = f["editorTopRow"], let panel = f["editorPanel"],
				      let footer = f["editorFooter"], let last = f["editorLastRow"], let name = f["editorNameField"],
				      let caption = f["editorViewResult"] else {
					return ["\(step): 편집 시트의 프레임이 기록되지 않았습니다 (\(f.keys.filter { $0.hasPrefix("editor") }.sorted()))"]
				}
				if let control {
					if !top.insetBy(dx: -1, dy: -1).contains(control) { problems.append("보기 버튼이 이름 줄 밖입니다: \(rect(control)), 줄 \(rect(top))") }
					if caption.maxX > control.minX + 0.5 { problems.append("보기 설명과 보기 버튼이 겹칩니다: \(rect(caption)), \(rect(control))") }
				}
				if name.maxX + 8 > caption.minX + 0.5 { problems.append("이름 칸과 보기 설명이 겹칩니다: \(rect(name)), \(rect(caption))") }
				// The header's second line (what "유지" means) is whole: the eye button shares the title's line only.
				if let text = f["editorHeaderText"] {
					let font = NSFont.preferredFont(forTextStyle: .subheadline)
					let needed = (PresetEditorSheet.headerSecondLine as NSString).size(withAttributes: [.font: font]).width
					if needed > text.width + 0.5 { problems.append("머리의 둘째 줄이 잘립니다: \(Int(needed.rounded(.up)))pt > \(Int(text.width))pt") }
					if let toggle = f["editorPreviewToggle"], toggle.maxY > text.minY + 22 { problems.append("눈 버튼이 제목 줄 밖입니다: \(rect(toggle))") }
				} else {
					problems.append("머리 글 칸의 프레임이 기록되지 않았습니다")
				}
				if abs(name.width - PresetEditorSheet.nameWidth) > 0.5 { problems.append("이름 칸이 \(Int(PresetEditorSheet.nameWidth))이 아닙니다: \(rect(name))") }
				if !top.insetBy(dx: -0.5, dy: -0.5).contains(caption) { problems.append("보기 설명이 이름 줄 밖입니다: \(rect(caption))") }
				let expected = PresetEditorSheet.size
				if abs(root.width - expected.width) > 0.5 || abs(root.height - expected.height) > 0.5 {
					problems.append("편집 시트 내용이 \(size(expected))이 아닙니다: \(rect(root))")
				}
				if abs(panel.height - PresetEditorSheet.panelHeight) > 0.5 {
					problems.append("옵션 칸 높이가 \(Int(PresetEditorSheet.panelHeight))이 아닙니다: \(rect(panel))")
				}
				let inner = root.insetBy(dx: 15.5, dy: 15.5)
				for (name, r) in [("머리", header), ("이름 줄", top), ("옵션 칸", panel), ("아래쪽 줄", footer)] where !inner.contains(r) {
					problems.append("편집 시트의 \(name)이 여백(16pt) 안에 없습니다: \(rect(r)), 시트 \(rect(root))")
				}
				if header.maxY > top.minY + 0.5 || top.maxY > panel.minY + 0.5 {
					problems.append("편집 시트: 머리, 이름 줄, 옵션 칸이 차례로 있지 않습니다: \(rect(header)) \(rect(top)) \(rect(panel))")
				}
				if panel.maxY > footer.minY + 0.5 { problems.append("편집 시트: 옵션 칸과 아래쪽 줄이 겹칩니다") }
				if !panel.insetBy(dx: 0.5, dy: 0.5).contains(last) {
					problems.append("편집 시트: \(EditorText.viewTitle(view))의 마지막 줄이 칸 밖입니다: \(rect(last)), 칸 \(rect(panel))")
				}
				log("  편집 시트(\(view?.rawValue ?? "keep")): 이름 칸 \(rect(name)), 설명 \(rect(caption)), 보기 버튼 \(control.map(rect) ?? "-"), 옵션 칸 \(rect(panel)), 마지막 줄 \(rect(last)), 아래쪽 줄 \(rect(footer))")
				return problems.map { "\(step): \($0)" }
			}

			/// The preset editor's preview window (Views/PresetPreviewWindow.swift) while the editor is open: a panel of its
			/// fixed size that cannot be resized, made full screen, key or main; a normal-level window (not a child window, which
			/// the sheet's dimming would cover), not restorable and
			/// not in the Window menu; on a screen; beside the main window (not over it or the sheet) when there is room on
			/// its screen; no scroll area; its header, content and footer inside it one below the other; the model it draws
			/// has every item, header and column inside the content area, a folder and an image among them, and the view
			/// the editor shows (Finder's default for "유지"). Empty while hidden with the eye button (`expectShown`).
			@MainActor func previewProblems(_ step: String, view: ViewStyle?, expectShown: Bool = true) -> [String] {
				let controller = PresetPreviewController.shared
				var problems: [String] = []
				guard controller.shown == expectShown else { return ["\(step): 미리보기 보기 설정이 \(controller.shown)입니다 (기대 \(expectShown))"] }
				guard let panel = controller.window, panel.isVisible else {
					return expectShown ? ["\(step): 미리보기 창이 열리지 않았습니다"] : []
				}
				if !expectShown { return ["\(step): 숨긴 미리보기 창이 보입니다"] }
				let expected = PresetPreviewController.contentSize
				let c = panel.contentRect(forFrameRect: panel.frame).size
				if abs(c.width - expected.width) > 0.5 || abs(c.height - expected.height) > 0.5 {
					problems.append("미리보기 창 콘텐츠가 \(size(expected))이 아닙니다: \(size(c))")
				}
				if panel.styleMask.contains(.resizable) { problems.append("미리보기 창의 크기를 바꿀 수 있습니다") }
				if !panel.collectionBehavior.contains(.fullScreenNone) || panel.collectionBehavior.contains(.fullScreenPrimary) { problems.append("미리보기 창이 전체 화면이 될 수 있습니다") }
				if panel.canBecomeKey || panel.canBecomeMain || panel.isKeyWindow { problems.append("미리보기 창이 키 창이 될 수 있습니다") }
				if NSApp.keyWindow === panel { problems.append("미리보기 창이 키보드를 가져갔습니다") }
				if panel.isRestorable || !panel.isExcludedFromWindowsMenu || panel.tabbingMode != .disallowed {
					problems.append("미리보기 창이 복원되거나 윈도우 메뉴·탭에 나옵니다")
				}
				if panel.parent != nil { problems.append("미리보기 창이 다른 창의 자식 창입니다(시트의 흐림이 덮음)") }
				if panel.level != .normal || panel.isFloatingPanel { problems.append("미리보기 창이 다른 앱 창 위에 뜹니다(level \(panel.level.rawValue))") }
				if !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame) }) {
					problems.append("미리보기 창이 화면 밖입니다: \(rect(panel.frame))")
				}
				if let visible = window.screen?.visibleFrame {
					let w = panel.frame.width, gap = PresetPreviewController.gap
					// The screen fits both side by side (the main window slides aside when it must): never over it or the sheet.
					let fitsBoth = visible.width >= window.frame.width + gap + w
					if fitsBoth && panel.frame.intersects(window.frame) { problems.append("화면에 자리가 있는데 미리보기 창이 메인 창과 겹칩니다: \(rect(panel.frame)), \(rect(window.frame))") }
					if fitsBoth, let sheet = window.attachedSheet, panel.frame.intersects(sheet.frame) { problems.append("미리보기 창이 편집 시트와 겹칩니다") }
					if abs(panel.frame.maxY - window.frame.maxY) > 0.5 && fitsBoth { problems.append("미리보기 창의 위쪽이 메인 창과 맞지 않습니다") }
					if !visible.insetBy(dx: -1, dy: -1).contains(window.frame) { problems.append("메인 창이 화면 밖으로 밀렸습니다: \(rect(window.frame))") }
				}
				// Stacking: the preview is ordered below the editor sheet (so even overlapping on a narrow screen it never
				// covers the sheet's buttons) and above the main window.
				if let sheet = window.attachedSheet {
					let order = NSWindow.windowNumbers(options: []) ?? []
					if let s = order.firstIndex(of: NSNumber(value: sheet.windowNumber)), let p = order.firstIndex(of: NSNumber(value: panel.windowNumber)), p < s {
						problems.append("미리보기 창이 편집 시트보다 위에 있습니다")
					}
				}
				if let root = panel.contentView {
					let scrolls = scrollViews(in: root)
					if !scrolls.isEmpty { problems.append("미리보기 창에 스크롤 영역이 \(scrolls.count)개 있습니다") }
				}
				if !panel.title.hasPrefix(String(localized: "미리보기")) { problems.append("미리보기 창의 제목: \(panel.title)") }
				if let header = frames["previewHeader"], let content = frames["previewContent"], let footer = frames["previewFooter"] {
					let top = header.minY
					let bounds = CGRect(x: 0, y: top, width: expected.width, height: expected.height).insetBy(dx: -0.5, dy: -0.5)
					for (id, r) in [("머리", header), ("내용", content), ("아랫줄", footer)] + (frames["previewBadges"].map { [("배지", $0)] } ?? []) where !bounds.contains(r) {
						problems.append("미리보기 창의 \(id)이 창 밖입니다: \(rect(r))")
					}
					if header.maxY > content.minY + 0.5 || content.maxY > footer.minY + 0.5 { problems.append("미리보기 창: 머리, 내용, 아랫줄이 차례로 있지 않습니다") }
					if abs(content.width - PresetPreview.contentSize.width) > 0.5 || abs(content.height - PresetPreview.contentSize.height) > 0.5 {
						problems.append("미리보기 내용이 \(size(PresetPreview.contentSize))이 아닙니다: \(rect(content))")
					}
				} else {
					problems.append("미리보기 창의 프레임이 기록되지 않았습니다")
				}
				if let p = previewModel {
					let drawn = view ?? model.globals.preferredViewStyle ?? .icon
					if p.view != drawn || p.viewKept != (view == nil) { problems.append("미리보기가 \(drawn.rawValue)를 그리지 않습니다: \(p.view.rawValue)") }
					problems += previewModelProblems(p)
					// The footer's one line is never cut: both texts, the info symbol (about 22pt with its spacing), the row's
					// paddings (2 × 12) and the spacing around its spacer (3 × 8) fit its width, with 4pt to spare.
					let footer = PreviewIcons.measure(p.footerLeading, 11) + PreviewIcons.measure(p.footerTrailing, 11) + 22 + 24 + 24 + 4
					if footer > expected.width { problems.append("미리보기 아랫줄이 잘립니다(\(Int(footer))pt): \(p.footerLeading) | \(p.footerTrailing)") }
				} else {
					problems.append("미리보기 모델이 기록되지 않았습니다")
				}
				return problems.map { "\(step): \($0)" }
			}

			/// What the preview draws lies inside its content area, with a folder and an image among the items.
			@MainActor func previewModelProblems(_ p: PresetPreview) -> [String] {
				let box = CGRect(origin: .zero, size: PresetPreview.contentSize).insetBy(dx: -0.5, dy: -0.5)
				var problems: [String] = []
				var types: Set<PreviewFileType> = []
				switch p.content {
				case .icon(let g):
					for cell in g.cells {
						types.insert(cell.item.type)
						if !box.contains(cell.frame) || !box.contains(cell.icon) || !box.contains(cell.label) || !(cell.info.map(box.contains) ?? true) {
							problems.append("미리보기 항목 \(cell.id)이 칸 밖입니다: \(rect(cell.frame))")
						}
					}
					for h in g.headers where !box.contains(h.frame) { problems.append("미리보기 머리글 \(h.title)이 칸 밖입니다") }
				case .list(let t):
					for row in t.rows {
						types.insert(row.item.type)
						if row.y + t.rowHeight > box.maxY { problems.append("미리보기 행 \(row.id)이 칸 밖입니다") }
					}
					if let last = t.columns.last, abs(last.x + last.width - PresetPreview.contentSize.width) > 0.5 { problems.append("미리보기 열 너비의 합이 칸과 다릅니다") }
					if Set(t.columns.map(\.id)).isSuperset(of: [.name, .dateModified, .size, .kind]) == false { problems.append("미리보기 목록에 열이 빠졌습니다") }
					// Names are never cut (AppKit's width of each label with its tag dots, the icon and the paddings).
					if let name = t.columns.first {
						for row in t.rows {
							let label = PreviewIcons.measure(PresetPreview.labelText(row.item.name, tags: row.item.tags.count), t.textSize)
							let needed = 2 * PresetPreview.listPadding + t.iconSide + PresetPreview.listIconSpacing + label
							if needed > name.width + 0.5 { problems.append("미리보기 목록의 이름이 잘립니다: \(row.item.name) \(Int(needed))pt > \(Int(name.width))pt") }
						}
					}
				case .column(let b):
					for pane in b.panes { for row in pane.rows where row.y + b.rowHeight > box.maxY { problems.append("미리보기 컬럼 행 \(row.id)이 칸 밖입니다") } }
					types = [.folder, .jpeg]
				case .gallery(let g):
					types = Set(g.strip.map(\.type))
				}
				if !types.contains(.folder) || !(types.contains(.jpeg) || types.contains(.png)) { problems.append("미리보기에 폴더나 이미지가 없습니다: \(types.map(\.rawValue).sorted())") }
				return problems
			}

			/// The eye button's action hides the preview and shows it again (the sheet stays, the window unchanged); the
			/// choice the user had is put back.
			@MainActor func previewToggleSteps(_ step: String) async {
				let controller = PresetPreviewController.shared
				let before = UserDefaults.standard.object(forKey: PresetPreviewController.shownKey)
				// The view the sheet shows now (its own copy: the view control may have changed it).
				let view: ViewStyle? = editorDraft.map(\.viewStyle) ?? model.presetEditor?.viewStyle
				controller.setShown(false)
				await settle()
				failures += previewProblems(step + " [미리보기 숨김]", view: view, expectShown: false)
				if window.attachedSheet == nil { failures.append(step + ": 미리보기를 숨기자 시트가 닫혔습니다") }
				controller.setShown(true)
				await settle()
				failures += previewProblems(step + " [미리보기 다시 보임]", view: view)
				if let before { UserDefaults.standard.set(before, forKey: PresetPreviewController.shownKey) } else { UserDefaults.standard.removeObject(forKey: PresetPreviewController.shownKey) }
				log("  \(step): 미리보기 숨김/보임 확인, 창 \(controller.window.map { rect($0.frame) } ?? "-"), 메인 \(rect(window.frame))")
			}

			/// The main window centred on its screen — where it opens on most screens (1440–1728pt wide), with room beside it
			/// for the preview on neither side: opening the editor slides the main window aside just enough and the preview
			/// sits beside it, over neither the main window nor the sheet, and below the sheet; the eye button hides it (the
			/// main window goes back) and shows it again (slides again); closing the editor puts the main window back where
			/// the user had it.
			@MainActor func previewCentredSteps(_ preset: Preset, prefix: String) async {
				guard let visible = window.screen?.visibleFrame else { failures.append(prefix + "미리보기: 화면이 없습니다"); return }
				let original = window.frame
				let centred = CGRect(x: (visible.midX - original.width / 2).rounded(), y: original.minY, width: original.width, height: original.height)
				window.setFrame(centred, display: true)
				await settle()
				let step = prefix + "미리보기: 가운데 둔 메인 창"
				frames = frames.filter { !$0.key.hasPrefix("editor") }
				model.beginEditPreset(preset.id)
				await settle(300)
				await check(step, sheet: true, sheetSize: PresetEditorSheet.size)
				let view = model.presetEditor?.viewStyle
				failures += previewProblems(step, view: view)
				let panelWidth = PresetPreviewController.shared.window?.frame.width ?? 0
				let fitsBoth = visible.width >= original.width + PresetPreviewController.gap + panelWidth
				let roomBeside = centred.maxX + PresetPreviewController.gap + panelWidth <= visible.maxX || centred.minX - PresetPreviewController.gap - panelWidth >= visible.minX
				if fitsBoth && !roomBeside && window.frame.origin == centred.origin { failures.append(step + ": 메인 창이 비켜서지 않았습니다") }
				log("  \(step): 화면 \(rect(visible)), 가운데 \(rect(centred)) → 메인 \(rect(window.frame)), 미리보기 \(PresetPreviewController.shared.window.map { rect($0.frame) } ?? "-")")
				await previewToggleSteps(step)
				model.cancelPresetEdit()
				await settle(700)
				if window.frame.origin != centred.origin { failures.append(step + ": 편집을 닫은 뒤 메인 창이 제자리로 돌아오지 않았습니다: \(rect(window.frame)), 기대 \(rect(centred))") }
				if PresetPreviewController.shared.isVisible { failures.append(step + ": 편집을 닫은 뒤에도 미리보기 창이 남았습니다") }
				window.setFrame(original, display: true)
				await settle()
			}

			/// Every view ("유지" and the four) with drafts that stress the preview (large icons with long labels, tiny ones,
			/// a grouped list with every option, everything kept): the preview window passes `previewProblems` each time.
			/// Opened in memory like `editorSteps` and closed with "취소".
			@MainActor func previewSteps(_ prefix: String) async {
				var big = PresetDraft(newName: "preview-big")
				(big.iconSize, big.iconTextSize, big.gridSpacing) = ("512", "16", "100")
				(big.labelOnBottom, big.showItemInfo, big.iconShowPreview, big.arrangeBy, big.groupBy) = (false, true, false, .kind, .kind)
				var small = PresetDraft(newName: "preview-small")
				(small.iconSize, small.iconTextSize, small.gridSpacing, small.groupBy, small.arrangeBy) = ("16", "10", "1", .dateModified, .dateAdded)
				var list = PresetDraft(newName: "preview-list")
				(list.listTextSize, list.listIconSize, list.sortColumn, list.sortAscending) = ("16", 32, .dateAdded, false)
				(list.useRelativeDates, list.calculateAllSizes, list.listShowPreview, list.groupBy) = (false, true, true, .size)
				let kept = PresetDraft(newName: "preview-kept")
				for (name, base) in [("큰 아이콘", big), ("작은 아이콘", small), ("목록", list), ("모두 유지", kept)] {
					for view in ViewSwitcher.choices {
						// The preview window's frames stay recorded (its view is not rebuilt, only redrawn).
						frames = frames.filter { !$0.key.hasPrefix("editor") }
						previewModel = nil
						var draft = base
						draft.viewStyle = view
						draft.token = UUID()
						model.presetEditor = draft
						let step = prefix + "미리보기 \(name) [\(EditorText.viewTitle(view))]"
						await check(step, sheet: true, sheetSize: PresetEditorSheet.size)
						failures += previewProblems(step, view: view)
						if let p = previewModel { log("  \(step): \(p.shownItems)/\(p.totalItems) \(p.scaleBadge ?? "") \(p.footerLeading)") }
					}
				}
				model.cancelPresetEdit()
				await settle()
				if PresetPreviewController.shared.isVisible { failures.append(prefix + "미리보기: 편집 시트를 닫은 뒤에도 창이 남았습니다") }
			}

			/// Opens the editor in each of its states (an existing preset; every value set with a long name and values
			/// that cannot be saved; a duplicate name with a refused save's reason; a new preset; values kept from the
			/// preset outside what the editor offers) on "유지" and on each of the four views, then clicks each segment of
			/// the view control: the sheet has the same size in all of them, the window stays 720×478, opening changes
			/// nothing in the sheet's copy of the draft, a click changes exactly what `PresetDraft.selectView` changes (the
			/// view style, and a typed text that is not a number the new view does not show) and never the model's draft. Closes it with
			/// "취소".
			@MainActor func editorSteps(_ preset: Preset, prefix: String) async {
				let presetsBefore = model.presets
				var sheetSizes: Set<String> = []
				@MainActor func checkEditor(_ name: String, view: ViewStyle?) async {
					await check(name, sheet: true, sheetSize: PresetEditorSheet.size)
					failures += editorProblems(name, view: view)
					failures += previewProblems(name, view: view)
					if let sheet = window.attachedSheet { sheetSizes.insert(size(sheet.frame.size)) }
					if size(window.frame.size) != "720x478" { failures.append("\(name): 창이 720x478이 아닙니다: \(size(window.frame.size))") }
				}
				@MainActor func show(_ step: String, _ make: () -> PresetDraft, problem: String? = nil) async {
					var last: PresetDraft?
					for view in ViewSwitcher.choices {
						// Every opening is a sheet with a new identity (`PresetDraft.token`), which records all its frames and
						// its draft once.
						frames = frames.filter { !$0.key.hasPrefix("editor") }
						editorDraft = nil
						var draft = make()
						draft.viewStyle = view
						draft.token = UUID()
						model.presetEditor = draft
						if let problem { model.presetEditorProblem = problem }
						let name = prefix + step + " [\(EditorText.viewTitle(view))]"
						await checkEditor(name, view: view)
						// Opening (sliders and menus included) never changes the sheet's copy.
						if editorDraft == nil || editorDraft != draft { failures.append("\(name): 시트를 열자 초안이 바뀌었습니다 (또는 기록되지 않음)") }
						last = draft
					}
					// The view control of the last opening, clicked segment by segment like a user does.
					guard let opened = last else { return }
					for view in ViewSwitcher.choices.reversed() where view != opened.viewStyle {
						guard let switcher = viewControl(), let before = editorDraft else { failures.append(prefix + step + ": 보기 버튼이나 초안이 없습니다"); break }
						frames["editorLastRow"] = nil
						switcher.selectedSegment = ViewSwitcher.index(view)
						switcher.sendAction(switcher.action, to: switcher.target)
						let name = prefix + step + " [\(EditorText.viewTitle(view)) 누름]"
						await checkEditor(name, view: view)
						var expected = before
						expected.selectView(view)
						if editorDraft != expected { failures.append("\(name): 보기 버튼이 보기 방식 말고 다른 값을 바꿨습니다") }
						if model.presetEditor != opened { failures.append("\(name): 보기 버튼이 모델의 초안을 바꿨습니다") }
					}
				}
				await show("프리셋 편집 시트") {
					model.beginEditPreset(preset.id)
					return model.presetEditor ?? PresetDraft(preset: preset)
				}
				if model.presetEditor?.original?.id != preset.id { failures.append(prefix + "프리셋 편집 시트: 그 프리셋의 값으로 열리지 않았습니다") }
				await previewToggleSteps(prefix + "프리셋 편집 시트")
				var full = PresetDraft(preset: preset)
				full.name = String(repeating: "아주 긴 프리셋 이름 ", count: 8)
				// Texts that are not numbers (a typed number out of range is clamped, not refused), so the warning line shows.
				(full.iconSize, full.iconTextSize, full.gridSpacing, full.listTextSize) = ("600px", "12,5", "abc", "16")
				(full.arrangeBy, full.labelOnBottom, full.showItemInfo, full.iconShowPreview) = (.dateLastOpened, false, true, true)
				(full.sortColumn, full.sortAscending, full.listIconSize) = (.dateLastOpened, false, 32)
				(full.listShowPreview, full.useRelativeDates, full.calculateAllSizes) = (true, false, true)
				full.groupBy = .dateLastOpened
				await show("편집 시트: 모든 값·긴 이름·잘못된 값") { full }
				if full.check(others: model.presetsOtherThan(full)).problems.count != 3 {
					failures.append(prefix + "편집 시트: 잘못된 값 3개를 찾지 못했습니다: \(full.check(others: model.presetsOtherThan(full)).problems)")
				}
				var duplicate = PresetDraft(preset: preset)
				duplicate.name = model.presets.last { $0.id != preset.id }?.name ?? preset.name
				await show("편집 시트: 같은 이름 경고·저장하지 않은 이유", { duplicate },
				           problem: String(repeating: PresetDraft.CommitError.changedOnDisk.message + " ", count: 6))
				await show("새 프리셋 시트") {
					model.beginNewPreset()
					return model.presetEditor ?? PresetDraft(newName: "new")
				}
				if model.presetEditor?.isNew != true || model.presetEditor.map({ d in
					var kept = d
					kept.viewStyle = nil
					return kept.check(others: model.presets).warnings.isEmpty
				}) != false {
					failures.append(prefix + "새 프리셋 시트: 모든 값이 유지인 새 프리셋이 아닙니다")
				}
				// Values kept from the preset although the editor does not offer them: a list icon size of 20, an icon size
				// beyond the slider, a grid spacing between its steps, a fractional text size. The sliders draw them clamped
				// and never write them back (the sheet's copy stays equal).
				let odd = Preset(name: "odd", settings: ViewSettings(icon: IconViewSettings(iconSize: 1000, textSize: 12.5, gridSpacing: 45.25),
				                                                     list: ListViewSettings(textSize: 9, iconSize: 20)))
				await show("편집 시트: 슬라이더 범위 밖의 값·목록 아이콘 크기 20") { PresetDraft(preset: odd) }
				if PresetDraft(preset: odd).check(others: []).settings != odd.settings { failures.append(prefix + "편집 시트: 프리셋의 범위 밖 값을 지키지 못했습니다") }
				if sheetSizes.count != 1 { failures.append(prefix + "편집 시트: 보기·상태마다 크기가 다릅니다: \(sheetSizes.sorted())") }
				log("  \(prefix)편집 시트 크기: \(sheetSizes.sorted())")
				model.cancelPresetEdit()
				await settle()
				if model.presetEditor != nil || model.presetEditorProblem != nil || window.attachedSheet != nil || model.presets != presetsBefore {
					failures.append(prefix + "편집 시트: 취소 뒤에도 시트나 상태가 남았습니다")
					model.cancelPresetEdit()
				}
				if PresetPreviewController.shared.isVisible || PresetPreviewController.shared.isEditing {
					failures.append(prefix + "편집 시트: 닫은 뒤에도 미리보기 창이 남았습니다")
				}
				await previewCentredSteps(preset, prefix: prefix)
			}

			// Started with the frame an older version remembered (e.g. 1080×700 in the defaults), the window must still
			// open at its fixed size (FixedWindow corrects it once) and must not be resizable.
			let toolbar = window.frame.height - window.contentLayoutRect.height
			log("시작 창: \(size(base)), 콘텐츠 \(size(window.contentLayoutRect.size)), 툴바 \(Int(toolbar.rounded()))")
			log("minSize \(size(window.minSize)), maxSize \(size(window.maxSize)), contentMinSize \(size(window.contentMinSize)), contentMaxSize \(size(window.contentMaxSize)), frameAutosaveName \"\(window.frameAutosaveName)\"")
			failures += fixedProblems().map { "시작: \($0)" }

			let saved = (selected: model.selectedPresetID, status: model.status, targets: model.targets,
			             presets: model.presets, selection: model.selectedTargets,
			             home: model.applyToHomeFolders, desktop: model.includeDesktop)
			await check("시작")
			failures += toolbarProblems("시작")
			if let scroll = window.contentView.map(scrollViews)?.first {
				log("목록 스크롤 영역: 콘텐츠 여백 \(Int(scroll.contentInsets.top))/\(Int(scroll.contentInsets.bottom)), 문서 \(Int(scroll.documentView?.frame.height ?? 0)), 보이는 높이 \(Int(scroll.contentView.bounds.height)), 위치 \(Int(scroll.contentView.bounds.minY))")
			}

			model.selectedPresetID = nil
			await check("프리셋 선택 해제")
			model.selectedPresetID = saved.selected

			model.isWorking = true
			await check("진행 표시")
			model.isWorking = false

			model.applyToHomeFolders = true
			model.includeDesktop = true
			await check("데스크탑 포함 경고")
			model.applyToHomeFolders = false
			await check("홈 폴더 끔")
			model.applyToHomeFolders = saved.home
			model.includeDesktop = saved.desktop

			// Long texts in the app's language (the model's own sentences), so an English run measures English.
			model.status = String(repeating: AppModel.staleNote + " · " + AppModel.tooWideNote(["~/Projects", "~/Photos"]) + " ", count: 12)
			await check("긴 상태 문구")
			model.status = saved.status

			let longName = String(repeating: "아주 긴 폴더 이름 ", count: 12)
			let knownID = saved.presets.first?.id
			model.targets = (1...40).map { i in
				TargetFolder(path: "/finder-presets-layout-probe/\(i % 4 == 0 ? longName : "folder")-\(i)",
				             presetID: i % 5 == 0 ? UUID() : (i % 3 == 0 ? knownID : nil))
			}
			await check("폴더 40개")
			model.selectedTargets = Set(model.targets.map(\.path))
			await check("폴더 40개 선택")
			model.selectedTargets = saved.selection
			model.targets = []
			await check("폴더 없음")
			// Exactly seven folders fit without scrolling, also with a row that follows its parent's preset, a row whose
			// preset is missing and a row with a warning icon (every row has two lines).
			let parent = TargetFolder(path: "/finder-presets-layout-probe/Photos", presetID: knownID)
			let child = TargetFolder(path: "/finder-presets-layout-probe/Photos/2026")
			model.targets = [parent, child, TargetFolder(path: "/finder-presets-layout-probe/missing", presetID: UUID()),
			                 TargetFolder(path: "/Volumes/finder-presets-layout-probe/Assets"), TargetFolder(path: "/finder-presets-layout-probe/Projects"),
			                 TargetFolder(path: "/finder-presets-layout-probe/Downloads"), TargetFolder(path: "/finder-presets-layout-probe/\(longName)")]
			await check("폴더 7개(상속·프리셋 없음·경고 행)")
			if model.inheritedAssignment(for: child) == nil { failures.append("폴더 7개: 상속 행을 만들지 못했습니다(데이터 폴더에 프리셋이 없음)") }
			if let problem = fitProblem(list: 1) { failures.append("폴더 7개: \(problem)") }
			// Folders are added at the end (addFolders appends): on a long list the new row is scrolled into view.
			model.targets = (1...12).map { TargetFolder(path: "/finder-presets-layout-probe/long-\($0)") }
			await check("폴더 12개")
			model.targets.append(TargetFolder(path: "/finder-presets-layout-probe/추가한 폴더"))
			await check("긴 폴더 목록 끝에 폴더 추가")
			if let problem = rowProblem(list: 1, row: model.targets.count - 1) { failures.append("긴 폴더 목록 끝에 폴더 추가: \(problem)") }
			model.targets = saved.targets

			model.presets = (1...30).map { i in
				Preset(name: i % 4 == 0 ? String(repeating: "긴 프리셋 이름 ", count: 10) + "\(i)" : "probe \(i)",
				       settings: ViewSettings(viewStyle: ([.icon, .list, .column, .gallery, nil] as [ViewStyle?])[i % 5],
				                              icon: IconViewSettings(iconSize: Double(16 + i * 4), textSize: 12)))
			}
			model.selectedPresetID = model.presets.first?.id
			await check("프리셋 30개")
			model.selectedPresetID = model.presets.first { $0.name.count > 40 }?.id
			await check("긴 프리셋 이름 선택")
			model.presets = []
			model.selectedPresetID = nil
			await check("프리셋 없음")
			model.presets = (1...5).map { i in
				Preset(name: "fit \(i)", settings: ViewSettings(viewStyle: ([.icon, .list, .column, .gallery, nil] as [ViewStyle?])[i - 1],
				                                               icon: IconViewSettings(iconSize: 64)))
			}
			model.selectedPresetID = model.presets.first?.id
			await check("프리셋 5개")
			if let problem = fitProblem(list: 0) { failures.append("프리셋 5개: \(problem)") }
			// A number far beyond what Finder offers (a hand-written or imported preset file) and a preset that sets only
			// list options: the rows, the summary box and the tooltips show them without stopping the app, and the list-only
			// preset does not read as one that changes nothing.
			let huge = Preset(name: "huge", settings: ViewSettings(icon: IconViewSettings(iconSize: 1e19, textSize: -1e300, gridSpacing: 1e19),
			                                                       list: ListViewSettings(textSize: 1e19, iconSize: 1e19)))
			let listOnly = Preset(name: "list only", settings: ViewSettings(list: ListViewSettings(textSize: 14, useRelativeDates: false)))
			model.presets = [huge, listOnly]
			model.selectedPresetID = huge.id
			await check("큰 값의 프리셋")
			model.selectedPresetID = listOnly.id
			await check("목록 옵션만 있는 프리셋")
			if !PresetRow.summary(listOnly.settings).contains(String(localized: "옵션 \(2)개")) {
				failures.append("목록 옵션만 있는 프리셋: 요약이 옵션을 알리지 않습니다: \(PresetRow.summary(listOnly.settings))")
			}
			model.presets = saved.presets
			model.selectedPresetID = saved.selected
			await settle()

			// A new preset that sorts first, added and selected in one go, the way importPreset / importPresetFiles do it
			// (reload, then select): a list whose rows still fit stays at its top.
			let firstNew = Preset(name: "가나다 프리셋", settings: ViewSettings(viewStyle: .icon))
			model.presets = [firstNew] + saved.presets
			model.selectedPresetID = firstNew.id
			await check("맨 앞에 프리셋 추가·선택")
			let secondNew = Preset(name: "가 프리셋", settings: ViewSettings(viewStyle: .list))
			model.presets = [secondNew, firstNew] + saved.presets
			model.selectedPresetID = secondNew.id
			await check("맨 앞에 프리셋 하나 더")
			// A long list: the new preset, selected somewhere below the visible rows, is scrolled into view.
			var many = (1...20).map { Preset(name: String(format: "probe %02d", $0), settings: ViewSettings(viewStyle: .icon)) }
			model.presets = many
			model.selectedPresetID = many.first?.id
			await settle()
			let lateNew = Preset(name: "probe 17a", settings: ViewSettings(viewStyle: .column))
			many.insert(lateNew, at: 17)
			model.presets = many
			model.selectedPresetID = lateNew.id
			await check("긴 목록 중간에 프리셋 추가·선택")
			if let problem = selectedRowProblem() { failures.append("긴 목록 중간에 프리셋 추가·선택: \(problem)") }
			// Deleting the selected preset there selects the first one (deletePreset: reload, then the first preset),
			// which is out of view now: it is scrolled into view.
			if rowProblem(list: 0, row: 0) == nil { log("  주의: 삭제 전에 첫 행이 이미 보입니다(스크롤 확인이 약해짐)") }
			many.removeAll { $0.id == lateNew.id }
			model.presets = many
			model.selectedPresetID = many.first?.id
			await check("긴 목록에서 선택한 프리셋 삭제")
			if let problem = selectedRowProblem() { failures.append("긴 목록에서 선택한 프리셋 삭제: \(problem)") }
			model.presets = saved.presets
			model.selectedPresetID = saved.selected
			let firstFolder = TargetFolder(path: "/finder-presets-layout-probe/가나다 폴더")
			model.targets = [firstFolder] + saved.targets
			model.selectedTargets = [firstFolder.path]
			await check("맨 앞에 폴더 추가·선택")
			model.targets = saved.targets
			model.selectedTargets = saved.selection

			// As long as before in characters (840, one paragraph), whatever the language: an alert grows with its text.
			var longError = ""
			while longError.count < 840 { longError += AppModel.staleNote + " " }
			model.errorMessage = String(longError.prefix(840))
			await check("오류 창", sheet: true)
			await pressAlertButton(String(localized: "확인")) { model.errorMessage = nil }

			// The delete confirmation, closed with "취소" (confirmDeletePreset is never called).
			if let first = model.presets.first {
				model.requestDeletePreset(first.id)
				await check("프리셋 삭제 확인 창", sheet: true)
				await pressAlertButton(String(localized: "취소")) { model.pendingPresetDelete = nil }
				if model.pendingPresetDelete != nil || model.presets.count != saved.presets.count {
					failures.append("프리셋 삭제 확인 창: 취소 뒤에도 상태가 남았습니다")
					model.pendingPresetDelete = nil
				}
			}

			model.showHelp = true          // never dismissHelp(): it writes helpSheetDismissed
			frames = frames.filter { !$0.key.hasPrefix("help") }
			await check("사용법 시트", sheet: true, sheetSize: HelpSheet.size)
			// ①–⑧ and the folded developer section fit the sheet without scrolling, above the fade (in the language of this run).
			if let steps = frames["helpSteps"], let scroll = frames["helpScroll"] {
				log("  사용법: 단계 \(Int(steps.height.rounded()))pt + 흐림 \(Int(HelpSheet.fade)), 스크롤 칸 \(Int(scroll.height.rounded()))pt")
				if steps.height + HelpSheet.fade > scroll.height + 0.5 {
					failures.append("사용법 시트: 단계가 스크롤 칸에 다 들어가지 않습니다 (단계 \(Int(steps.height.rounded())) + 흐림 \(Int(HelpSheet.fade)) > 칸 \(Int(scroll.height.rounded())))")
				}
			} else {
				failures.append("사용법 시트: 단계·스크롤 칸의 프레임이 기록되지 않았습니다")
			}
			model.showHelp = false
			await settle()

			// The real confirmation dialog: planning only reads the folders listed in the isolated data folder.
			if !model.targets.isEmpty && model.canApply(to: model.targets.map(\.path)) {
				model.prepareApply(to: model.targets.map(\.url))
				for _ in 0..<100 where model.isWorking { await settle(100) }
				let shown = model.pendingApply != nil
				await check("적용 확인 창" + (shown ? "" : "(바뀔 것 없음)"), sheet: shown)
				if shown { await pressAlertButton(String(localized: "취소")) { model.pendingApply = nil } }
			}
			model.status = saved.status

			if let first = model.presets.first {
				model.pendingGlobalApply = GlobalApplyPlan(preset: first, roots: [URL(fileURLWithPath: "/finder-presets-layout-probe/Documents")],
				                                           plan: nil, globalDiffs: [], stamp: model.planStamp)
				await check("시스템 전체 확인 시트", sheet: true)
				// The longest message: Finder's defaults change, a long name, a grouping note and a three-digit count of
				// folders whose icon positions are reset. It must be read without scrolling its area.
				let long = Preset(name: String(repeating: "긴 프리셋 이름 ", count: 5),
				                  settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 164, arrangeBy: .grid), groupBy: .kind))
				let resets = (0..<120).map {
					PlanEntry(folder: URL(fileURLWithPath: "/finder-presets-layout-probe/f\($0)"), depth: 1, location: nil, category: .willChange,
					          reason: nil, target: long.settings, presetID: long.id, ruleSource: .defaultPreset, diffs: [], resetsIconPositions: true)
				}
				model.pendingGlobalApply = GlobalApplyPlan(preset: long, roots: [URL(fileURLWithPath: "/finder-presets-layout-probe/Documents")],
				                                           plan: Plan(roots: [], entries: resets),
				                                           globalDiffs: ViewSettings().differences(to: long.settings.globalDefaultsPart), stamp: model.planStamp)
				await check("시스템 전체 확인 시트: 가장 긴 글", sheet: true)
				if let text = frames["globalMessage"], let area = frames["globalMessageArea"] {
					if text.height > area.height + 0.5 {
						failures.append("시스템 전체 확인 시트: 글이 칸을 넘어 스크롤됩니다 (글 \(Int(text.height))pt > 칸 \(Int(area.height))pt)")
					}
					log("  시스템 전체 확인 시트: 가장 긴 글 \(Int(text.height))pt, 칸 \(Int(area.height))pt")
				} else {
					failures.append("시스템 전체 확인 시트: 글의 프레임이 기록되지 않았습니다")
				}
				model.pendingGlobalApply = nil
				await settle()
			}

			// The preset editor ("편집…", "새 프리셋…"): one fixed size whatever it shows, every option inside it without a
			// scroll area, the window unchanged. Opened in memory only (beginEditPreset, beginNewPreset and replacing the
			// draft never write) and closed with cancelPresetEdit — "저장" is never pressed.
			if let first = model.presets.first {
				await editorSteps(first, prefix: "")
			}

			// The status line's "되돌리기…" right after an apply, next to a long line's details button: inside the status bar,
			// nothing overlaps, nothing moves.
			model.status = String(repeating: String(localized: "완료: \(12)개 폴더 변경") + " · " + AppModel.staleNote + " ", count: 8)
			model.offerUndo(UUID())
			await check("상태줄 되돌리기 바로가기")
			if model.undoShortcutID == nil { failures.append("상태줄 되돌리기 바로가기: 표시되지 않습니다") }
			if let undo = frames["statusUndo"], let bar = frames["statusBar"] {
				if !bar.insetBy(dx: -0.5, dy: -0.5).contains(undo) { failures.append("상태줄 되돌리기 바로가기가 상태줄 밖입니다: \(rect(undo))") }
				if undo.maxX > bar.maxX - UILayout.edge + 0.5 { failures.append("상태줄 되돌리기 바로가기가 오른쪽 여백을 넘습니다") }
				if let details = frames["statusDetails"], details.maxX > undo.minX + 0.5 {
					failures.append("상태줄: 말풍선 버튼과 되돌리기 바로가기가 겹칩니다 (\(rect(details)), \(rect(undo)))")
				}
				log("  되돌리기 바로가기 \(rect(undo)), 상태줄 \(rect(bar))")
			} else {
				failures.append("상태줄 되돌리기 바로가기: 프레임이 기록되지 않았습니다")
			}
			model.recentOperation = nil
			model.status = saved.status

			// "기록": the data folder's real records (the data folder must hold some; reading only), then in memory a long list
			// with long names, the undo confirmations (folders with many conflicts, Finder's defaults), the running state,
			// a result with many skipped folders and the restart question on top. The sheet keeps its size, the window too.
			model.openHistory()
			for _ in 0..<50 where model.historyLoading || model.historyItems.isEmpty { await settle(100) }
			await check("기록 시트", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			failures += historyProblems("기록 시트")
			if model.historyItems.isEmpty { failures.append("기록 시트: 데이터 폴더의 기록을 읽지 못했습니다") }
			log("  기록 \(model.historyItems.count)개: \(model.historyItems.map { "\($0.kind.rawValue)/\(HistoryText.badge($0)?.text ?? "-")" }.joined(separator: ", "))")
			let now = Date()
			var fake: [FinderPresetsOperation] = []
			for i in 0..<30 {
				let kind: OperationKind = [.apply, .undo, .applyGlobal, .undoGlobal][i % 4]
				let entries = kind.isGlobal ? [] : (0..<(1 + i % 7)).map {
					OperationEntry(folderPath: "/finder-presets-layout-probe/\(longName)/f\($0)", storePath: "/finder-presets-layout-probe/.DS_Store", key: "f\($0)",
					               before: nil, after: ManagedRecordSet(), status: .changed)
				}
				let started = now.addingTimeInterval(Double(-i) * 3600)
				fake.append(FinderPresetsOperation(kind: kind, startedAt: started, finishedAt: i == 4 ? nil : started.addingTimeInterval(2),
				                         presetName: i % 5 == 0 ? String(repeating: "긴 프리셋 이름 ", count: 8) : "probe \(i)",
				                         roots: kind.isGlobal ? [] : (0..<(1 + i % 4)).map { "/finder-presets-layout-probe/\(i % 2 == 0 ? longName : "root")-\($0)" },
				                         entries: entries, undoOfOperationID: kind.isUndo ? fake.last?.id : nil, pinned: i % 6 == 0,
				                         globalSnapshotFile: kind.isGlobal ? OperationStore.globalSnapshotFileName : nil))
			}
			// A record left behind (no finishedAt, started two days ago, so it is not in progress either): the badge
			// "미완료" and the state sentence of a leftover.
			fake.append(FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-2 * 86400), presetName: "probe leftover",
			                         roots: ["/finder-presets-layout-probe/\(longName)/leftover"],
			                         entries: [OperationEntry(folderPath: "/finder-presets-layout-probe/leftover/f0", storePath: "/finder-presets-layout-probe/.DS_Store",
			                                                  key: "f0", before: nil, after: ManagedRecordSet(), status: .changed)]))
			// A record left behind that has nothing to undo either (it only skipped folders): the longest state line, both
			// sentences of it ("중간에 멈춘 작업입니다." and the reason).
			fake.append(FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-4 * 86400), presetName: "probe leftover nothing",
			                         roots: ["/finder-presets-layout-probe/\(longName)/leftover-nothing"],
			                         entries: [OperationEntry(folderPath: "/finder-presets-layout-probe/leftover-nothing/f0",
			                                                  storePath: "/finder-presets-layout-probe/.DS_Store", key: "f0",
			                                                  before: nil, after: nil, status: .skippedMatching)]))
			// The usual row: a finished folder apply of many folders that can be undone now, pinned.
			fake.append(FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-30), finishedAt: now.addingTimeInterval(-28),
			                         presetName: "probe undoable", roots: ["/finder-presets-layout-probe/\(longName)/undoable", "/finder-presets-layout-probe/root-9"],
			                         entries: (0..<478).map {
				OperationEntry(folderPath: "/finder-presets-layout-probe/undoable/f\($0)", storePath: "/finder-presets-layout-probe/.DS_Store", key: "f\($0)",
				               before: nil, after: ManagedRecordSet(), status: .changed)
			}, pinned: true))
			// An apply that changed no folder but skipped some and failed on one: "변경 없음", its own title and the line
			// that counts what it skipped and could not write.
			let nothingStart = now.addingTimeInterval(-3 * 86400)
			fake.append(FinderPresetsOperation(kind: .apply, startedAt: nothingStart, finishedAt: nothingStart.addingTimeInterval(2),
			                         presetName: String(repeating: "긴 프리셋 이름 ", count: 4), roots: ["/finder-presets-layout-probe/\(longName)/nothing"],
			                         entries: (0..<12).map {
				OperationEntry(folderPath: "/finder-presets-layout-probe/nothing/f\($0)", storePath: "/finder-presets-layout-probe/.DS_Store", key: "f\($0)",
				               before: nil, after: nil, status: $0 < 11 ? .skippedMatching : .failed)
			}))
			let fakeHistory = OperationHistory(fake)
			model.historyItems = fakeHistory.overviews
			model.historyPairs = AppModel.systemPairs(fakeHistory.operations)
			model.historyUnreadable = ["00000000-0000-0000-0000-000000000000: probe"]
			model.historySelection = model.historyItems.first { ($0.presetName?.count ?? 0) > 40 && !$0.isGlobal }?.id
			model.historyNotice = String(repeating: UndoRefusal.changed.message + " ", count: 6)
			await check("기록 시트: 긴 목록·긴 이름·알림", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			failures += historyProblems("기록 시트: 긴 목록·긴 이름·알림")
			model.historyNotice = nil
			// Every state the details word: an operation that can be undone, one already undone (with the paired
			// system-wide note), one with nothing to undo, an unfinished one, one still being written and an undo record.
			// The sentences and the state line must fit the pane in Korean and in English.
			let states: [(String, (OperationOverview) -> Bool)] = [
				("되돌릴 수 있는 폴더 작업", { !$0.isGlobal && !$0.isUndo && $0.canUndo && $0.isFinished }),
				("되돌린 작업", { !$0.isUndo && $0.status != .undoable && $0.isFinished && !$0.isGlobal }),
				("Finder 기본 보기 작업", { $0.kind == .applyGlobal }),
				("되돌릴 것 없는 작업", { $0.status == .nothingToUndo && $0.isFinished }),
				("되돌리기 기록", { $0.isUndo }),
				("진행 중인 작업", { $0.inProgress }),
				("미완료 작업", { !$0.isFinished && !$0.inProgress && $0.status == .undoable }),
				("미완료·되돌릴 것 없는 작업", { !$0.isFinished && !$0.inProgress && $0.status == .nothingToUndo })
			]
			// What the pane reads from the selected record's manifest (`AppModel.loadHistoryDetails`): the preset it applied
			// and the folders it changed. The probe's records live in memory only, so their details are set here — the
			// pane's own read finds nothing and leaves them alone.
			@MainActor func probeDetails(_ o: OperationOverview, preset: ViewSettings?, roots: Int = 3, changed: Int = 14) -> HistoryDetails {
				let rootPaths = (0..<max(1, roots)).map { "/finder-presets-layout-probe/\(longName)/root-\($0)" }
				func entry(_ path: String, _ status: EntryStatus) -> OperationEntry {
					OperationEntry(folderPath: path, storePath: "/finder-presets-layout-probe/.DS_Store", key: (path as NSString).lastPathComponent,
					               before: nil, after: ManagedRecordSet(), status: status)
				}
				let entries = (0..<changed).map { entry("\(rootPaths[$0 % rootPaths.count])/\(longName)-\($0)", .changed) }
				return HistoryDetails(FinderPresetsOperation(id: o.id, kind: o.kind, presetName: o.presetName, presetSnapshot: preset,
				                                   roots: o.isGlobal ? [] : rootPaths,
				                                   entries: o.isGlobal ? [] : entries + [entry("/finder-presets-layout-probe/skipped", .skippedMatching),
				                                                                         entry("/finder-presets-layout-probe/failed", .failed)]))
			}
			// The preset a record applied, drawn in the pane: the largest icon view (grouped, item info, two-line labels)
			// and a list view, the two that fill the picture most.
			let probePresets: [(String, ViewSettings)] = [
				("아이콘 프리셋", ViewSettings(viewStyle: .icon,
				                          icon: IconViewSettings(iconSize: 512, textSize: 16, labelOnBottom: true, showItemInfo: true,
				                                                 arrangeBy: .dateModified, gridSpacing: 100),
				                          groupBy: .kind)),
				("목록 프리셋", ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 16, iconSize: 32, sortColumn: .dateLastOpened,
				                                                                sortAscending: false, calculateAllSizes: true)))
			]
			for (name, matches) in states {
				guard let item = model.historyItems.first(where: matches) else {
					failures.append("기록 시트: \(name)을 목록에서 찾지 못했습니다")
					continue
				}
				model.historySelection = item.id
				let step = "기록 시트: \(name) 선택"
				await settle()
				// A record that applied one preset draws it; an undo record (and one whose preset was not recorded) says so.
				model.historyDetails = probeDetails(item, preset: item.isUndo ? nil : probePresets[0].1)
				await check(step, sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				failures += historyProblems(step)
				// The sentence the pane shows: with the time of the undo that undid it, like HistoryDetail computes it.
				var undoneAt: Date?
				if case .undone(let by) = item.status { undoneAt = model.historyItems.first { $0.id == by }?.startedAt }
				log("  \(step): \"\(HistoryText.title(item))\" · \(HistoryText.summarySentence(item)) · \(HistoryText.stateSentence(item, undoneAt: undoneAt).text)"
					+ (HistoryText.countsLine(item).map { " · " + $0 } ?? ""))
			}
			// The pane's middle row: each preset drawn as a picture beside a folder list with several roots and "외 N개",
			// then the same record without a recorded preset (the line that replaces the picture).
			if let item = model.historyItems.first(where: { !$0.isGlobal && !$0.isUndo && $0.canUndo && $0.isFinished }) {
				model.historySelection = item.id
				await settle()
				for (name, preset) in probePresets {
					let step = "기록 시트: \(name) 미리보기"
					model.historyDetails = probeDetails(item, preset: preset)
					await check(step, sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
					failures += historyProblems(step)
					if let folders = model.historyDetails?.folders {
						log("  \(step): \(HistoryText.foldersTitle(item, count: folders.total)) · 표시 \(folders.shown.count)개 · \(HistoryText.moreFolders(folders.hidden) ?? "-")"
							+ " · " + folders.shown.prefix(3).map { HistoryText.folderRow($0.path, under: $0.root).place }.map { $0.isEmpty ? "(뿌리 안)" : $0 }.joined(separator: ", "))
						// The words under the picture, which the picture itself is too small to show.
						let drawn = PresetPreview.make(settings: preset, defaults: model.previewDefaults, locale: AppLanguage.locale, now: Date())
						log("  \(step): \(drawn.footerLeading) · \(drawn.scaleBadge ?? "-")")
					}
				}
				let step = "기록 시트: 프리셋 없는 기록"
				model.historyDetails = probeDetails(item, preset: nil, roots: 1, changed: 1)
				await check(step, sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				failures += historyProblems(step)
				log("  \(step): \(HistoryText.noPreview(item))")
				// Still reading the manifest: the box stays empty and nothing else moves.
				model.historyDetails = nil
				await check("기록 시트: 자세한 내용 읽는 중", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				failures += historyProblems("기록 시트: 자세한 내용 읽는 중")
				// The manifest could not be read at all: the box says so instead of staying as empty as while it is read.
				model.historyDetailsUnreadable = item.id
				await check("기록 시트: 자세한 내용을 읽지 못함", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				failures += historyProblems("기록 시트: 자세한 내용을 읽지 못함")
				log("  기록 시트: 자세한 내용을 읽지 못함: \(HistoryText.detailsUnreadable)")
				model.historyDetailsUnreadable = nil
			}
			// Several records chosen (⇧/⌘-click): the pane says how many and offers only "지우기…", inside the pane.
			model.historySelected = Set(model.historyItems.prefix(3).map(\.id))
			await check("기록 시트: 여러 개 선택", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			if let well = frames["historyDetailWell"], let chosen = frames["historyChosen"] {
				if !well.insetBy(dx: -0.5, dy: -0.5).contains(chosen) {
					failures.append("기록 시트: 여러 개 선택: 내용이 오른쪽 칸을 넘칩니다: \(rect(chosen)), 칸 \(rect(well))")
				}
				log("  기록 시트: 여러 개 선택: \(HistoryText.chosenTitle(model.historySelected.count)), 칸 \(rect(well)), 내용 \(rect(chosen))")
			} else {
				failures.append("기록 시트: 여러 개 선택: 오른쪽 칸의 프레임이 기록되지 않았습니다")
			}
			// "지우기…" asks first, on top of the sheet; the probe answers "취소" only (it never deletes anything).
			model.pendingHistoryDelete = HistoryDeletion.chosen(model.historySelected, in: model.historyItems)
			await check("기록 시트: 지우기 확인", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			if window.attachedSheet?.attachedSheet == nil { failures.append("기록 시트: 지우기 확인이 시트 위에 뜨지 않았습니다") }
			await pressAlertButton(String(localized: "취소"), nested: true) { model.pendingHistoryDelete = nil }
			if model.pendingHistoryDelete != nil {
				failures.append("기록 시트: \"취소\" 뒤에도 지우기 확인이 남았습니다")
				model.pendingHistoryDelete = nil
			}
			model.historySelection = model.historyItems.first?.id
			if let folderOp = fake.first(where: { $0.kind == .apply }), let globalOp = fake.first(where: { $0.kind == .applyGlobal }) {
				let paths = { (tag: String, n: Int) in (1...n).map { "/finder-presets-layout-probe/\(longName)/\(tag)-\($0)" } }
				let folderUndo = PendingUndo(operation: folderOp, overview: fakeHistory.overview(of: folderOp), restorable: paths("r", 40),
				                             conflicts: paths("c", 200), alreadyRestored: paths("a", 5), related: fakeHistory.overview(of: globalOp))
				model.undoPhase = .confirm(folderUndo)
				await check("되돌리기 확인(충돌 200개)", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				let wide = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 128, arrangeBy: .dateLastOpened),
				                        list: ListViewSettings(sortColumn: .dateLastOpened))
				model.undoPhase = .confirm(PendingUndo(operation: globalOp, overview: fakeHistory.overview(of: globalOp),
				                                       global: .init(current: wide, restored: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64)),
				                                                     recordedAt: now, alreadyRestored: false),
				                                       related: fakeHistory.overview(of: folderOp)))
				await check("Finder 기본 보기 되돌리기 확인", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				model.undoPhase = .running(folderUndo)
				await check("되돌리는 중", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				model.undoPhase = .result(UndoOutcome(operationID: folderOp.id, isGlobal: false, undoOperationID: UUID(), restored: paths("r", 40),
				                                      conflicts: paths("c", 200), alreadyRestored: paths("a", 5), failed: paths("f", 30)))
				await check("되돌리기 결과", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				// The restart question on top of the sheet, answered "나중에" (never "지금 다시 시작").
				model.askRelaunchAfterUndo = true
				await check("되돌리기 결과: Finder 다시 시작 질문", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
				if window.attachedSheet?.attachedSheet == nil { failures.append("기록 시트: \"Finder를 다시 시작할까요?\"가 시트 위에 뜨지 않았습니다") }
				await pressAlertButton(String(localized: "나중에"), nested: true) { model.askRelaunchAfterUndo = false }
				if model.askRelaunchAfterUndo { failures.append("기록 시트: \"나중에\" 뒤에도 질문이 남았습니다"); model.askRelaunchAfterUndo = false }
				model.undoPhase = .result(UndoOutcome(operationID: globalOp.id, isGlobal: true, finderRelaunched: false,
				                                      error: String(repeating: ErrorText.describe(GlobalApplyError.finderDidNotQuit) + " ", count: 4)))
				await check("Finder 기본 보기 되돌리기 결과(오류)", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			}
			model.historyItems = []
			model.historyUnreadable = []
			model.undoPhase = .idle
			await check("기록 시트: 기록 없음", sheet: true, sheetSize: HistorySheet.size, largerThanWindow: true)
			model.closeHistory()
			await settle()

			/// Every AppKit button under `view` (SwiftUI's push buttons, check boxes and radio buttons are `NSButton`s).
			@MainActor func buttons(in view: NSView) -> [NSButton] {
				((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
			}

			/// The walkthrough sheet ("단축키 설정 방법", Views/ShortcutGuideSheet.swift) on the Settings window, step by step
			/// (`steps`, all six of them by default — ① carries the button that opens System Settings, which is never
			/// pressed, and ⑥ shows the state of this run): one fixed size, no scroll area, and its parts — the heading,
			/// the drawing, the step's words, the step's own row, the dots and the bottom row — lie inside it one below the
			/// other. Two things the frames alone would not show are measured as well: the step's sentence never needs more
			/// than the height it is given (a longer text would be cut with an ellipsis, not overlap), and a step's drawing
			/// never grows past the box it was given. The sheet is opened through `ShortcutGuide` on the step it checks, the
			/// way "설정 방법 보기…" opens it, and must still stand on that step once everything is measured: it never moves by
			/// itself (only "이전"·"다음" and ← → change the step). The sheet's own buttons are read too: "이전" is disabled on
			/// the first step and only there, "다음" on the last and only there, and "닫기" is always enabled — the visible
			/// buttons and the hidden copies that carry ← → and Esc share those titles and states, so every button with the
			/// title is checked, and one of each must be there. Nothing is pressed, nothing is written and no other app is opened.
			@MainActor func guideSteps(_ step: String, on settings: NSWindow, steps: [Int]? = nil) async {
				let last = ShortcutGuideSheet.steps.count - 1
				let wanted = steps ?? Array(0...last)
				for index in wanted {
					let name = ShortcutGuideSheet.marks[min(index, last)] + " 단계"   // l10n-exempt: the probe's own log
					frames = frames.filter { !$0.key.hasPrefix("guide") }
					ShortcutGuide.shared.open(at: index)
					await settle()
					guard let sheet = settings.attachedSheet, let content = sheet.contentView else {
						failures.append("\(step) 단축키 안내 \(name): 시트가 열리지 않았습니다")
						ShortcutGuide.shared.close()
						await settle()
						continue
					}
					var problems: [String] = []
					let expected = ShortcutGuideSheet.size
					if abs(sheet.frame.width - expected.width) > 0.5 || abs(sheet.frame.height - expected.height) > 0.5 {
						problems.append("시트가 고정 크기 \(size(expected))가 아닙니다: \(size(sheet.frame.size))")
					}
					let visible = settings.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
					if sheet.frame.width > visible.width - 40 || sheet.frame.height > visible.height - 40 {
						problems.append("시트 \(size(sheet.frame.size))가 화면 \(size(visible.size))에 들어가지 않습니다")
					}
					let scrolls = scrollViews(in: content)
					if !scrolls.isEmpty { problems.append("스크롤 영역이 \(scrolls.count)개 있습니다") }
					if ShortcutGuide.shared.step != index { problems.append("단계가 \(index)가 아닙니다: \(ShortcutGuide.shared.step)") }
					// The parts, in the sheet's own coordinates (`guideRoot` is its whole content).
					let order = ["guideHeader", "guideDrawing", "guideText", "guideAction", "guideDots", "guideBottom"]
					var parts: [String: CGRect] = [:]
					for id in ["guideRoot"] + order {
						guard let r = frames[id] else { problems.append("\(id): 프레임이 기록되지 않았습니다"); continue }
						parts[id] = r
						log("  \(step) 단축키 안내 \(name): \(id) \(rect(r))")
					}
					if let root = parts["guideRoot"] {
						if abs(root.width - expected.width) > 0.5 || abs(root.height - expected.height) > 0.5 {
							problems.append("시트 내용이 \(size(expected))이 아닙니다: \(rect(root))")
						}
						let inside = root.insetBy(dx: -0.5, dy: -0.5)
						for id in order where parts[id] != nil && !inside.contains(parts[id]!) {
							problems.append("\(id) \(rect(parts[id]!))가 시트 밖입니다")
						}
					}
					for (above, below) in zip(order, order.dropFirst()) {
						guard let a = parts[above], let b = parts[below] else { continue }
						if a.maxY > b.minY + 0.5 { problems.append("\(above)와 \(below)가 겹칩니다 (\(rect(a)), \(rect(b)))") }
					}
					// The two measurements that are not part of the order above must be there as well.
					for id in ["guideTextIdeal", "guideDrawingContent"] where frames[id] == nil {
						problems.append("\(id): 프레임이 기록되지 않았습니다")
					}
					// The sentence's own height (a hidden copy at the same width): more than its slot means the step's
					// last words are cut off with an ellipsis, which no frame would show.
					if let ideal = frames["guideTextIdeal"], ideal.height > ShortcutGuideSheet.textHeight + 0.5 {
						problems.append("단계 글이 잘립니다 (필요 \(Int(ideal.height.rounded(.up)))pt, 자리 \(Int(ShortcutGuideSheet.textHeight))pt)")
					}
					// The drawing's content against the box it was given: a drawing that grows past it would cross the
					// drawn card's bottom stroke.
					// (`GuidePanel` keeps 10pt between its content and the card's edge.)
					if let drawing = parts["guideDrawing"], let inner = frames["guideDrawingContent"], inner.maxY > drawing.maxY - 9.5 {
						problems.append("그림이 상자를 넘칩니다 (내용 \(rect(inner)), 상자 \(rect(drawing)))")
					}
					// "이전" off on the first step, "다음" off on the last, "닫기" always on: the buttons are wired to the step.
					// SwiftUI's push buttons are NSButtons with an empty `title` and no identifier (SwiftUI draws the label and
					// keeps the accessibility identifier on its own element), so the visible ones are read by place: the
					// buttons drawn inside the bottom row, left to right, are "이전", "다음" and "닫기". The hidden ← → and
					// Esc copies have no size and are left out.
					let sheetButtons = buttons(in: content)
					func placed(_ b: NSButton) -> CGRect {
						let r = b.convert(b.bounds, to: content)
						return CGRect(x: r.minX, y: content.isFlipped ? r.minY : content.bounds.height - r.maxY, width: r.width, height: r.height)
					}
					let row = parts["guideBottom"] ?? .zero
					let rowButtons = sheetButtons.filter { b in
						let r = placed(b)
						return r.width > 1 && r.height > 1 && r.midY >= row.minY - 1 && r.midY <= row.maxY + 1
					}.sorted { placed($0).minX < placed($1).minX }
					log("  \(step) 단축키 안내 \(name): 아래 줄 버튼 "
						+ rowButtons.map { "x\(Int(placed($0).minX))\($0.isEnabled ? "" : "(꺼짐)")" }.joined(separator: ", "))
					let enabledWanted = [(String(localized: "이전"), index != 0), (String(localized: "다음"), index != last),
					                     (String(localized: "닫기"), true)]
					if rowButtons.count != enabledWanted.count {
						problems.append("아래 줄 버튼이 \(rowButtons.count)개입니다 (이전·다음·닫기 3개여야 함)")
					}
					for ((title, enabled), button) in zip(enabledWanted, rowButtons) where button.isEnabled != enabled {
						problems.append("\"\(title)\" 버튼이 \(enabled ? "꺼져" : "켜져") 있습니다")
					}
					log("  \(step) 단축키 안내 \(name): 시트 \(size(sheet.frame.size)), 글 \(Int(frames["guideTextIdeal"]?.height ?? 0))pt, "
						+ "그림 내용 \(Int(frames["guideDrawingContent"]?.height ?? 0))pt, 상태 \(ShortcutGuide.shared.shortcut)")
					// Still the step it was opened on, after the settling and the measuring above: nothing advances it.
					if ShortcutGuide.shared.step != index || !ShortcutGuide.shared.isOpen {
						problems.append("단계가 저절로 바뀌었거나 시트가 닫혔습니다: \(ShortcutGuide.shared.step)")
					}
					failures += problems.map { "\(step): 단축키 안내 \(name): \($0)" }
					ShortcutGuide.shared.close()
					await settle()
					if settings.attachedSheet != nil { failures.append("\(step): 단축키 안내 \(name): 시트가 닫히지 않았습니다") }
				}
				// The Settings window is unchanged by the sheet, and so is the main window.
				await check("\(step): 단축키 안내를 닫은 뒤")
			}

			/// App menu > "설정…" (⌘,): the Settings window (the app's language, then the quick preset) has its fixed size,
			/// cannot be resized or made full screen, has no scroll area, and its parts lie inside it one below the other, the
			/// note beside "앱 다시 시작", and under the quick preset's name the shortcut line and the two buttons; the main
			/// window is unchanged. Only opened and closed: no language is chosen (nothing is written to the defaults), and
			/// "앱 다시 시작", "키보드 단축키 열기…" and the walkthrough's "키보드 설정 열기…" are never pressed (no System
			/// Settings is opened). `quick`: the preset starred meanwhile (in memory: the probe's star store is not the
			/// defaults, `QuickPresetSetting.forThisLaunch`), nil for "없음". `shortcut`: the `NSServicesStatus` dictionary
			/// this step pretends macOS has (`ServiceShortcut.Development`, never the real `pbs` domain), nil for a service
			/// without a shortcut. `guide`: also walk through the "단축키 설정 방법" sheet.
			@MainActor func settingsSteps(_ step: String, quick: Preset? = nil, shortcut: [String: Any]? = nil,
			                              guide: [Int]? = nil) async {
				let starred = model.quickPresetID
				model.quickPresetID = quick?.id
				// Read from a dictionary in memory, so the probe never reads a domain of the system.
				ServiceShortcut.Development.shared.status = shortcut
				ShortcutGuide.shared.refresh()
				defer {
					model.quickPresetID = starred
					ServiceShortcut.Development.shared.status = nil
					ShortcutGuide.shared.refresh()
				}
				// The window keeps its view between openings (its frames were recorded the first time and stay valid).
				@MainActor func settingsWindow() -> NSWindow? {
					NSApp.windows.first { $0 !== window && $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.contentView != nil }
				}
				// The app menu's "설정…" item (⌘,), the way a user opens it.
				if let appMenu = NSApp.mainMenu?.items.first?.submenu,
				   let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
					appMenu.performActionForItem(at: index)
				} else {
					failures.append("\(step): 앱 메뉴에 \"설정…\"(⌘,)이 없습니다")
				}
				var found: NSWindow?
				for _ in 0..<30 {
					found = settingsWindow()
					if found != nil { break }
					await settle(100)
				}
				guard let settings = found, let root = settings.contentView else { failures.append("\(step): 설정 창이 열리지 않았습니다"); return }
				await settle()
				let expected = LanguageSettingsView.size
				let c = settings.contentLayoutRect.size
				log("\(step): 설정 창 \(size(settings.frame.size)), 콘텐츠 \(size(c)), \"\(settings.title)\"")
				var problems: [String] = []
				if abs(c.width - expected.width) > 0.5 || abs(c.height - expected.height) > 0.5 {
					problems.append("콘텐츠가 고정 크기 \(size(expected))가 아닙니다: \(size(c))")
				}
				if settings.styleMask.contains(.resizable) { problems.append("사용자가 창 크기를 바꿀 수 있습니다") }
				if settings.collectionBehavior.contains(.fullScreenPrimary) { problems.append("전체 화면이 가능합니다") }
				let scrolls = scrollViews(in: root)
				if !scrolls.isEmpty { problems.append("스크롤 영역이 \(scrolls.count)개 있습니다") }
				let ids = ["settingsPicker", "settingsCaption", "settingsNote", "settingsRelaunch", "settingsQuickName",
				           "settingsShortcut", "settingsShortcuts", "settingsGuideButton", "settingsQuickCaption"]
				// The recorded frames are in the window's coordinates, the title bar above the content included.
				let titleBar = settings.frame.height - c.height
				let bounds = CGRect(x: 0, y: titleBar, width: expected.width, height: expected.height).insetBy(dx: -0.5, dy: -0.5)
				var parts: [String: CGRect] = [:]
				for id in ids {
					guard let r = frames[id] else { problems.append("\(id): 프레임이 기록되지 않았습니다"); continue }
					parts[id] = r
					log("  \(id) \(rect(r))")
					if !bounds.contains(r) { problems.append("\(id) \(rect(r))가 창 밖입니다") }
				}
				if let picker = parts["settingsPicker"], let caption = parts["settingsCaption"], picker.maxY > caption.minY + 0.5 {
					problems.append("언어 선택과 설명이 겹칩니다 (\(rect(picker)), \(rect(caption)))")
				}
				if let caption = parts["settingsCaption"], let note = parts["settingsNote"], let button = parts["settingsRelaunch"] {
					if caption.maxY > min(note.minY, button.minY) + 0.5 { problems.append("설명과 아랫줄이 겹칩니다") }
					if note.maxX > button.minX + 0.5 { problems.append("안내 문구와 \"앱 다시 시작\"이 겹칩니다 (\(rect(note)), \(rect(button)))") }
				}
				if let note = parts["settingsNote"], let relaunch = parts["settingsRelaunch"], let name = parts["settingsQuickName"],
				   let line = parts["settingsShortcut"], let open = parts["settingsShortcuts"], let guideButton = parts["settingsGuideButton"],
				   let caption = parts["settingsQuickCaption"] {
					if max(note.maxY, relaunch.maxY) > min(name.minY, line.minY) + 0.5 { problems.append("언어 줄과 빠른 적용 줄이 겹칩니다") }
					if name.maxY > line.minY + 0.5 { problems.append("빠른 적용 프리셋 이름과 단축키 줄이 겹칩니다 (\(rect(name)), \(rect(line)))") }
					if line.maxY > min(open.minY, guideButton.minY) + 0.5 { problems.append("단축키 줄과 버튼 줄이 겹칩니다 (\(rect(line)), \(rect(open)))") }
					if open.maxX > guideButton.minX + 0.5 {
						problems.append("\"키보드 단축키 열기…\"와 \"설정 방법 보기…\"가 겹칩니다 (\(rect(open)), \(rect(guideButton)))")
					}
					// "없음 — …" must fit whole (a long preset name may be shortened in the middle, like in the list).
					if quick == nil, let ideal = frames["settingsQuickNameIdeal"], ideal.width > name.width + 0.5 {
						problems.append("\"없음\" 안내가 잘립니다 (필요 \(Int(ideal.width.rounded(.up)))pt, 자리 \(Int(name.width))pt)")
					}
					// The shortcut line never wraps, so only the width it wants shows that it would be cut off.
					if let ideal = frames["settingsShortcutIdeal"], ideal.width > line.width + 0.5 {
						problems.append("단축키 줄이 잘립니다 (필요 \(Int(ideal.width.rounded(.up)))pt, 자리 \(Int(line.width))pt)")
					}
					if max(open.maxY, guideButton.maxY) > caption.minY + 0.5 { problems.append("버튼 줄과 단축키 안내가 겹칩니다") }
				}
				// The radio group: one button per choice, the stored choice selected.
				let all = buttons(in: root)
				log("  설정 창 버튼: \(all.map { "\($0.title)\($0.state == .on ? "(선택)" : "")\($0.isEnabled ? "" : "(꺼짐)")" }.joined(separator: ", "))")
				log("  저장된 언어 선택: \(LanguageSetting.standard.choice.rawValue), 다시 시작 필요: \(LanguageSetting.standard.needsRelaunch(current: AppLanguage.code))")
				failures += problems.map { "\(step): 설정 창: \($0)" }
				await check("\(step): 설정 창이 열린 동안")
				if guide.map({ !$0.isEmpty }) ?? true { await guideSteps(step, on: settings, steps: guide) }
				settings.close()
				await settle()
				if settingsWindow() != nil { failures.append("\(step): 설정 창이 닫히지 않았습니다") }
			}

			// Appearance of this process only (nothing is written to the system settings or the defaults).
			let appearance = NSApp.appearance
			NSApp.appearance = NSAppearance(named: .aqua)
			await check("라이트 모드")
			failures += toolbarProblems("라이트 모드")
			// Light: no star and no shortcut, with every step of the walkthrough. Dark: a starred preset and the shortcut of
			// the machine this was written for ("@~^p" → ⌃⌥⌘P), then the same shortcut with the service switched off (the
			// longest line, and a warning) — there the walkthrough is opened on its last step, the one that shows the state.
			let lastGuideStep = ShortcutGuideSheet.steps.count - 1
			await settingsSteps("라이트 모드")
			await previewSteps("라이트 모드: ")
			NSApp.appearance = NSAppearance(named: .darkAqua)
			await check("다크 모드")
			failures += toolbarProblems("다크 모드")
			let bundleID = Bundle.main.bundleIdentifier ?? ""
			await settingsSteps("다크 모드", quick: model.presets.first,
			                    shortcut: ServiceShortcut.status(keyEquivalent: "@~^p", bundleID: bundleID),
			                    guide: [0, 4, lastGuideStep])
			await settingsSteps("다크 모드(서비스 꺼짐)", quick: model.presets.first,
			                    shortcut: ServiceShortcut.status(keyEquivalent: "@~^p", bundleID: bundleID, servicesMenu: 0),
			                    guide: [lastGuideStep])
			if let first = model.presets.first { await editorSteps(first, prefix: "다크 모드: ") }
			await previewSteps("다크 모드: ")
			NSApp.appearance = appearance

			await check("원래대로")
			await settle(800)
			log("끝 크기: \(size(window.frame.size))")
			log(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; "))
			exit(failures.isEmpty ? 0 : 1)
		}
		return true
	}
}
#endif

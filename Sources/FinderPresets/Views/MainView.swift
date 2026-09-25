import SwiftUI
import FinderPresetsCore

/// The window: the two columns, the one-line whole-system bar and the status bar. Every sheet, alert and confirmation
/// lives here, except what the history sheet asks itself (its undo confirmation and "Finder를 다시 시작할까요?").
struct MainView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	/// The preset editor's last draft, shown while its sheet closes.
	@State private var lastEditor: PresetDraft?

	#if DEBUG
	/// The self-test drives the model only and sets and clears these states within a few milliseconds. Closing an alert
	/// sheet that is still animating in, during a SwiftUI layout pass, crashes AppKit (seen on macOS 26), so while the
	/// self-test runs the dialogs are not presented at all. Nothing the self-test checks depends on them.
	private static let presentsDialogs = !SelfTest.isRequested
	#else
	private static let presentsDialogs = true
	#endif

	private func presented(_ get: @escaping () -> Bool, dismiss: @escaping () -> Void) -> Binding<Bool> {
		Binding(get: { Self.presentsDialogs && get() }, set: { if !$0 { dismiss() } })
	}

	var body: some View {
		VStack(spacing: 0) {
			Workbench()
			SystemBar()
			StatusBar()
		}
		.frame(width: UILayout.content.width, height: UILayout.content.height, alignment: .topLeading)
		.background(Theme.canvas)
		.probeFrame("root")
		// The buttons say what they are: a symbol with its name beside it, in the primary text color (icon-only toolbar
		// buttons were easy to miss). The three labels and the window title fit the fixed 720pt width in both languages
		// (checked by the layout probe, and estimated by AppHelpersTests.fixedLayoutBudget).
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button { model.openHistory() } label: {
					Label(Self.historyLabel, systemImage: "clock.arrow.circlepath")
						.foregroundStyle(.primary)
				}
				.labelStyle(.titleAndIcon)
				.help(String(localized: "작업 기록 보기 · 되돌리기"))
				.accessibilityIdentifier("history")
				Button { model.showHelp = true } label: {
					Label(Self.helpLabel, systemImage: "questionmark.circle")
						.foregroundStyle(.primary)
				}
				.labelStyle(.titleAndIcon)
				.help(String(localized: "사용법 보기"))
				.accessibilityIdentifier("help")
				// GitHub's latest release page in the browser (ReleaseLink): the app never checks for updates itself.
				Button { model.openLatestRelease() } label: {
					Label(ReleaseLink.buttonLabel, systemImage: "arrow.down.circle")
						.foregroundStyle(.primary)
				}
				.labelStyle(.titleAndIcon)
				.help(ReleaseLink.help())
				.accessibilityIdentifier("latestRelease")
			}
		}
		.sheet(isPresented: presented({ model.showHelp }, dismiss: { model.showHelp = false })) { HelpSheet() }
		.sheet(isPresented: presented({ model.showHistory }, dismiss: { model.closeHistory() })) { HistorySheet() }
		.sheet(isPresented: presented({ model.pendingGlobalApply != nil }, dismiss: { model.cancelPendingGlobalApply() })) {
			GlobalConfirmSheet()
		}
		// "편집…" / "새 프리셋…": a new identity per opening, so the sheet always starts from the draft it was opened with.
		// While the sheet closes (the model's draft is already gone) it keeps showing the last one instead of going blank.
		.sheet(isPresented: presented({ model.presetEditor != nil }, dismiss: { model.cancelPresetEdit() })) {
			if let draft = model.presetEditor ?? lastEditor { PresetEditorSheet(initial: draft).id(draft.token) }
		}
		// The editor's preview window opens and closes with the editor (Views/PresetPreviewWindow.swift): with its draft,
		// whatever closes it (save, cancel, Esc).
		.onChange(of: model.presetEditor?.token) {
			if let draft = model.presetEditor {
				lastEditor = draft
				PresetPreviewController.shared.begin(draft, globals: model.globals)
			} else {
				PresetPreviewController.shared.end()
			}
		}
		.alert("오류", isPresented: presented({ model.errorMessage != nil }, dismiss: { model.errorMessage = nil })) {
			Button("확인") { model.errorMessage = nil }
		} message: { Text(model.errorMessage ?? "") }
		// "적용" clears `pendingApply` before the dialog reports its dismissal, so the dismissal only cancels what is still pending.
		.confirmationDialog("적용할까요?", isPresented: presented({ model.pendingApply != nil }, dismiss: { model.cancelPendingApply() })) {
			Button("적용") { model.confirmApply() }
			Button("취소", role: .cancel) { model.cancelPendingApply() }
		} message: {
			if let p = model.pendingApply { Text(Self.confirmMessage(p)) }
		}
		// "삭제" clears `pendingPresetDelete` before deleting, so the dismissal that follows changes nothing.
		.confirmationDialog("프리셋을 삭제할까요?", isPresented: presented({ model.pendingPresetDelete != nil }, dismiss: { model.pendingPresetDelete = nil })) {
			Button("삭제", role: .destructive) { model.confirmDeletePreset() }
			Button("취소", role: .cancel) { model.pendingPresetDelete = nil }
		} message: {
			if let p = model.pendingPresetDelete { Text(model.deleteMessage(p)) }
		}
		.relaunchQuestion(isPresented: presented({ model.askRelaunch }, dismiss: { model.askRelaunch = false }), after: model.relaunchAfter) {
			model.relaunchFinder()
		}
		// A Finder service that arrives after the window was closed opens it again (FinderServices.swift).
		.onAppear { FinderServiceProvider.shared.openMainWindow = { [openWindow] in openWindow(id: "main") } }
	}

	/// The toolbar buttons' names, in the toolbar's order (the layout probe measures them).
	static var historyLabel: String { String(localized: "기록") }
	static var helpLabel: String { String(localized: "사용법") }
	static var toolbarLabels: [String] { [historyLabel, helpLabel, ReleaseLink.buttonLabel] }

	/// "총 15개 폴더를 바꿉니다: Pictures 3개 폴더, 목록 보기 12개 폴더. …"
	static func confirmMessage(_ p: PendingApply) -> String {
		let shown = Fmt.firstNames(p.roots.map(\.lastPathComponent), limit: 6)
		var lines = [String(localized: "총 \(p.changeCount)개 폴더를 바꿉니다: \(p.presetSummary)."), String(localized: "대상: \(shown)")]
		if !p.skipped.isEmpty { lines.append(AppModel.skippedNote(p.skipped)) }
		if !p.tooWide.isEmpty { lines.append(AppModel.tooWideNote(p.tooWide)) }
		if p.plan.iconPositionResets > 0 { lines.append(AppModel.iconPositionsNote(p.plan.iconPositionResets)) }
		lines.append(String(localized: "바뀌기 전 상태는 자동으로 백업됩니다."))
		return lines.joined(separator: "\n")
	}
}

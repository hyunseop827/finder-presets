import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderPresetsCore

/// One row of "2. 적용할 폴더". targets.json: `[{"path": …, "presetID": …}]` — `presetID` is omitted when nil, and a file
/// written before assignments existed (`[{"path": …}]`) loads with every folder on "선택한 프리셋 사용".
struct TargetFolder: Codable, Identifiable, Equatable, Hashable {
	var id: String { path }
	var path: String
	var presetID: UUID?          // nil = "선택한 프리셋 사용"
	var url: URL { URL(fileURLWithPath: path) }
	var name: String { url.lastPathComponent }
	var assignment: TargetAssignment { TargetAssignment(path: path, presetID: presetID) }
}

/// Which edits a plan was computed from. The model counts every change of the presets, the selected preset, the
/// folder list (with its assignments) and "하위 폴더 포함"; a plan whose stamp no longer matches is thrown away
/// instead of being confirmed or written, because it would ignore what the user changed while it was computed.
struct PlanStamp: Equatable {
	var presets = 0       // `presets` or `selectedPresetID` changed
	var targets = 0       // `targets` (paths, assignments) or `includeSubfolders` changed
	var homeFolders = true
	var includeDesktop = false

	/// "선택한/전체 폴더에 적용" depends on the presets, the selection, the folder list and "하위 폴더 포함".
	func sameForFolders(as other: PlanStamp) -> Bool { presets == other.presets && targets == other.targets }
	/// "시스템 전체에 적용" depends on the presets, the selection and its two checkboxes.
	func sameForSystem(as other: PlanStamp) -> Bool {
		presets == other.presets && homeFolders == other.homeFolders && includeDesktop == other.includeDesktop
	}
}

/// What "선택한/전체 폴더에 적용" will do, computed before the confirmation (nothing written yet).
struct PendingApply {
	struct PresetChange: Equatable {
		var name: String
		var count: Int
	}
	var roots: [URL]                               // requested roots that resolved to a preset
	var plan: Plan
	var skipped: [TargetBatch.SkippedRoot]         // requested roots without a preset (not scanned)
	var tooWide: [String] = []                     // requested home folder / folders above it (never scanned), abbreviated
	var presetChanges: [PresetChange]              // folders that will change, per preset, most first
	var presetName: String                         // for the operation record: the one preset, or all names
	var presetSnapshot: ViewSettings?              // only when a single preset is written
	var stamp = PlanStamp()                        // the model's edits when the plan was made
	var changeCount: Int { plan.changes.count }
	/// "Pictures 3개 폴더, 목록 보기 12개 폴더"
	var presetSummary: String { presetChanges.map { String(localized: "\(Fmt.name($0.name)) \($0.count)개 폴더") }.joined(separator: ", ") }
}

/// When "종료" (⌘Q, the Dock, logging out) may go ahead: not while a task writes `.DS_Store` files or operation records,
/// or has Finder quit (a system-wide apply, a Finder default undo, "지금 다시 시작", the quick preset) — quitting then
/// would leave Finder quit or a record unfinished. Such a quit is put off and goes ahead when the task ends.
struct QuitGuard: Equatable {
	/// A task that writes or quits Finder is running.
	private(set) var writing = false
	private(set) var quitsFinder = false
	/// "종료" came while `writing`: the app quits when the task ends.
	private(set) var quitWhenDone = false
	/// The task ended with a quit pending: the app is quitting now (no new alert is shown).
	private(set) var quitting = false
	/// A task quit Finder and Finder did not come back (its launch failed).
	private(set) var finderLeftQuit = false

	mutating func begin(quitsFinder: Bool) {
		writing = true
		quitting = false
		self.quitsFinder = quitsFinder
	}

	/// "종료": true when the app may quit now; otherwise the quit is put off until `end`.
	mutating func requestQuit() -> Bool {
		guard writing else { return true }
		quitWhenDone = true
		return false
	}

	/// The task ended (`finderRunning`: whether Finder runs now). True when a quit that was put off goes ahead now.
	mutating func end(finderRunning: Bool) -> Bool {
		guard writing else { return false }
		writing = false
		if quitsFinder { finderLeftQuit = !finderRunning }
		quitsFinder = false
		let quit = quitWhenDone
		quitWhenDone = false
		quitting = quit
		return quit
	}

	/// The quit did not happen after all (an error to read, a sheet in the way): the app goes on as usual.
	mutating func dropQuit() { quitting = false }

	/// Whether the app launches Finder when it quits: a task of this app quit it, and it is still not running.
	func relaunchOnQuit(finderRunning: Bool) -> Bool { finderLeftQuit && !finderRunning }
}

/// The "오류" alert (MainView, `AppModel.errorMessage`): its text, and whether all of it is quick-preset refusals
/// (`reportQuickRefusal`; also the quick preset's "Finder overwrote it, press the shortcut once more" notice). Such an alert does not stop the next press of the quick preset's shortcut: the press closes
/// it and goes on (`AppModel.quickApplyGate`). Anything else in it — another message, a text set directly, or a refusal
/// added after another message — makes it an alert that refuses the press (`.dialogOpen`) until it is closed, so a real
/// error is never closed unseen; closing it (nil) forgets what it held.
struct ErrorAlert: Equatable, Sendable {
	/// What the alert holds, for `AppModel.quickApplyGate`.
	enum Content: Equatable, Sendable {
		case none
		/// Only quick-preset refusal text.
		case quickRefusals
		/// Anything else (with or without refusals).
		case other
	}

	/// The text; nil when the alert is closed.
	private(set) var message: String?
	private(set) var onlyQuickRefusals = false

	var content: Content { message == nil ? .none : onlyQuickRefusals ? .quickRefusals : .other }

	/// A text set directly (`errorMessage = …`), or nil when the alert is closed ("확인").
	mutating func set(_ text: String?) {
		message = text
		onlyQuickRefusals = false
	}

	/// `text` after a message that is still waiting there (none is replaced): `AppModel.report`.
	mutating func report(_ text: String) {
		set(message.map { "\($0)\n\n\(text)" } ?? text)
	}

	/// A quick-preset refusal. It replaces an alert that holds only such refusals — the latest press's reason is what
	/// matters, not every earlier one — and the alert still holds only refusals; after anything else it is added like
	/// `report`, and the alert then holds more than refusals.
	mutating func reportQuickRefusal(_ text: String) {
		guard content != .other else {
			report(text)
			return
		}
		message = text
		onlyQuickRefusals = true
	}
}

/// What "Finder를 다시 시작할까요?" follows: its text names what the restart shows (new or restored view settings).
enum RelaunchReason: Equatable { case apply, undo }

/// What "지금 다시 시작" did (`AppModel.restartFinder`). The question follows a write (an apply, a folder undo) and a
/// Finder that quits writes what it holds in memory for the folders it shows into their parent `.DS_Store`, over what was
/// just written: the folders of that operation which held what it wrote before the quit and do not after
/// it are written again while Finder is down.
struct FinderRestart: Equatable, Sendable {
	/// Finder quit; when it did not, nothing else happened (nothing was written again) and the question is asked again.
	var quit = false
	/// Finder runs again.
	var back = false
	/// The operation is a folder undo: the advice at the end differs ("다시 적용하세요" is for an apply).
	var undo = false
	/// Folders of the operation that no longer held what it wrote before the quit (a window closed meanwhile, whose
	/// folder Finder wrote over; an undo; the user; another tool): not written again, but named.
	var leftAlone: [String] = []
	/// Folders Finder overwrote as it quit, written again with what the operation wrote.
	var rewritten: [String] = []
	/// Folders it overwrote that could not be written again, and the first reason.
	var notRewritten: [String] = []
	var reason: String?
	/// Folders that did not hold what the operation wrote when they were read back, once Finder had been launched again
	/// and had a moment to settle (`FinderLifecycle.settle`). Only folders that held it right before the quit, so never
	/// one of `leftAlone` (`AppModel.restartFinder`).
	var overwritten: [String] = []
	/// `overwritten` without the folders named as not written again: those Finder overwrote after the restart.
	var stillOverwritten: [String] { overwritten.filter { !notRewritten.contains($0) } }
	/// The operation's folders opened once Finder was back (`FolderReopen`; those the opener reported as opened), or how
	/// many there were when they were too many to open (then none was opened).
	var reopened: [String] = []
	var tooManyToReopen = 0
	/// How many of the windows Finder showed before the quit were opened again once it was back (`FinderWindows`: before
	/// the operation's folders, without them).
	var windowsReopened = 0

	/// Anything but a clean restart — Finder did not quit or come back, folders were not written again, were overwritten
	/// or were left alone —, i.e. the status line is a warning (StatusBar.tone): the app's window is brought forward over
	/// the Finder windows the restart has just opened (`AppModel.relaunchFinder`), so the warning, or the question asked
	/// again, is seen. A clean restart leaves Finder in front.
	var needsAttention: Bool {
		!quit || !back || !notRewritten.isEmpty || !leftAlone.isEmpty || !stillOverwritten.isEmpty
	}

	/// Whether folders were written again, or tried (`Applier.writeAgain` ran): it saves the operation's record again — a
	/// new backup, the `after` read back — also when some of its folders failed, and finds it gone when it was deleted
	/// meanwhile. An open history sheet then reads the record again (`AppModel.relaunchFinder`).
	var recordMayHaveChanged: Bool { !rewritten.isEmpty || !notRewritten.isEmpty }

	/// The status line. Anything but a clean restart reads as a warning (StatusBar.tone).
	var message: String {
		guard quit else {
			return String(localized: "Finder 재실행 실패: Finder가 종료되지 않았습니다(아무것도 다시 쓰지 않음). Finder의 복사나 대화상자가 끝난 뒤, 다시 묻는 창에서 \"지금 다시 시작\"을 고르세요.")
		}
		var parts: [String]
		if !back {
			parts = [String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")]
		} else if !reopened.isEmpty {
			parts = [String(localized: "Finder를 다시 시작했습니다."), String(localized: "폴더 \(reopened.count)개를 열었습니다: \(Fmt.folderNames(reopened)).")]
		} else if tooManyToReopen > 0 {
			parts = [String(localized: "Finder를 다시 시작했습니다."),
			         String(localized: "폴더가 \(tooManyToReopen)개라 열지 않았습니다(한 번에 \(FolderReopen.limit)개까지 엽니다). 필요한 폴더는 직접 여세요.")]
		} else {
			parts = [String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요.")]
		}
		// "도" (Also) only after a sentence that opened the operation's folders.
		if back && windowsReopened > 0 {
			parts.append(reopened.isEmpty ? String(localized: "열려 있던 Finder 창 \(windowsReopened)개를 다시 열었습니다.")
				: String(localized: "열려 있던 Finder 창 \(windowsReopened)개도 다시 열었습니다."))
		}
		if !rewritten.isEmpty { parts.append(String(localized: "Finder가 종료하면서 덮어쓴 폴더 \(rewritten.count)개는 다시 썼습니다.")) }
		if !notRewritten.isEmpty {
			parts.append(String(localized: "Finder가 종료하면서 덮어쓴 폴더 \(notRewritten.count)개는 다시 쓰는 데 실패했습니다: \(reason ?? "?")"))
		}
		let still = stillOverwritten
		if !still.isEmpty {
			parts.append(String(localized: "폴더 \(still.count)개는 Finder를 다시 시작한 뒤에도 쓴 값이 아닙니다(Finder가 덮어씀)."))
		}
		if !leftAlone.isEmpty {
			parts.append(String(localized: "폴더 \(leftAlone.count)개는 다시 시작하기 전에 이미 쓴 값이 아니어서 다시 쓰지 않았습니다(창을 닫을 때 Finder가 덮어썼거나 다른 곳에서 바뀜)."))
		}
		if !notRewritten.isEmpty || !still.isEmpty || !leftAlone.isEmpty {
			parts.append(undo ? String(localized: "툴바의 \"기록\"에서 확인하세요.") : String(localized: "폴더가 바뀌지 않았으면 다시 적용하세요."))
		}
		return parts.joined(separator: " ")
	}
}

/// Which folders "지금 다시 시작" opens once Finder is back (`AppModel.restartFinder`), like the quick preset opens its
/// folder again: the user wants to see what the apply or the folder undo changed. They are opened after the windows
/// Finder showed before the quit (`FinderWindows`), so they end up in front.
enum FolderReopen: Equatable, Sendable {
	/// These folders, in the operation's order.
	case open([URL])
	/// More than `limit` of them: none is opened (a pile of windows is worse than none); the status line says how many.
	case tooMany(Int)

	static let limit = 5

	/// The roots of `op` — the rows of "2. 적용할 폴더" that were applied (or whose apply was undone), never the subfolders
	/// under them — in which it changed something (the root itself or a folder inside it: a row that was already the same
	/// is not opened), each once, without those that are no longer folders. Nothing without an operation, and nothing for
	/// one whose roots include the home folder (`home`), which the folder list refuses: "시스템 전체에 적용"'s home
	/// folders (the home folder and its standard folders, which that apply's own restart does not open either, so neither
	/// does the restart after undoing them) or a quick preset on the home folder window.
	static func choose(for op: FinderPresetsOperation?, limit: Int = limit,
	                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
	                   isFolder: (URL) -> Bool = FinderWindows.isFolder) -> FolderReopen {
		guard let op else { return .open([]) }
		guard !op.roots.contains(where: { HomeFolders.isHome($0, home: home) }) else { return .open([]) }
		let changed = op.entries.filter { $0.status == .changed || $0.status == .positionsOnly }.map { FolderRule.normalize($0.folderPath) }
		var seen = Set<String>()
		let roots = op.roots.map(FolderRule.normalize).filter { root in
			let inside = root.hasSuffix("/") ? root : root + "/"
			return seen.insert(root).inserted && changed.contains { $0 == root || $0.hasPrefix(inside) }
		}
		let folders = roots.map { URL(fileURLWithPath: $0) }.filter(isFolder)
		return folders.count > limit ? .tooMany(folders.count) : .open(folders)
	}
}

/// What "시스템 전체에 적용" will do, computed before the confirmation sheet (nothing written, Finder untouched).
struct GlobalApplyPlan {
	var preset: Preset               // the preset selected when the analysis started (the one that is written)
	var roots: [URL]                 // the home folder, then the standard home folders; empty when the checkbox is off
	var plan: Plan?                  // folder plan for `roots` (nil when there are no roots)
	var globalDiffs: [FieldDiff]     // Finder's global defaults vs. the preset; empty = already identical
	var stamp: PlanStamp             // presets, selection and the two checkboxes when the analysis started
	var folderChanges: Int { plan?.changes.count ?? 0 }
	/// False for a preset that only sets a grouping: Finder's defaults are never given one (`ViewSettings.globalDefaultsPart`).
	var writesGlobalDefaults: Bool { !preset.settings.globalDefaultsPart.isEmpty }

	/// " 그룹 기준은 Finder 기본 보기에 쓰지 않고 폴더에만 씁니다." for a preset with a grouping that also sets something
	/// Finder's defaults hold; "" otherwise (a preset with only a grouping says so in its first sentence).
	static func groupNote(_ preset: Preset) -> String {
		guard preset.settings.groupBy != nil, !preset.settings.globalDefaultsPart.isEmpty else { return "" }
		return " " + String(localized: "그룹 기준은 Finder 기본 보기에 쓰지 않고 폴더에만 씁니다.")
	}
}

@MainActor
@Observable
final class AppModel {
	static let helpDismissedKey = "helpSheetDismissed"

	let dirs = AppDirectories.standard
	let presetStore: PresetStore
	let operationStore: OperationStore
	private(set) var globals = GlobalDefaults.readCurrent()

	// The didSet counters feed `planStamp` (see PlanStamp); they only count real changes.
	var presets: [Preset] = [] { didSet { if presets != oldValue { presetEdits &+= 1 } } }
	var targets: [TargetFolder] = [] { didSet { if targets != oldValue { targetEdits &+= 1 } } }
	var selectedPresetID: UUID? { didSet { if selectedPresetID != oldValue { presetEdits &+= 1 } } }
	var selectedTargets = Set<String>()
	/// "빠른 적용" (QuickPreset.swift): the one starred preset the quick preset service applies; kept in `quickPresetSetting`.
	var quickPresetID: UUID?
	@ObservationIgnored let quickPresetSetting: QuickPresetSetting
	var includeSubfolders = true { didSet { if includeSubfolders != oldValue { targetEdits &+= 1 } } }

	/// A task runs in the background (an analysis, a write, a Finder restart). When one that writes or quits Finder ends
	/// (`beginWriting`), a quit the user asked for meanwhile goes ahead (`terminateReply`).
	var isWorking = false {
		didSet {
			guard oldValue, !isWorking, quitGuard.writing else { return }
			guard quitGuard.end(finderRunning: FinderController.isRunning) else { return }
			// After the rest of the task's report (status line, error) on the next turn of the main actor. The relaunch
			// question is not asked meanwhile (`askRelaunchFinder`): any alert or sheet over the window keeps AppKit from
			// quitting. An error is left on screen instead, and the quit is dropped so it can be read.
			Task { @MainActor in
				if self.errorMessage == nil { NSApp.terminate(nil) }
				// Still here: an error to read, or a sheet kept AppKit from quitting.
				self.quitGuard.dropQuit()
			}
		}
	}
	/// Whether "종료" may go ahead now (`terminateReply`).
	@ObservationIgnored private(set) var quitGuard = QuitGuard()
	var status = String(localized: "프리셋을 고르고 폴더에 적용하세요.")
	/// The "오류" alert's text (MainView), nil when it is closed. Setting it, to a text or to nil ("확인"), leaves an alert
	/// that holds no quick-preset refusal of its own (`errorAlert`).
	var errorMessage: String? {
		get { errorAlert.message }
		set { errorAlert.set(newValue) }
	}
	/// The alert's text and whether it holds only quick-preset refusals (`ErrorAlert`, `reportQuickRefusal`).
	private(set) var errorAlert = ErrorAlert()
	var askRelaunch = false
	/// What "Finder를 다시 시작할까요?" follows (MainView words it): an apply, or a folder undo.
	var relaunchAfter: RelaunchReason = .apply
	/// The operation that question follows (the apply or folder undo just written; also the history sheet's question):
	/// "지금 다시 시작" writes again what Finder overwrites of it as it quits (`relaunchFinder`). Nil: only a restart.
	@ObservationIgnored var relaunchOperationID: UUID?
	/// Whether "지금 다시 시작" opens that operation's folders once Finder is back (`FolderReopen`): after an apply of the
	/// folder list and after a folder undo, not after "시스템 전체에 적용" (the home folder and its standard folders; the
	/// undo of those home folders opens none either, since `FolderReopen.choose` skips a record rooted at the home folder).
	@ObservationIgnored var relaunchReopensFolders = true
	var pendingApply: PendingApply?

	var showHelp = false
	/// The preset "삭제…" asks about (MainView's confirmation); nothing is deleted before `confirmDeletePreset`.
	var pendingPresetDelete: Preset?
	/// The draft the preset editor opened with (PresetEditor.swift); non-nil while the sheet is shown. The sheet edits its
	/// own copy, so typing never touches the model; nothing is written before `savePresetEdit`.
	var presetEditor: PresetDraft?
	/// Why the last "저장" in the editor saved nothing (a value that cannot be saved, a file changed elsewhere).
	var presetEditorProblem: String?
	var applyToHomeFolders = true
	var includeDesktop = false
	var pendingGlobalApply: GlobalApplyPlan?

	// "기록" (the history sheet) and undo in the app: HistoryModel.swift.
	var showHistory = false
	/// Every readable record, newest first (`OperationHistory.overviews`), as last read by `loadHistory`.
	var historyItems: [OperationOverview] = []
	/// Operation folders whose manifest could not be read ("<folder>: <reason>"); left alone.
	var historyUnreadable: [String] = []
	/// The two records one "시스템 전체에 적용" leaves (home folders ↔ Finder's defaults), both ways.
	var historyPairs: [UUID: UUID] = [:]
	var historyLoading = false
	/// The records chosen in the list: one, or several with ⇧-click and ⌘-click (they can then be deleted together).
	var historySelected: Set<UUID> = []
	/// The one chosen record, whose details, undo and pin the sheet offers; nil when none or several are chosen. Setting
	/// it chooses that record alone.
	var historySelection: UUID? {
		get { historySelected.count == 1 ? historySelected.first : nil }
		set { historySelected = newValue.map { [$0] } ?? [] }
	}
	/// The selected record's preset and folders (`loadHistoryDetails`), read from its manifest when the selection changes.
	var historyDetails: HistoryDetails?
	/// The record whose manifest could not be read (removed or unreadable since the list was read): the pane says so
	/// instead of staying as empty as it is while the manifest is still being read.
	var historyDetailsUnreadable: UUID?
	/// A short message inside the sheet (a refused undo or pin); the main window's alerts cannot show over a sheet.
	var historyNotice: String?
	/// What "지우기…" / "기록 모두 지우기…" asks about; nothing is removed before it is confirmed (HistoryModel.swift).
	var pendingHistoryDelete: HistoryDeletion?
	var undoPhase: UndoPhase = .idle
	/// "Finder를 다시 시작할까요?" inside the history sheet, after a folder undo.
	var askRelaunchAfterUndo = false
	/// The operation an apply just recorded and the status line that reported it: while that line is shown, the status bar
	/// offers "되돌리기…" for it.
	var recentOperation: RecentOperation?
	/// Records removed by the automatic cleanup during this launch.
	var retentionRemoved = 0
	/// How many times the automatic cleanup ran during this launch (at launch, after every recorded operation).
	@ObservationIgnored var retentionRuns = 0
	@ObservationIgnored var historyGeneration = 0
	/// The records the sheet listed before it was opened again without a record to select (`openHistory`), until a read
	/// of the list has used them (`loadHistory`, `chosenHistoryRecords`).
	@ObservationIgnored var historyShownBefore: Set<UUID>?
	@ObservationIgnored var historyDetailsGeneration = 0
	@ObservationIgnored var launchRetentionStarted = false

	@ObservationIgnored private var presetEdits = 0
	@ObservationIgnored private var targetEdits = 0
	/// Set while targets.json exists but could not be read (the reason). `targets` then does not reflect the file, so
	/// `saveTargets` moves the file aside before writing instead of silently replacing the list stored in it.
	@ObservationIgnored private var targetsFileProblem: String?
	/// Unreadable preset files already reported, so every reload does not raise the same alert again.
	@ObservationIgnored private var reportedUnreadablePresets = Set<String>()

	init() {
		presetStore = PresetStore(dirs: dirs)
		operationStore = OperationStore(dirs: dirs)
		quickPresetSetting = .forThisLaunch
		quickPresetID = quickPresetSetting.id
		reload(selectFirstPreset: true)
	}

	private var targetsURL: URL { dirs.root.appendingPathComponent("targets.json") }

	var planStamp: PlanStamp {
		PlanStamp(presets: presetEdits, targets: targetEdits, homeFolders: applyToHomeFolders, includeDesktop: includeDesktop)
	}

	/// Starts a task that writes (folders, records) or quits Finder: `isWorking`, and "종료" waits until it ends.
	func beginWriting(quitsFinder: Bool) {
		isWorking = true
		quitGuard.begin(quitsFinder: quitsFinder)
	}

	/// The app's answer to "종료" (AppDelegate.applicationShouldTerminate). While a task writes or has Finder quit (a
	/// system-wide apply, a Finder default undo, "지금 다시 시작" or the quick preset keeps Finder quit for a few seconds —
	/// up to about 40 when Finder is slow to quit (10), to exit (5) and to start, asked twice (2 × 10, a second more after
	/// each error) —, then opens its windows again and gives it 1.5 s to settle), quitting would leave Finder quit or the
	/// record unfinished: the quit is put off, the status line says so, and the app quits by itself once the task has
	/// ended. Otherwise the app quits at once.
	func terminateReply() -> NSApplication.TerminateReply {
		guard !quitGuard.requestQuit() else { return .terminateNow }
		status = String(localized: "작업이 끝나면 앱을 종료합니다. 파일 쓰기와 Finder 다시 실행이 끝날 때까지 기다려 주세요.")
		return .terminateCancel
	}

	/// When the app quits: Finder is launched again if this app quit it and it did not come back. This runs on the main
	/// thread as the app terminates, so Finder is asked once (`FinderController.launch` with one attempt), and the wait is
	/// the 5 s it was before the launch could retry — 6 s at most, when LaunchServices reports an error at the very end.
	/// Its windows are not opened here: the task that read them has ended by then.
	func relaunchFinderLeftQuit() {
		guard quitGuard.relaunchOnQuit(finderRunning: FinderController.isRunning) else { return }
		FinderController.launch(timeout: Self.quitTimeLaunchTimeout, attempts: 1)
	}

	/// How long `relaunchFinderLeftQuit` waits for Finder (one request).
	nonisolated static let quitTimeLaunchTimeout: TimeInterval = 5

	/// True when a data file could not be read at the last reload (an unreadable preset file or targets.json).
	var hasUnreadableData: Bool { targetsFileProblem != nil || !reportedUnreadablePresets.isEmpty }

	/// Reads the presets and targets.json independently: a broken preset file never keeps the folder list from loading.
	/// The first preset is selected only at launch (`selectFirstPreset`); later reloads (rename, delete, import) keep
	/// "no preset selected", which makes an apply skip the folders without an assignment.
	func reload(selectFirstPreset: Bool = false) {
		do { try dirs.ensure() } catch { errorMessage = ErrorText.describe(error); return }
		var problems: [String] = []
		var presetsComplete = false
		do {
			let listing = try presetStore.listReadable()
			presets = listing.presets
			presetsComplete = listing.unreadable.isEmpty
			let unreported = listing.unreadable.filter { !reportedUnreadablePresets.contains($0) }
			reportedUnreadablePresets = Set(listing.unreadable)
			if !unreported.isEmpty {
				problems.append(String(localized: "읽지 못한 프리셋 파일이 있어 목록에서 뺐습니다(파일은 그대로 둡니다). 이 파일을 가리키는 폴더별 지정도 그대로 둡니다.")
					+ "\n" + unreported.joined(separator: "\n"))
			}
		} catch {
			problems.append(String(localized: "프리셋 목록을 읽지 못했습니다: \(ErrorText.describe(error))"))
		}
		// A star on a preset that no longer exists is forgotten — only when every preset file was read (see below).
		if presetsComplete { quickPresetID = quickPresetSetting.validID(among: presets) }
		let targetsComplete = loadTargets(problems: &problems)
		if selectFirstPreset, selectedPresetID == nil { selectedPresetID = presets.first?.id }
		// Assignments to a preset that no longer exists (e.g. its file was removed outside the app) fall back to
		// "선택한 프리셋 사용" — only when every preset file and targets.json were read: a preset file this version
		// cannot read is not a deleted preset, and an unread targets.json is not the folder list.
		if presetsComplete && targetsComplete {
			let ids = Set(presets.map(\.id))
			clearAssignments { !ids.contains($0) }
		}
		if !problems.isEmpty { report(problems.joined(separator: "\n\n")) }
	}

	/// Shows `message` in the error alert, after a message that is still waiting there (none is replaced).
	func report(_ message: String) {
		errorAlert.report(message)
	}

	/// Shows a quick-preset refusal in the error alert: it replaces an alert that holds only such refusals, and follows
	/// anything else like `report` (`ErrorAlert.reportQuickRefusal`). The next press of the shortcut closes an alert that
	/// holds only refusals and goes on (`quickApplyGate`).
	func reportQuickRefusal(_ message: String) {
		errorAlert.reportQuickRefusal(message)
	}

	/// Loads targets.json into `targets`. A missing file keeps the current list. Returns false when the file exists
	/// but cannot be read or decoded: `targets` keeps its current value and `targetsFileProblem` protects the file.
	private func loadTargets(problems: inout [String]) -> Bool {
		guard FileManager.default.fileExists(atPath: targetsURL.path) else { return true }
		do {
			targets = try JSONCoding.decoder().decode([TargetFolder].self, from: Data(contentsOf: targetsURL))
			targetsFileProblem = nil
			return true
		} catch {
			if targetsFileProblem == nil {
				problems.append(String(localized: "폴더 목록 파일(targets.json)을 읽지 못했습니다: \(ErrorText.describe(error))\n목록을 바꾸면 이 파일은 지우지 않고 같은 폴더에 다른 이름으로 옮겨 둡니다."))
			}
			targetsFileProblem = ErrorText.describe(error)
			return false
		}
	}

	private static let asideFormatter: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyyMMdd-HHmmss"
		return f
	}()

	/// Writes targets.json. While the file on disk could not be read, it is first moved to
	/// `targets.json.unreadable-<time>`, so the list in memory never replaces what it holds; if that fails, nothing is written.
	private func saveTargets() {
		if targetsFileProblem != nil {
			let aside = dirs.root.appendingPathComponent("targets.json.unreadable-\(Self.asideFormatter.string(from: Date()))")
			do {
				try FileManager.default.moveItem(at: targetsURL, to: aside)
				report(String(localized: "읽지 못한 폴더 목록 파일을 \(aside.lastPathComponent)(으)로 옮겨 두고 지금 목록을 저장했습니다. 예전 목록이 필요하면 그 파일을 확인하세요."))
			} catch {
				guard !FileManager.default.fileExists(atPath: targetsURL.path) else {
					report(String(localized: "폴더 목록을 저장하지 않았습니다. 읽지 못한 targets.json을 옮기지 못했습니다: \(ErrorText.describe(error))"))
					return
				}
			}
			targetsFileProblem = nil
		}
		do {
			try JSONCoding.encoder().encode(targets).write(to: targetsURL, options: .atomic)
		} catch {
			report(String(localized: "폴더 목록을 저장하지 못했습니다: \(ErrorText.describe(error))"))
		}
	}

	/// Sets `presetID` to nil where `matches` holds, and saves only when something changed.
	private func clearAssignments(where matches: (UUID) -> Bool) {
		var changed = false
		for i in targets.indices {
			if let id = targets[i].presetID, matches(id) { targets[i].presetID = nil; changed = true }
		}
		if changed { saveTargets() }
	}

	var selectedPreset: Preset? { presets.first { $0.id == selectedPresetID } }

	/// Reads Finder's global defaults again — the one place that does, so what is derived from them (`previewDefaults`) is
	/// never left behind by a write of Finder's defaults (a global apply or undo) or by a plan that re-read them.
	func refreshGlobals() {
		globals = GlobalDefaults.readCurrent()
		previewDefaultsCache = nil
	}

	/// Finder's defaults as a preset preview draws "유지" — read once and kept until the globals are read again. The
	/// editor's preview window takes its own copy when it opens; the history sheet draws its records with this one.
	var previewDefaults: PreviewDefaults {
		if let previewDefaultsCache { return previewDefaultsCache }
		let made = PreviewDefaults(globals, foldersFirst: PresetPreviewController.readFoldersFirst())
		previewDefaultsCache = made
		return made
	}

	@ObservationIgnored private var previewDefaultsCache: PreviewDefaults?

	// MARK: Presets

	/// "이 폴더처럼": reads the folder's current Finder view settings and stores them as a preset.
	func importPreset(from folder: URL) {
		do {
			let made = try makePreset(from: folder)
			let name = Fmt.name(folder.lastPathComponent)
			status = made.ownSettings ? String(localized: "\(name)의 보기 설정을 프리셋으로 저장했습니다.")
				: String(localized: "\(name)에는 고유 설정이 없어 현재 표시되는 값(Finder 기본값)을 저장했습니다.")
		} catch { errorMessage = ErrorText.describe(error) }
	}

	/// Stores the folder's current Finder view settings as a new preset named after the folder ("사진 2" when the name is
	/// taken) and selects it. `ownSettings` is false when the folder has none and Finder's defaults were stored. Throws,
	/// with nothing written, when the folder's settings cannot be read (also the Finder services, FinderServices.swift).
	@discardableResult
	func makePreset(from folder: URL) throws -> (preset: Preset, ownSettings: Bool) {
		let loc = try ParentStoreLocator.locate(folder)
		let state = try Planner.readState(at: loc, globals: globals)
		let settings = state.hasExplicitRecords ? state.explicit : state.effective
		let name = PresetDraft.uniqueName(folder.lastPathComponent) { name in presets.contains { $0.name == name } }
		let p = Preset(name: name, settings: settings)
		try presetStore.save(p)
		reload()
		selectedPresetID = p.id
		return (p, state.hasExplicitRecords)
	}

	func chooseFolderForPreset() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true; panel.canChooseFiles = false
		panel.prompt = String(localized: "가져오기")
		panel.message = String(localized: "이 폴더의 현재 Finder 보기 설정을 프리셋으로 가져옵니다")
		if panel.runModal() == .OK, let url = panel.url { importPreset(from: url) }
	}

	/// An empty (or blank) name is never stored: it would show as an empty row and export as a hidden ".json" file.
	func rename(_ preset: Preset, to name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			status = String(localized: "이름이 비어 있어 프리셋 \"\(Fmt.name(preset.name))\"의 이름을 바꾸지 않았습니다.")
			return
		}
		guard trimmed != preset.name else { return }
		var p = preset; p.name = trimmed
		do {
			try presetStore.save(p)
			reload()
			// A status line that still names the old name would be stale.
			status = String(localized: "프리셋 \"\(Fmt.name(preset.name))\"의 이름을 \"\(Fmt.name(trimmed))\"(으)로 바꿨습니다.")
		} catch { errorMessage = ErrorText.describe(error) }
	}

	/// "삭제…" (the summary box's trash button, the row's right-click menu) asks first: deleting cannot be undone.
	func requestDeletePreset(_ id: UUID) { pendingPresetDelete = preset(id) }

	func confirmDeletePreset() {
		guard let p = pendingPresetDelete else { return }
		pendingPresetDelete = nil
		deletePreset(p.id)
	}

	/// The confirmation's text: the name, that it cannot be undone, and how many folder assignments it clears. The Korean
	/// lines are broken by hand (the alert wraps Hangul between any two syllables) and each fits the alert's width.
	func deleteMessage(_ p: Preset) -> String {
		let assigned = assignedFolderCount(p.id)
		var message = String(localized: "프리셋 \"\(p.name)\"을(를)\n삭제합니다. 되돌릴 수 없습니다.")
		if assigned > 0 { message += "\n" + String(localized: "이 프리셋을 지정한 폴더 \(assigned)개는\n\"선택한 프리셋 사용\"이 됩니다.") }
		return message
	}

	/// Folders assigned to the deleted preset go back to "선택한 프리셋 사용" (reload clears them and saves targets.json), and
	/// its star goes with it (also while another preset file cannot be read, when reload leaves the star alone).
	func deletePreset(_ id: UUID) {
		do {
			try presetStore.delete(id: id)
			if quickPresetID == id { quickPresetSetting.set(nil); quickPresetID = nil }
			reload()
			if selectedPresetID == id { selectedPresetID = presets.first?.id }
		} catch { errorMessage = ErrorText.describe(error) }
	}

	// MARK: Preset files (export / import)

	func exportSelectedPreset() {
		guard let p = selectedPreset else { errorMessage = String(localized: "먼저 프리셋을 선택하세요."); return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.canCreateDirectories = true
		panel.nameFieldStringValue = "\(p.name).json"
		panel.prompt = String(localized: "내보내기")
		panel.message = String(localized: "프리셋 \"\(p.name)\"을(를) JSON 파일로 저장합니다")
		if panel.runModal() == .OK, let url = panel.url { exportPreset(p, to: url) }
	}

	func exportPreset(_ preset: Preset, to url: URL) {
		do {
			try presetStore.export(preset, to: url)
			status = String(localized: "프리셋 \"\(Fmt.name(preset.name))\"을(를) \(Fmt.name(url.lastPathComponent))(으)로 내보냈습니다.")
		} catch { errorMessage = ErrorText.describe(error) }
	}

	func chooseFilesToImport() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
		panel.allowedContentTypes = [.json]
		panel.prompt = String(localized: "불러오기")
		panel.message = String(localized: "내보낸 프리셋 JSON 파일을 선택하세요 (여러 개 가능)")
		if panel.runModal() == .OK { importPresetFiles(panel.urls) }
	}

	/// Imports preset JSON files. A name that is already taken gets " 2", " 3", … like a folder import.
	/// Files that cannot be read are reported together; the others are still imported.
	func importPresetFiles(_ urls: [URL]) {
		var imported: [Preset] = []
		var failures: [String] = []
		for url in urls {
			do {
				var p = try presetStore.importPreset(from: url)
				let taken = Set(presets.map(\.name) + imported.map(\.name))
				if taken.contains(p.name) {
					p.name = PresetDraft.uniqueName(p.name, taken: taken.contains)
					try presetStore.save(p)
				}
				imported.append(p)
			} catch { failures.append("\(url.lastPathComponent): \(ErrorText.describe(error))") }
		}
		reload()
		if let last = imported.last {
			selectedPresetID = last.id
			status = String(localized: "프리셋 \(imported.count)개를 불러왔습니다: \(Fmt.name(imported.map(\.name).joined(separator: ", ")))")
		}
		if !failures.isEmpty { report(String(localized: "불러오지 못한 파일:") + "\n" + failures.joined(separator: "\n")) }
	}

	// MARK: Help

	/// First launch (no presets, no folders) shows the guide once, unless the user chose "다시 보지 않기".
	/// A data folder whose files could not be read is not a first launch.
	func showHelpIfFirstLaunch() {
		guard presets.isEmpty, targets.isEmpty, !hasUnreadableData, !UserDefaults.standard.bool(forKey: Self.helpDismissedKey) else { return }
		showHelp = true
	}

	func dismissHelp(dontShowAgain: Bool) {
		showHelp = false
		UserDefaults.standard.set(dontShowAgain, forKey: Self.helpDismissedKey)
	}

	// MARK: Targets

	/// The home folder and the folders above it (`/`, `/Users`) are refused: with "하위 폴더 포함" they would change every
	/// folder in the home folder, the Desktop included. Only local folders are added: a file, a missing item or a web
	/// link (whose path could name a real local folder, e.g. `https://…/Applications`) is left out and reported. A folder
	/// already in the list (or given twice) is added once (`folderAddition`, FinderServices.swift).
	@discardableResult
	func addFolders(_ urls: [URL]) -> FolderAddition {
		let result = Self.folderAddition(urls, listed: targets.map(\.path))
		if !result.added.isEmpty {
			targets.append(contentsOf: result.added.map { TargetFolder(path: $0) })
			saveTargets()
		}
		if !result.refused.isEmpty { report(Self.homeRefusal(result.refused)) }
		if !result.notFolders.isEmpty { report(String(localized: "폴더만 추가할 수 있습니다. 추가하지 않은 항목: \(result.notFolders.joined(separator: ", "))")) }
		return result
	}

	static func homeRefusal(_ paths: [String]) -> String {
		String(localized: "홈 폴더와 그 상위 폴더는 목록에 넣을 수 없습니다: \(paths.joined(separator: ", "))\n하위 폴더까지 적용하면 데스크탑을 포함한 홈 폴더 안의 모든 폴더가 바뀌기 때문입니다. 그 안의 폴더(예: 문서, 다운로드)를 추가하세요.")
	}

	func chooseFolders() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
		panel.prompt = String(localized: "추가")
		panel.message = String(localized: "보기 설정을 적용할 폴더를 선택하세요")
		if panel.runModal() == .OK { addFolders(panel.urls) }
	}

	func removeSelectedTargets() { removeTargets(selectedTargets) }

	func removeTargets(_ paths: Set<String>) {
		targets.removeAll { paths.contains($0.path) }
		selectedTargets.subtract(paths)
		saveTargets()
	}

	// MARK: Per-folder presets

	/// Assigns a preset to the given target folders (nil = "선택한 프리셋 사용") and saves targets.json.
	func assignPreset(_ id: UUID?, to paths: Set<String>) {
		guard id.map({ id in presets.contains { $0.id == id } }) ?? true else { return }
		var changed = false
		for i in targets.indices where paths.contains(targets[i].path) && targets[i].presetID != id {
			targets[i].presetID = id
			changed = true
		}
		guard changed else { return }
		saveTargets()
		let rows = targets.filter { paths.contains($0.path) }
		let names = Fmt.folderNames(rows.map(\.path))
		if let p = preset(id) {
			status = String(localized: "\(names)에 프리셋 \"\(Fmt.name(p.name))\"을(를) 지정했습니다. \"적용…\"을 눌러야 폴더가 바뀝니다.")
			return
		}
		// What the cleared rows use now: an assigned folder around them, the selected preset, or nothing (skipped).
		var notes: [(note: String, names: [String])] = []
		for row in rows {
			let note = fallbackNote(for: row)
			if let i = notes.firstIndex(where: { $0.note == note }) { notes[i].names.append(row.name) } else { notes.append((note, [row.name])) }
		}
		let detail = notes.count == 1 ? notes[0].note : notes.map { "\(Fmt.name($0.names.joined(separator: ", "))): \($0.note)" }.joined(separator: " · ")
		status = String(localized: "\(names)의 프리셋 지정을 해제했습니다. \(detail)")
	}

	func preset(_ id: UUID?) -> Preset? { id.flatMap { id in presets.first { $0.id == id } } }

	/// What a folder without its own preset uses on the next apply, in the words of the status line and the row's help:
	/// the nearest assigned folder around it (with "하위 폴더 포함"), else the selected preset, else nothing (skipped).
	func fallbackNote(for target: TargetFolder) -> String {
		if let from = assigningFolder(for: target) {
			if let p = preset(from.presetID) { return String(localized: "상위 폴더 \(Fmt.name(from.name))의 지정(\(Fmt.name(p.name)))을 따릅니다.") }
			return String(localized: "상위 폴더 \(Fmt.name(from.name))에 지정된 프리셋이 없어 적용할 때 건너뜁니다.")
		}
		if let p = selectedPreset { return String(localized: "왼쪽에서 선택한 프리셋(\(Fmt.name(p.name)))을 씁니다.") }
		return String(localized: "선택한 프리셋이 없어 적용할 때 건너뜁니다.")
	}

	/// The same resolution "적용…" uses: assigned targets are rules, the selected preset is the default.
	var batch: TargetBatch {
		TargetBatch(presets: presets, targets: targets.map(\.assignment), selectedPresetID: selectedPresetID, includeSubfolders: includeSubfolders)
	}

	/// For a folder without its own preset that sits inside an assigned target (with "하위 폴더 포함"): that target and its preset.
	func inheritedAssignment(for target: TargetFolder) -> (from: TargetFolder, preset: Preset)? {
		guard target.presetID == nil, includeSubfolders, let from = assigningFolder(for: target), let p = preset(from.presetID) else { return nil }
		return (from, p)
	}

	/// The assigned folder of the list around `target` that decides for it (with "하위 폴더 포함"), if any.
	private func assigningFolder(for target: TargetFolder) -> TargetFolder? {
		guard case .inheritedRule(_, let fromPath) = batch.resolver.resolve(path: target.path).source else { return nil }
		return targets.first { $0.path == fromPath }
	}

	/// True when at least one of the folders resolves to an existing preset (its own, inherited or the selected one).
	func canApply(to paths: [String]) -> Bool {
		let usable = paths.filter { !HomeFolders.isHomeOrAncestor($0) }
		return !usable.isEmpty && !batch.partition(roots: usable).applied.isEmpty
	}

	var selectedTargetPaths: [String] { targets.filter { selectedTargets.contains($0.path) }.map(\.path) }

	/// Tooltip of a row's warning icon. `~/Library` and `/Volumes` are in `ScanOptions.defaultExclusions()`, so an apply
	/// always skips them and everything inside them.
	func riskNote(_ path: String) -> String? {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		func isIn(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
		if path == home + "/Desktop" { return String(localized: "데스크탑은 아이콘 위치가 바뀔 수 있습니다.") }
		if HomeFolders.isHomeOrAncestor(path) { return String(localized: "홈 폴더와 그 상위 폴더에는 적용하지 않습니다(적용할 때 건너뜀). 그 안의 폴더를 추가하세요.") }
		if isIn(home + "/Library") { return String(localized: "~/Library 안의 폴더는 적용할 때 항상 건너뜁니다.") }
		if isIn("/Volumes") { return String(localized: "/Volumes 안의 폴더(외장·네트워크 볼륨)는 적용할 때 항상 건너뜁니다.") }
		return nil
	}

	// MARK: Apply

	/// "선택한 폴더에 적용…" / "전체 폴더에 적용…": each folder gets its own preset, a folder without one the selected preset,
	/// and with "하위 폴더 포함" the nearest assigned target decides for everything inside it (TargetBatch). Folders with no
	/// preset at all are skipped and reported. Plans first (nothing written), then asks for confirmation with the counts per preset.
	/// Nothing the user changes while the folders are checked is lost: the result is only shown (and later written) when the
	/// presets, the selection, the folder list, the assignments and "하위 폴더 포함" are still what the plan was made from.
	func prepareApply(to requested: [URL]) {
		// A home folder or a folder above it (only possible from a targets.json written before this check existed) is never scanned.
		let tooWide = requested.filter { HomeFolders.isHomeOrAncestor($0.path) }.map { Fmt.abbreviate($0.path) }
		let roots = requested.filter { !HomeFolders.isHomeOrAncestor($0.path) }
		let wideAlert = String(localized: "홈 폴더와 그 상위 폴더에는 적용하지 않습니다: \(tooWide.joined(separator: ", "))\n하위 폴더까지 적용하면 데스크탑을 포함한 홈 폴더 안의 모든 폴더가 바뀌기 때문입니다. 목록에서 제거하고 그 안의 폴더를 추가하세요.")
		guard !roots.isEmpty else {
			errorMessage = tooWide.isEmpty ? String(localized: "적용할 폴더가 없습니다.") : wideAlert
			return
		}
		let batch = self.batch
		let split = batch.partition(roots: roots.map(\.path))
		guard !split.applied.isEmpty else {
			errorMessage = String(localized: "적용할 프리셋이 없습니다. 왼쪽에서 프리셋을 선택하거나, 폴더 행의 메뉴에서 프리셋을 지정하세요.")
				+ "\n\n" + Self.skippedNote(split.skipped) + (tooWide.isEmpty ? "" : "\n\n" + wideAlert)
			return
		}
		isWorking = true
		status = String(localized: "폴더를 확인하는 중…")
		refreshGlobals()
		let globals = self.globals
		let exclusions = ScanOptions.defaultExclusions()
		let stamp = planStamp
		Task.detached(priority: .userInitiated) {
			let result = batch.plan(roots: roots, globals: globals, excludedPaths: exclusions)
			await MainActor.run {
				self.isWorking = false
				guard self.planStamp.sameForFolders(as: stamp) else {
					self.status = Self.staleNote
					return
				}
				let plan = result.plan
				let c = plan.counts
				let skipped = Self.skippedSuffix(result.skipped, tooWide: tooWide)
				if plan.changes.isEmpty {
					self.status = Self.noChangeNote(c[.alreadyMatching] ?? 0) + Self.problems(c) + skipped
					return
				}
				let changes = result.changesByPreset.map { PendingApply.PresetChange(name: batch.preset($0.presetID)?.name ?? "?", count: $0.count) }
				let single = result.changesByPreset.count == 1 ? batch.preset(result.changesByPreset[0].presetID) : nil
				let pending = PendingApply(roots: result.roots, plan: plan, skipped: result.skipped, tooWide: tooWide, presetChanges: changes,
				                           presetName: single?.name ?? changes.map(\.name).joined(separator: ", "),
				                           presetSnapshot: single?.settings, stamp: stamp)
				self.status = String(localized: "\(plan.changes.count)개 폴더를 바꿉니다 (\(pending.presetSummary)).") + " "
					+ String(localized: "이미 동일 \(c[.alreadyMatching] ?? 0)개") + Self.problems(c) + skipped
				self.pendingApply = pending
			}
		}
	}

	/// "취소" in the confirmation (or closing it): nothing was written, and the status line stops announcing the change.
	func cancelPendingApply() {
		guard pendingApply != nil else { return }
		pendingApply = nil
		status = Self.cancelNote
	}

	/// "취소" in the whole-system sheet (or closing it).
	func cancelPendingGlobalApply() {
		guard pendingGlobalApply != nil else { return }
		pendingGlobalApply = nil
		status = Self.cancelNote
	}

	/// An apply that finds nothing to change: "변경할 폴더가 없습니다. 이미 동일 N개".
	static func noChangeNote(_ alreadyMatching: Int) -> String { String(localized: "변경할 폴더가 없습니다. 이미 동일 \(alreadyMatching)개") }

	/// The status line of a write that stopped partway (a record that could not be saved): the reason, and that some
	/// folders may be written already (an apply, the quick preset).
	nonisolated static func stoppedWriteNote(_ reason: String) -> String {
		String(localized: "중단: \(reason)") + " · " + String(localized: "일부 폴더는 이미 변경됐을 수 있습니다 (되돌리기: 툴바의 \"기록\")")
	}

	static var cancelNote: String { String(localized: "취소했습니다. 파일과 Finder 설정은 그대로입니다.") }

	static var staleNote: String { String(localized: "확인하는 동안 프리셋, 선택, 폴더 목록이나 지정이 바뀌어 그 결과를 쓰지 않았습니다. 다시 \"적용…\"을 누르세요.") }

	static func tooWideNote(_ paths: [String]) -> String { String(localized: "홈 폴더나 그 상위 폴더라 건너뜀: \(Fmt.name(paths.joined(separator: ", ")))") }

	private static func problems(_ c: [PlanCategory: Int]) -> String {
		var parts: [String] = []
		if let n = c[.noPreset] { parts.append(String(localized: "프리셋 없음 \(n)")) }
		if let n = c[.permissionDenied] { parts.append(String(localized: "권한 없음 \(n)")) }
		if let n = c[.unreadable] { parts.append(String(localized: "읽지 못함 \(n)")) }
		if let n = c[.unsupported] { parts.append(String(localized: "미지원 \(n)")) }
		if let n = c[.excluded] { parts.append(String(localized: "제외 \(n)")) }
		return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
	}

	/// The confirmations' sentence for the folders whose icon positions the apply resets (`Plan.iconPositionResets`);
	/// "" when there are none. It leaves out which arrangements this concerns (정렬 없음·자동 격자 정렬): the
	/// system-wide sheet's message area is 80pt high and already holds the preset name twice.
	static func iconPositionsNote(_ count: Int) -> String {
		count == 0 ? "" : String(localized: "아이콘 크기나 간격이 바뀌는 폴더 \(count)개는 겹치지 않게 아이콘 자리를 새로 잡습니다.")
	}

	/// "프리셋이 없어 건너뜀: Documents, Music · 지정된 프리셋이 없어 건너뜀: Old"
	static func skippedNote(_ skipped: [TargetBatch.SkippedRoot]) -> String {
		func names(_ list: [TargetBatch.SkippedRoot]) -> String { Fmt.folderNames(list.map(\.path)) }
		let none = skipped.filter { $0.reason == .noPreset }
		let missing = skipped.filter { $0.reason != .noPreset }
		var parts: [String] = []
		if !none.isEmpty { parts.append(String(localized: "프리셋이 없어 건너뜀: \(names(none))")) }
		if !missing.isEmpty { parts.append(String(localized: "지정된 프리셋이 없어 건너뜀: \(names(missing))")) }
		return parts.joined(separator: " · ")
	}

	/// " · 프리셋이 없어 건너뜀: … · 홈 폴더나 그 상위 폴더라 건너뜀: …" after an apply's counts; "" when nothing was skipped.
	static func skippedSuffix(_ skipped: [TargetBatch.SkippedRoot], tooWide: [String]) -> String {
		(skipped.isEmpty ? "" : " · " + skippedNote(skipped)) + (tooWide.isEmpty ? "" : " · " + tooWideNote(tooWide))
	}

	func confirmApply() {
		guard let pending = pendingApply else { return }
		pendingApply = nil
		guard planStamp.sameForFolders(as: pending.stamp) else {
			status = Self.staleNote
			errorMessage = String(localized: "아무것도 바꾸지 않았습니다.") + " " + Self.staleNote
			return
		}
		beginWriting(quitsFinder: false)
		status = String(localized: "적용하는 중…")
		let applier = Applier(operations: operationStore, globals: globals)
		let request = ApplyRequest(plan: pending.plan, presetName: pending.presetName, presetSnapshot: pending.presetSnapshot)
		let planned = pending.changeCount
		let breakdown = pending.presetChanges.count > 1 ? " (\(pending.presetSummary))" : ""
		let skipped = Self.skippedSuffix(pending.skipped, tooWide: pending.tooWide)
		Task.detached(priority: .userInitiated) {
			do {
				let op = try applier.apply(request)
				await MainActor.run {
					self.isWorking = false
					let s = op.summary
					self.status = String(localized: "완료: \(s.changed)개 폴더 변경")
						+ (s.failed > 0 ? String(localized: ", \(s.failed)개 실패") : (s.changed == planned ? breakdown : "")) + skipped
					self.offerUndo(s.changed > 0 ? op.id : nil)
					if s.changed > 0 { self.askRelaunchFinder(after: .apply, operation: op.id) }
					self.afterOperationRecorded()
				}
			} catch {
				// Applier records each parent store as it goes; a throw here is a manifest write failure, so some
				// folders may already be written. Say so instead of leaving the status line at "적용하는 중…".
				await MainActor.run {
					self.isWorking = false
					self.status = Self.stoppedWriteNote(ErrorText.describe(error))
					self.errorMessage = ErrorText.describe(error)
					self.afterOperationRecorded()
				}
			}
		}
	}

	/// "Finder를 다시 시작할까요?" over the window, after `operation` wrote folders. Not while the app is about to quit (a
	/// quit asked for during the write): the alert would keep it from quitting. `reopensFolders`: "지금 다시 시작" opens
	/// the operation's folders once Finder is back (not after "시스템 전체에 적용").
	func askRelaunchFinder(after reason: RelaunchReason, operation: UUID?, reopensFolders: Bool = true) {
		guard !quitGuard.quitting else { return }
		relaunchAfter = reason
		relaunchOperationID = operation
		relaunchReopensFolders = reopensFolders
		askRelaunch = true
	}

	/// "지금 다시 시작" (after an apply, a folder undo): `restartFinder` in the background. The question comes after the
	/// write, so the write cannot wait for the quit; instead what Finder overwrites of that operation as it quits is
	/// written again before Finder is launched, and once Finder is back the operation's folders are opened (`FolderReopen`,
	/// with `NSWorkspace`; not after "시스템 전체에 적용"). "종료" waits meanwhile (QuitGuard). When Finder does not quit (a
	/// copy, a dialog of its own), nothing was written again or opened and the same question is asked again with the same
	/// operation — a restart by hand would be the unprotected order. `inHistory`: the question came from the history sheet
	/// (after a folder undo there), where it is asked again while the sheet is open. "나중에" calls nothing: Finder is not
	/// restarted and no folder is opened.
	func relaunchFinder(inHistory: Bool = false) {
		let operation = relaunchOperationID
		let reopens = relaunchReopensFolders
		relaunchOperationID = nil
		relaunchReopensFolders = true
		let reason = inHistory ? RelaunchReason.undo : relaunchAfter
		beginWriting(quitsFinder: true)
		status = String(localized: "Finder를 다시 시작하는 중…")
		let (store, globals) = (operationStore, globals)
		Task.detached {
			let restart = Self.restartFinder(after: operation, store: store, globals: globals, finder: RealFinderLifecycle(),
			                                 opener: reopens ? { NSWorkspace.shared.open($0) } : nil)
			await MainActor.run {
				self.isWorking = false
				self.status = restart.message
				// The history sheet read the record before it gained a backup and a new `after`: it shows it as it is now.
				if restart.recordMayHaveChanged { self.reloadHistoryIfShown(changed: operation) }
				if !restart.quit {
					self.askRelaunchAgain(after: reason, operation: operation, inHistory: inHistory, reopensFolders: reopens)
				}
				// Finder's windows, just opened again, are in front of the app: a warning or the question again comes forward.
				if restart.needsAttention { FinderServiceProvider.shared.showWindow() }
			}
		}
	}

	/// The question again after a restart Finder refused (`relaunchFinder`): in the history sheet while it is open, else
	/// over the window. Not while the app is quitting (a quit asked for during the restart).
	func askRelaunchAgain(after reason: RelaunchReason, operation: UUID?, inHistory: Bool, reopensFolders: Bool = true) {
		guard !quitGuard.quitting else { return }
		if inHistory && showHistory {
			relaunchOperationID = operation
			relaunchReopensFolders = reopensFolders
			askRelaunchAfterUndo = true
		} else {
			askRelaunchFinder(after: reason, operation: operation, reopensFolders: reopensFolders)
		}
	}

	/// "지금 다시 시작", off the main thread. Reads which folders of `operationID` (the apply or folder undo the question
	/// follows) still hold what it wrote (`Applier.holdingWritten`), quits Finder, writes again those that Finder's quit
	/// overwrote (`Applier.writeAgain`: the record read again, backed up, their `before` kept, so undoing the operation
	/// still restores the state before it), launches Finder, lets it settle (`FinderLifecycle.settle`) and reads them back
	/// once more. A folder that no longer held what was written before the quit is left alone and named
	/// (`FinderRestart.leftAlone`): it may be Finder's write as its window closed while the question was up, an undo,
	/// the user or another tool — which one cannot be told from the file. The other way round, a view
	/// the user changed in a Finder window that Finder had not written to the file yet cannot be told apart from the
	/// quit's own write: that folder counts as overwritten by the quit and gets the operation's values again (the store as
	/// Finder left it is in the new backup, `<hash>-2.DS_Store`; undo goes back to the state before the operation, not to
	/// that view). Nothing is written when Finder does not quit; without an operation, or when its record cannot be read,
	/// Finder is only restarted. `finder`: the real Finder in the app, a fake in the tests.
	///
	/// The folders of Finder's windows are read right before the quit and, once Finder is back, opened again
	/// (`FinderWindows`: at most `FinderWindows.limit`, back to front, without the operation's folders the opener opens
	/// next). With an `opener`, the operation's folders (`FolderReopen.choose`: its roots in which it changed something, at
	/// most `FolderReopen.limit`, else none; none for a record rooted at the home folder) are opened after them, so they end
	/// up in front — and before Finder is given its moment to settle, like the quick preset, so what Finder writes as it
	/// shows them is still read back. A Finder that went away while it settled is launched once more
	/// (`FinderLifecycle.settleAndCheck`). Nothing is opened when Finder did not come back. `opener`: `NSWorkspace` in the
	/// app, a fake in the tests, true when the folder was opened; nil opens none of the operation's folders.
	nonisolated static func restartFinder(after operationID: UUID?, store: OperationStore, globals: GlobalDefaults,
	                                      finder: any FinderLifecycle, opener: ((URL) -> Bool)? = nil) -> FinderRestart {
		let applier = Applier(operations: store, globals: globals)
		var op = operationID.flatMap { try? store.load(id: $0) }
		let holding = op.map(applier.holdingWritten) ?? []
		let windows = FinderWindows.remember(finder)
		guard finder.quit() else { return FinderRestart() }
		var result = FinderRestart(quit: true, undo: op?.kind.isUndo == true)
		if let current = op {
			result.leftAlone = current.entries.filter { $0.status == .changed && $0.after != nil && !holding.contains($0.folderPath) }
				.map(\.folderPath)
		}
		if let current = op, !holding.isEmpty {
			let lost = applier.verify(current).filter { holding.contains($0.folderPath) }
			if !lost.isEmpty {
				do {
					let again = try applier.writeAgain(lost, of: current)
					op = again.operation
					result.rewritten = lost.map(\.folderPath).filter { again.failed[$0] == nil }
					result.notRewritten = lost.map(\.folderPath).filter { again.failed[$0] != nil }
					result.reason = again.failed.values.first.map { ErrorText.describe($0) }
				} catch {
					// The manifest could not be read again or saved (the stores may be written): not reported as done.
					result.notRewritten = lost.map(\.folderPath)
					result.reason = ErrorText.describe(error)
				}
			}
		}
		result.back = finder.launch()
		if result.back {
			let choice = opener == nil ? FolderReopen.open([]) : FolderReopen.choose(for: op)
			let own: [URL] = if case .open(let folders) = choice { folders } else { [] }
			result.windowsReopened = windows.reopen(in: finder, before: own).count
			if let opener {
				switch choice {
				case .open(let folders):
					result.reopened = folders.filter(opener).map(\.path)
				case .tooMany(let count):
					result.tooManyToReopen = count
				}
			}
			result.back = finder.settleAndCheck()
		}
		if let op { result.overwritten = applier.verify(op).map(\.folderPath).filter(holding.contains) }
		return result
	}

	// MARK: Apply to the whole system (Finder global defaults + standard home folders)

	/// Analysis only — nothing is written and Finder is not touched: the home folder is planned (`systemPlan`) and
	/// Finder's global defaults are compared with the preset. Then the confirmation sheet shows what will change.
	func prepareGlobalApply() {
		guard let preset = selectedPreset else { errorMessage = String(localized: "먼저 프리셋을 선택하세요."); return }
		guard !preset.settings.isEmpty else { errorMessage = String(localized: "프리셋에 적용할 값이 없습니다."); return }
		isWorking = true
		status = String(localized: "Finder 기본 보기와 홈 폴더를 확인하는 중…")
		refreshGlobals()
		let withHome = applyToHomeFolders
		let includeDesktop = includeDesktop
		let globals = globals
		let stamp = planStamp
		// Finder's defaults never get a grouping: only the rest of the preset is compared with them (and written).
		let globalSettings = preset.settings.globalDefaultsPart
		Task.detached(priority: .userInitiated) {
			let current = GlobalDefaultsWriter.snapshot(domain: GlobalDefaultsWriter.finderDomain)
			let globalDiffs = globalSettings.isEmpty ? [] : current.decodedSettings.differences(to: globalSettings)
			let system = withHome ? Self.systemPlan(preset, globals: globals, includeDesktop: includeDesktop, writesDefaults: !globalDiffs.isEmpty) : nil
			let roots = system?.roots ?? []
			let plan = system?.plan
			await MainActor.run {
				self.isWorking = false
				// The preset or the checkboxes changed during the analysis: its result describes something else.
				guard self.planStamp.sameForSystem(as: stamp) else {
					self.status = String(localized: "확인하는 동안 프리셋이나 선택이 바뀌어 그 결과를 쓰지 않았습니다. 다시 \"시스템 전체에 적용…\"을 누르세요.")
					return
				}
				let c = plan?.counts ?? [:]
				let changes = plan?.changes.count ?? 0
				let globalPart = globalSettings.isEmpty ? String(localized: "그룹 기준만 있는 프리셋이라 Finder 기본 보기는 바꾸지 않습니다.")
					: globalDiffs.isEmpty ? String(localized: "Finder 기본 보기는 이미 \"\(Fmt.name(preset.name))\"과 같습니다.")
					: String(localized: "Finder 기본 보기를 \"\(Fmt.name(preset.name))\"(으)로 바꿉니다.")
				// No view changes but icon positions to reset (folders that follow the new default): say that instead of "0개".
				let resets = plan?.iconPositionResets ?? 0
				let folderPart = roots.isEmpty ? String(localized: "홈 폴더는 건드리지 않습니다.")
					: (changes == 0 && resets > 0 ? Self.iconPositionsNote(resets) : String(localized: "\(changes)개 폴더를 바꿉니다."))
						+ " " + String(localized: "이미 동일 \(c[.alreadyMatching] ?? 0)개") + Self.problems(c)
				if globalDiffs.isEmpty && changes == 0 {
					self.status = String(localized: "변경할 것이 없습니다.") + " " + globalPart + " " + folderPart + GlobalApplyPlan.groupNote(preset)
				} else {
					self.status = globalPart + " " + folderPart + GlobalApplyPlan.groupNote(preset)
					self.pendingGlobalApply = GlobalApplyPlan(preset: preset, roots: roots, plan: plan, globalDiffs: globalDiffs, stamp: stamp)
				}
			}
		}
	}

	/// The folders "시스템 전체에 적용" changes with "홈 폴더 포함", planned (nothing written):
	/// - the standard home folders (문서·다운로드·사진·음악·동영상, and the Desktop with "데스크탑 포함") with all their
	///   subfolders, like an apply with "하위 폴더 포함";
	/// - the rest of the home folder — the home folder itself (its own `"."` record, `ParentStoreLocator`) and every
	///   folder in it outside those — where a folder has view settings of its own (`PlanOptions.ownSettingsOnly`). The
	///   others follow Finder's default view, which the same apply sets, so nothing is written for their view. When the
	///   apply writes Finder's defaults (`writesDefaults`: the preset has a part for them and they differ), such a folder
	///   whose icons would be drawn bigger at the positions Finder stored for the old default loses those positions
	///   (`PlanCategory.iconPositionsOnly`). Folders outside the home folder are never planned, so theirs stay.
	/// ~/Library, the Trash, hidden folders and packages are never planned. `home`: a test passes a folder of its own.
	nonisolated static func systemPlan(_ preset: Preset, globals: GlobalDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser,
	                                   includeDesktop: Bool, writesDefaults: Bool = false) -> (roots: [URL], plan: Plan) {
		let standard = HomeFolders.standardFolders(home: home, includeDesktop: includeDesktop)
		let resolver = RuleResolver(rules: [], defaultPresetID: preset.id)
		let exclusions = ScanOptions.defaultExclusions(home: home)
		let full = Planner(presets: [preset], resolver: resolver, globals: globals, home: home)
			.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: nil, excludedPaths: exclusions)).scan(roots: standard), roots: standard)
		let rest = ScanOptions(maxDepth: nil, excludedPaths: exclusions + standard.map(\.path) + [home.appendingPathComponent(HomeFolders.desktopName).path])
		// What GlobalApplier writes (the preset's part for Finder's defaults) over what they hold now.
		let defaultsAfter = writesDefaults ? preset.settings.normalized().globalDefaultsPart.filling(from: globals.effectiveSettings) : nil
		let own = Planner(presets: [preset], resolver: resolver, globals: globals,
		                  options: PlanOptions(ownSettingsOnly: true, defaultsAfterApply: defaultsAfter), home: home)
			.plan(scanned: FolderScanner(options: rest).scan(roots: [home]), roots: [home])
		let roots = [home] + standard
		return (roots, Plan(roots: roots, entries: own.entries + full.entries))
	}

	/// Everything a running Finder could overwrite from its cache is written while Finder is down:
	/// snapshot → read the folders of Finder's windows → quit Finder → home folders (Applier: per-parent backup, atomic
	/// write) → Finder's global defaults (GlobalApplier) → launch Finder → open its windows again → a moment to settle →
	/// re-read the home folders (`systemApplyWrite`). When only the home folders differ, the same quit → write → launch window is used without
	/// touching the domain. Nothing is written when Finder does not quit. Each step reports its own outcome: a failure
	/// after the folder step still says how many folders changed (that operation is recorded and undoable), and the
	/// status line never stays at "…중". `askRelaunch` only appears when folders changed but Finder did not come back.
	func confirmGlobalApply() {
		guard let pending = pendingGlobalApply else { return }
		pendingGlobalApply = nil
		// Writes exactly what the sheet showed: the analysed preset, and only while nothing it depends on has changed.
		guard planStamp.sameForSystem(as: pending.stamp) else {
			status = String(localized: "아무것도 바꾸지 않았습니다. 확인하는 동안 프리셋이나 선택이 바뀌었습니다. 다시 \"시스템 전체에 적용…\"을 누르세요.")
			errorMessage = status
			return
		}
		let preset = pending.preset
		beginWriting(quitsFinder: true)
		status = switch (pending.folderChanges > 0, !pending.globalDiffs.isEmpty) {
			case (true, true): String(localized: "Finder를 종료하고 홈 폴더와 Finder 기본 보기를 바꾸는 중… (Finder가 다시 시작됩니다)")
			case (true, false): String(localized: "Finder를 종료하고 홈 폴더를 바꾸는 중… (Finder가 다시 시작됩니다)")
			default: String(localized: "Finder를 종료하고 Finder 기본 보기를 바꾸는 중… (Finder가 다시 시작됩니다)")
		}
		let applier = Applier(operations: operationStore, globals: globals)
		let globalApplier = GlobalApplier(operations: operationStore, finder: RealFinderLifecycle())
		let folderRequest: ApplyRequest? = pending.plan.flatMap { plan in
			// Folders whose icon positions alone are reset are written too, also when no view changes.
			plan.changes.isEmpty && plan.iconPositionResets == 0 ? nil : ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings)
		}
		Task.detached(priority: .userInitiated) {
			let run = Self.systemApplyWrite(preset, writesDefaults: !pending.globalDiffs.isEmpty, folderRequest: folderRequest,
			                                applier: applier, globalApplier: globalApplier)
			let (folderOp, folderError, flowError) = (run.folderOp, run.folderError, run.flowError)
			let (relaunched, globalOpID, overwritten) = (run.relaunched, run.globalOpID, run.overwritten)
			let needsAttention = Self.systemApplyNeedsAttention(run)
			await MainActor.run {
				self.isWorking = false
				self.refreshGlobals()
				let summary = folderOp?.summary
				let relaunchNote: String = switch relaunched {
					case true?: " · " + String(localized: "Finder를 다시 시작했습니다.")
					case false?: " · " + String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")
					case nil: ""
				}
				if let flowError {
					let reason = ErrorText.describe(flowError)
					var parts = [String(localized: "중단: \(reason)")]
					var message = reason
					if let summary, folderOp != nil {
						if summary.changed > 0 || summary.positionsOnly == 0 {
							parts.append(String(localized: "홈 폴더 \(summary.changed)개는 이미 변경됨 (되돌리기: 툴바의 \"기록\")"))
							message = String(localized: "Finder 기본 보기는 바꾸지 못했습니다: \(message)\n\n홈 폴더 \(summary.changed)개는 이미 변경됐습니다. 되돌리려면 툴바의 \"기록\"에서 이 작업을 고르세요.")
						} else {
							// Only icon positions were written: "홈 폴더 0개는 이미 변경됨" would hide them, and they can be undone too.
							let positions = HistoryText.positionsOnlyFolders(summary.positionsOnly, undo: false)
							parts.append(String(localized: "이미 씀: \(positions) (되돌리기: 툴바의 \"기록\")"))
							message = String(localized: "Finder 기본 보기는 바꾸지 못했습니다: \(message)\n\n홈 폴더에는 이미 썼습니다(\(positions)). 되돌리려면 툴바의 \"기록\"에서 이 작업을 고르세요.")
						}
						if summary.changed > 0 && summary.positionsOnly > 0 {
							parts.append(HistoryText.positionsOnlyFolders(summary.positionsOnly, undo: false))
						}
					} else if folderRequest != nil {
						parts.append(String(localized: "홈 폴더는 바꾸지 않음"))
					}
					self.status = parts.joined(separator: " · ") + relaunchNote
					self.errorMessage = message
				} else {
					var parts = [!pending.writesGlobalDefaults ? String(localized: "Finder 기본 보기는 바꾸지 않음")
						: pending.globalDiffs.isEmpty ? String(localized: "Finder 기본 보기는 이미 동일")
						: String(localized: "Finder 기본 보기를 \"\(Fmt.name(preset.name))\"(으)로 변경")]
					if let summary {
						parts.append(String(localized: "\(summary.changed)개 폴더 변경") + (summary.failed > 0 ? String(localized: ", \(summary.failed)개 실패") : "")
							+ (overwritten > 0 ? String(localized: " (그중 \(overwritten)개는 Finder가 덮어씀 — 다시 적용하세요)") : ""))
						if summary.positionsOnly > 0 { parts.append(HistoryText.positionsOnlyFolders(summary.positionsOnly, undo: false)) }
					} else if !pending.roots.isEmpty {
						parts.append(folderRequest == nil ? String(localized: "홈 폴더는 이미 동일") : String(localized: "홈 폴더 변경 안 됨"))
					}
					self.status = String(localized: "완료: \(parts.joined(separator: " · "))") + relaunchNote
					if let folderError {
						self.errorMessage = String(localized: "홈 폴더에 적용하지 못했습니다: \(ErrorText.describe(folderError))\n일부 폴더는 이미 변경됐을 수 있습니다. 되돌리려면 툴바의 \"기록\"에서 이 작업을 고르세요.")
					}
				}
				// "되돌리기…" in the status line: Finder's defaults when they were written, else the home folders.
				// Folders whose icon positions alone changed count as written folders here: they are undone and shown anew too.
				let wroteFolders = summary.map { $0.changed + $0.positionsOnly > 0 } ?? false
				self.offerUndo(globalOpID ?? (wroteFolders ? folderOp?.id : nil))
				self.afterOperationRecorded()
				// Folders changed but Finder was not restarted by this flow (its own relaunch failed): offer it, unless
				// an error alert is already up — the status line then carries the instruction. That restart opens no
				// folders (the home folder and its standard folders), like this apply's own restart.
				if wroteFolders, relaunched != true, self.errorMessage == nil {
					self.askRelaunchFinder(after: .apply, operation: folderOp?.id, reopensFolders: false)
				}
				// Finder's windows, just opened again by the restart, are in front of the app: an error alert, a warning or
				// the question to restart comes forward over them. A clean apply leaves Finder in front.
				if needsAttention { FinderServiceProvider.shared.showWindow() }
			}
		}
	}

	/// The writes of "시스템 전체에 적용", off the main thread, in Finder's down time: with Finder's defaults to write
	/// (`writesDefaults`), `GlobalApplier.apply` reads the folders of Finder's windows, quits Finder, runs the home
	/// folders' write (`folderRequest`, Applier) while it is down, writes the defaults, launches Finder and opens those
	/// windows again (`FinderWindows`); with the home folders alone, the same window without the domain
	/// (`GlobalApplier.runWithFinderQuit`). Nothing is written when Finder does not quit.
	/// Once Finder is back, `GlobalApplier` gives it a moment to settle (`FinderLifecycle.settleAndCheck`: `launch`
	/// returns as soon as the process exists) and launches it once more if it went away meanwhile — on both paths, with
	/// or without the home folders — so `relaunched` is whether Finder runs after that. Then the home folders' stores are
	/// read back: the same wait as the quick preset, "지금 다시 시작" and `finder-presets apply
	/// --relaunch`, so what Finder writes as it starts is reported as overwritten. Like those, a Finder that did not come
	/// back is not waited for, but the stores are read back all the same. `globalApplier` carries the domain and Finder:
	/// `com.apple.finder` and the real Finder in the app, a throwaway domain and a fake in the tests.
	nonisolated static func systemApplyWrite(_ preset: Preset, writesDefaults: Bool, folderRequest: ApplyRequest?,
	                                         applier: Applier, globalApplier: GlobalApplier) -> SystemApplyRun {
		var run = SystemApplyRun()
		func applyFolders() {   // runs while Finder is quit; never throws so the global step can finish and report
			guard let folderRequest else { return }
			do { run.folderOp = try applier.apply(folderRequest) } catch { run.folderError = error }
		}
		if writesDefaults {
			do {
				// The home folders' record is named on the global one, so the history pairs them exactly (HistoryModel).
				let globalOp = try globalApplier.apply(preset.settings, presetName: preset.name, whileFinderIsQuit: applyFolders,
				                                       relatedOperation: { run.folderOp?.id })
				run.globalOpID = globalOp.id
				run.relaunched = globalOp.finderRelaunched
			} catch {
				run.flowError = error
				if case GlobalApplyError.verificationFailed(let id, _) = error { run.globalOpID = id }
				// GlobalApplier launches Finder again (and lets it settle) on its own failure paths after the quit — a
				// home folders' write or a read-back that differs shows the quit happened; before the quit nothing did.
				if run.folderOp != nil || run.globalOpID != nil { run.relaunched = globalApplier.finder.isRunning }
			}
		} else if folderRequest != nil {
			do { run.relaunched = try globalApplier.runWithFinderQuit(applyFolders).finderRelaunched } catch { run.flowError = error }
		}
		// Re-read the parent stores and report what Finder overwrote — once it is back (its windows opened
		// again by GlobalApplier) and has settled, or at once when it did not come back (nothing to wait for).
		if let op = run.folderOp { run.overwritten = applier.verify(op).count }
		return run
	}

	/// Anything but a clean "시스템 전체에 적용": the flow stopped, the home folders' write stopped or failed for some
	/// folders, Finder overwrote some of them, or Finder did not come back. `confirmGlobalApply` then brings the window
	/// forward over the Finder windows the restart opened again, so the alert or the warning on the status line is seen.
	nonisolated static func systemApplyNeedsAttention(_ run: SystemApplyRun) -> Bool {
		run.flowError != nil || run.folderError != nil || run.overwritten > 0 || run.relaunched == false
			|| (run.folderOp?.summary.failed ?? 0) > 0
	}
}

/// What the writes of "시스템 전체에 적용" did (`AppModel.systemApplyWrite`); `confirmGlobalApply` words it.
struct SystemApplyRun: Sendable {
	/// The home folders' `apply` record, when their write ran.
	var folderOp: FinderPresetsOperation?
	/// Why the home folders' write stopped (a manifest that could not be saved: some folders may be written).
	var folderError: (any Error)?
	/// Why the whole flow stopped: Finder did not quit, or Finder's defaults were not written or not read back as written.
	var flowError: (any Error)?
	/// Whether Finder runs again; nil when the flow never got as far as launching it.
	var relaunched: Bool?
	/// The `applyGlobal` record, when Finder's defaults were written (also when their read-back differed).
	var globalOpID: UUID?
	/// How many home folders no longer held what was written when they were read back: once Finder had been launched
	/// again and had a moment to settle, or at once when it did not come back.
	var overwritten = 0
}

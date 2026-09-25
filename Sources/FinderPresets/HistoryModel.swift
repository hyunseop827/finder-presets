import Foundation
import AppKit
import FinderPresetsCore

/// The operation an apply just recorded, and the status line that reported it (`AppModel.recentOperation`).
struct RecentOperation: Equatable {
	var id: UUID
	var status: String
}

/// An undo prepared for the history sheet's confirmation — nothing written yet. Folders: what `UndoService.preview`
/// found in each parent `.DS_Store`. Finder's defaults: the recorded snapshot and the current values (read only).
struct PendingUndo: Equatable {
	struct GlobalInfo: Equatable {
		/// Finder's defaults now.
		var current: ViewSettings
		/// What the undo writes back: the values recorded before the operation.
		var restored: ViewSettings
		var recordedAt: Date
		/// Finder's defaults already hold the recorded values: nothing to undo, Finder is left alone (like `finder-presets global-undo`).
		var alreadyRestored: Bool
	}

	var operation: FinderPresetsOperation
	var overview: OperationOverview
	/// Folder undo: the folders it puts back, the ones changed again after the operation (skipped, like `finder-presets undo`
	/// without `--force`), the ones already back to the state before (left alone), and the ones whose parent
	/// `.DS_Store` cannot be read now (their state is unknown; the undo records them as failed).
	var restorable: [String] = []
	var conflicts: [String] = []
	var alreadyRestored: [String] = []
	var unreadable: [String] = []
	/// How many of `restorable` get only their icon positions back (`EntryStatus.positionsOnly`): the confirmation names
	/// them apart, since no view settings are restored there.
	var restorablePositionsOnly = 0
	/// Set for an undo of Finder's global defaults (`applyGlobal`).
	var global: GlobalInfo?
	/// The other record of the same "시스템 전체에 적용" (home folders ↔ Finder's defaults); it is undone on its own.
	var related: OperationOverview?

	var isGlobal: Bool { global != nil }
	/// Nothing is left to put back and nothing stands in the way: every folder is already as before (none conflicts or
	/// cannot be read), or Finder's defaults already hold the recorded values. Confirming writes nothing (Finder is left
	/// alone) and records the operation as undone, so it is no longer offered — like `finder-presets undo` / `finder-presets global-undo`.
	var recordsOnly: Bool {
		global.map(\.alreadyRestored) ?? (restorable.isEmpty && !alreadyRestored.isEmpty && conflicts.isEmpty && unreadable.isEmpty)
	}
	/// False when confirming would do nothing at all: no folder to put back, and conflicts or unreadable folders keep the
	/// operation from counting as undone.
	var canConfirm: Bool { isGlobal || !restorable.isEmpty || recordsOnly }
}

/// What an undo started from the history sheet did (`UndoService.undo` / `GlobalApplier.undo`).
struct UndoOutcome: Equatable {
	var operationID: UUID
	var isGlobal: Bool
	/// The undo's own record, when one was written.
	var undoOperationID: UUID?
	var restored: [String] = []
	var conflicts: [String] = []
	var alreadyRestored: [String] = []
	var failed: [String] = []
	/// Global undo: whether Finder came back (nil when Finder was left alone).
	var finderRelaunched: Bool?
	/// Everything was already as before: nothing was written (Finder left alone), the operation is recorded as undone.
	var recordedOnly = false
	/// Why the undo stopped; the lists above still say what was done before that.
	var error: String?

	var succeeded: Bool { error == nil && failed.isEmpty && finderRelaunched != false }
	/// The status line's text (also the result's summary).
	var message: String { HistoryText.outcomeMessage(self) }
}

/// What the history sheet shows about the selected record beyond its row: the preset it applied (drawn as the editor's
/// preview) and the folders it changed. Read from that one manifest only (`AppModel.loadHistoryDetails`), because the
/// list holds overviews, which carry neither.
struct HistoryDetails: Equatable, Sendable {
	/// How many skipped or failed folders the counts line's tooltip names.
	static let problemLimit = 20

	var id: UUID
	/// The values the operation applied; nil for an undo record and for an apply of several presets at once.
	var preset: ViewSettings?
	var folders: ChangedFolders
	/// The first folders it skipped and the first it could not write (the counts line's tooltip).
	var skipped: [String] = []
	var failed: [String] = []

	init(_ op: FinderPresetsOperation) {
		id = op.id
		preset = op.presetSnapshot
		folders = ChangedFolders(op)
		skipped = op.entries.filter { $0.status == .skippedMatching || $0.status == .skippedConflict }
			.prefix(Self.problemLimit).map(\.folderPath)
		failed = op.entries.filter { $0.status == .failed }.prefix(Self.problemLimit).map(\.folderPath)
	}
}

/// What "지우기…" (the selected record) or "기록 모두 지우기…" asks about before anything is removed. Deleting a record
/// removes its manifest and its backups, so it can no longer be undone; the view settings it wrote are left as they are.
struct HistoryDeletion: Equatable {
	/// What the confirmation names: the one record, the records chosen in the list, or every record in it.
	enum Scope: Equatable {
		case one(OperationOverview)
		case chosen
		case all
	}

	/// The records to delete, newest first — never one still being written.
	var ids: [UUID]
	var scope: Scope
	/// Records left out because they are still being written.
	var inProgress = 0

	/// "지우기…" for the records chosen in the list (one, or several with ⇧/⌘-click), or nil when none of them can be
	/// deleted. A record still being written is left out and counted.
	static func chosen(_ ids: Set<UUID>, in items: [OperationOverview]) -> HistoryDeletion? {
		let picked = items.filter { ids.contains($0.id) }
		let deletable = picked.filter { !$0.inProgress }
		guard let first = deletable.first else { return nil }
		let scope: Scope = picked.count == 1 ? .one(first) : .chosen
		return HistoryDeletion(ids: deletable.map(\.id), scope: scope, inProgress: picked.count - deletable.count)
	}

	/// "기록 모두 지우기…": every record in the list but the ones still being written, or nil when that leaves nothing.
	/// Records whose manifest could not be read are not in the list and are left alone, as the automatic cleanup leaves them.
	static func all(_ items: [OperationOverview]) -> HistoryDeletion? {
		let ids = items.filter { !$0.inProgress }.map(\.id)
		guard !ids.isEmpty else { return nil }
		return HistoryDeletion(ids: ids, scope: .all, inProgress: items.count - ids.count)
	}
}

/// Where the history sheet is: the list, an undo being prepared, its confirmation, the undo running, its result.
enum UndoPhase: Equatable {
	case idle
	case preparing(UUID)
	case confirm(PendingUndo)
	case running(PendingUndo)
	case result(UndoOutcome)
}

/// Why the app does not undo an operation.
enum UndoRefusal: Error, Equatable {
	case notFound
	case alreadyUndone
	case nothingToUndo
	/// An undo record (`undo`, `undoGlobal`) is never offered; `finder-presets undo <its ID>` still redoes it.
	case isUndoRecord
	case inProgress
	/// The record changed since the confirmation was shown (undone or rewritten elsewhere, e.g. by `finder-presets`).
	case changed
	/// Finder's defaults changed since a confirmation that promised to leave Finder alone (they held the recorded values).
	case globalChanged
	case unreadable(String)

	var message: String {
		switch self {
		case .notFound: String(localized: "이 작업의 기록이 없습니다(이미 정리됐을 수 있습니다).")
		case .alreadyUndone: String(localized: "이미 되돌린 작업입니다.")
		case .nothingToUndo: String(localized: "되돌릴 것이 없습니다(바뀐 폴더나 기록한 값이 없습니다).")
		case .isUndoRecord: String(localized: "되돌리기 기록은 여기서 다시 되돌리지 않습니다.")
		case .inProgress: String(localized: "아직 기록하는 중인 작업입니다(이 앱이나 finder-presets가 쓰는 중). 끝난 뒤에 되돌리세요.")
		case .changed: String(localized: "확인하는 동안 기록이 바뀌어 되돌리지 않았습니다. 목록을 다시 확인하세요.")
		case .globalChanged: String(localized: "확인한 뒤에 Finder 기본 보기가 바뀌어 아무것도 하지 않았습니다. 다시 확인하세요.")
		case .unreadable(let detail): String(localized: "기록을 읽지 못했습니다: \(detail)")
		}
	}
}

extension AppModel {
	// MARK: History sheet ("기록")

	/// "기록" in the toolbar, and the status line's "되돌리기…": opens the sheet, reads the records in the background,
	/// selects `id` (else the newest when records were added since the sheet last listed them, else keeps the selection,
	/// else the newest: `chosenHistoryRecords`) and, with `startUndo`, prepares its undo — the confirmation only, nothing is
	/// written before "되돌리기".
	func openHistory(select id: UUID? = nil, startUndo: Bool = false) {
		if case .running = undoPhase {} else { undoPhase = .idle }
		historyNotice = nil
		if let id { historySelection = id }
		historyShownBefore = id == nil ? Set(historyItems.map(\.id)) : nil
		showHistory = true
		Task {
			await loadHistory()
			if startUndo, let id, historyItems.contains(where: { $0.id == id }) { prepareUndo(id) }
		}
	}

	/// "닫기" (or Esc). A confirmation still open is dropped (nothing was written); an undo already running goes on and
	/// reports on the status line.
	func closeHistory() {
		showHistory = false
		historyNotice = nil
		pendingHistoryDelete = nil
		if case .running = undoPhase { return }
		undoPhase = .idle
	}

	/// Reads every record in the background (the manifests can be large). The newest call wins; it also uses what the sheet
	/// listed before it was opened again (`historyShownBefore`), when that was set before the call.
	func loadHistory() async {
		historyGeneration &+= 1
		let generation = historyGeneration
		let shownBefore = historyShownBefore
		historyLoading = true
		let store = operationStore
		let result: Result<(OperationHistory, [String]), any Error> = await Task.detached(priority: .userInitiated) {
			do {
				let listing = try store.listReadable()
				return .success((OperationHistory(listing.operations), listing.unreadable))
			} catch {
				return .failure(error)
			}
		}.value
		guard generation == historyGeneration else { return }
		if shownBefore != nil { historyShownBefore = nil }
		historyLoading = false
		switch result {
		case .success(let (history, unreadable)):
			historyItems = history.overviews
			historyUnreadable = unreadable
			historyPairs = Self.systemPairs(history.operations)
			let chosen = Self.chosenHistoryRecords(historySelected, in: historyItems.map(\.id), shownBefore: shownBefore)
			if chosen != historySelected { historySelected = chosen }
			// The status line's shortcut only while its operation can still be undone.
			if let recent = recentOperation, historyItems.first(where: { $0.id == recent.id })?.canUndo != true { recentOperation = nil }
		case .failure(let error):
			historyNotice = String(localized: "기록을 읽지 못했습니다: \(ErrorText.describe(error))")
		}
	}

	/// The records chosen once the list is read (`listed`, newest first): those still listed — a reload while the sheet is
	/// open keeps the choice —, else the newest. `shownBefore`: what the sheet listed before it was opened again without a
	/// record to select; a record listed now that it did not show (an apply, an undo or the quick preset since) chooses the
	/// newest, so "되돌리기" is never offered for an older operation chosen before.
	nonisolated static func chosenHistoryRecords(_ selected: Set<UUID>, in listed: [UUID], shownBefore: Set<UUID>? = nil) -> Set<UUID> {
		let newest = Set(listed.prefix(1))
		if let shownBefore, listed.contains(where: { !shownBefore.contains($0) }) { return newest }
		let kept = selected.intersection(listed)
		return kept.isEmpty ? newest : kept
	}

	var selectedHistoryItem: OperationOverview? { historyItems.first { $0.id == historySelection } }

	/// The selected record's preset and folders, read in the background from its manifest alone — never for the whole
	/// list, whose manifests can be large. The newest call wins. `historyDetails` stays nil while the manifest is read and
	/// when it cannot be read; the two are told apart by `historyDetailsUnreadable`, so a record whose file went away
	/// (`finder-presets`, the automatic cleanup, an I/O error) says so instead of looking as if it were still loading.
	func loadHistoryDetails(_ id: UUID?) async {
		historyDetailsGeneration &+= 1
		let generation = historyDetailsGeneration
		historyDetails = nil
		historyDetailsUnreadable = nil
		guard let id else { return }
		let store = operationStore
		let details = await Task.detached(priority: .userInitiated) { (try? store.load(id: id)).map(HistoryDetails.init) }.value
		guard generation == historyDetailsGeneration else { return }
		historyDetails = details
		historyDetailsUnreadable = details == nil ? id : nil
	}

	/// The overview of the other record of the same "시스템 전체에 적용", when it is listed.
	func relatedHistoryItem(_ id: UUID) -> OperationOverview? {
		historyPairs[id].flatMap { other in historyItems.first { $0.id == other } }
	}

	/// The two records one "시스템 전체에 적용" leaves, paired both ways. The `applyGlobal` record names the home folders'
	/// `apply` (`relatedOperationID`, saved before Finder's defaults are written). Records written before that was saved are
	/// paired by time: the home folders are written while Finder is quit, i.e. after the `applyGlobal` record was started
	/// and before it finished, with the same preset — and only an `apply` written before `recordCodes` existed (the same
	/// older version) can be such a partner, so an unrelated later apply is never paired with an older unfinished one.
	nonisolated static func systemPairs(_ operations: [FinderPresetsOperation]) -> [UUID: UUID] {
		var pairs: [UUID: UUID] = [:]
		let ids = Set(operations.map(\.id))
		for g in operations where g.kind == .applyGlobal {
			guard let related = g.relatedOperationID else { continue }
			if ids.contains(related), pairs[related] == nil {
				pairs[g.id] = related
				pairs[related] = g.id
			}
		}
		for g in operations where g.kind == .applyGlobal && g.relatedOperationID == nil && pairs[g.id] == nil {
			let end = g.finishedAt ?? g.startedAt.addingTimeInterval(600)
			let folders = operations.filter {
				$0.kind == .apply && $0.recordCodes == nil && pairs[$0.id] == nil && $0.presetName == g.presetName
					&& $0.startedAt >= g.startedAt && $0.startedAt <= end
			}
			if let f = folders.min(by: { $0.startedAt < $1.startedAt }) {
				pairs[g.id] = f.id
				pairs[f.id] = g.id
			}
		}
		return pairs
	}

	// MARK: Undo

	/// "되돌리기…": reads the record and what undoing it would do (in the background, nothing written) and shows the
	/// confirmation. Refused while another task runs, and for anything `OperationHistory` does not offer.
	func prepareUndo(_ id: UUID) {
		switch undoPhase {
		case .preparing, .running: return
		default: break
		}
		guard !isWorking else {
			historyNotice = String(localized: "다른 작업이 끝난 뒤에 되돌리세요.")
			return
		}
		historyNotice = nil
		if historySelection != id { historySelection = id }
		undoPhase = .preparing(id)
		let store = operationStore
		Task {
			let result = await Task.detached(priority: .userInitiated) { Self.makePendingUndo(id, store: store) }.value
			guard self.undoPhase == .preparing(id) else { return }   // closed or replaced meanwhile
			switch result {
			case .success(let pending):
				self.undoPhase = .confirm(pending)
			case .failure(let refusal):
				self.undoPhase = .idle
				self.historyNotice = refusal.message
			}
		}
	}

	/// The confirmation's contents, read from disk now (the list may be older). `domain`: where Finder's defaults are read
	/// (tests pass a throwaway domain; the app always reads `com.apple.finder`, read only).
	nonisolated static func makePendingUndo(_ id: UUID, store: OperationStore, now: Date = Date(),
	                                        domain: String = GlobalDefaultsWriter.finderDomain) -> Result<PendingUndo, UndoRefusal> {
		let history: OperationHistory
		do { history = try OperationHistory(store: store, now: now) } catch { return .failure(.unreadable(ErrorText.describe(error))) }
		guard let op = history.operation(id) else { return .failure(.notFound) }
		if let refusal = refusal(op, in: history, now: now) { return .failure(refusal) }
		var pending = PendingUndo(operation: op, overview: history.overview(of: op),
		                          related: systemPairs(history.operations)[op.id].flatMap(history.operation).map(history.overview(of:)))
		if op.kind.isGlobal {
			guard let file = op.globalSnapshotFile else { return .failure(.nothingToUndo) }
			let recorded: GlobalSnapshot
			do { recorded = try store.loadGlobalSnapshot(file, for: op) } catch { return .failure(.unreadable(ErrorText.describe(error))) }
			let current = GlobalDefaultsWriter.snapshot(domain: domain)   // read only
			pending.global = PendingUndo.GlobalInfo(current: current.decodedSettings, restored: recorded.decodedSettings,
			                                        recordedAt: recorded.takenAt, alreadyRestored: current.hasSameValues(as: recorded))
		} else {
			let preview = UndoService(operations: store).preview(op)
			pending.restorable = preview.restorable.map(\.folderPath)
			let positionsOnly = Set(op.entries.filter { $0.status == .positionsOnly }.map(\.folderPath))
			pending.restorablePositionsOnly = pending.restorable.filter(positionsOnly.contains).count
			pending.conflicts = preview.conflicts.map(\.folderPath)
			pending.alreadyRestored = preview.alreadyRestored.map(\.folderPath)
			pending.unreadable = preview.unreadable.map(\.folderPath)
		}
		return .success(pending)
	}

	/// Why the app does not undo `op`, or nil: the same verdict as `finder-presets undo last` / `global-undo last`
	/// (`OperationHistory.isUndoable`), and never an operation that is still being written (`FinderPresetsOperation.isInProgress`:
	/// an unfinished one whose writer returned, threw or is gone is a leftover and can be undone at once).
	nonisolated static func refusal(_ op: FinderPresetsOperation, in history: OperationHistory, now: Date) -> UndoRefusal? {
		if op.kind.isUndo { return .isUndoRecord }
		switch history.status(of: op) {
		case .undone: return .alreadyUndone
		case .nothingToUndo: return .nothingToUndo
		case .undoable: break
		}
		return op.isInProgress(now: now) ? .inProgress : nil
	}

	func cancelUndo() {
		switch undoPhase {
		case .preparing, .confirm: undoPhase = .idle
		default: break
		}
	}

	/// "목록으로" after an undo.
	func closeUndoResult() {
		if case .result = undoPhase { undoPhase = .idle }
	}

	/// "되돌리기" in the confirmation. Folders: `UndoService.undo` (record-level restore, conflicts skipped, recorded as an
	/// `undo` operation), then "Finder를 다시 시작할까요?" like after an apply. Finder's defaults: `GlobalApplier.undo`,
	/// which quits Finder, writes the recorded values and launches Finder again — or, when they are already there, records
	/// the undo without touching Finder. The record is read again first: when it changed since the confirmation (undone or
	/// rewritten elsewhere), nothing is written.
	func confirmUndo() {
		guard case .confirm(let pending) = undoPhase, pending.canConfirm, !isWorking else { return }
		#if DEBUG
		// The development hooks never restart Finder: they prepare a global undo, they never carry it out.
		if pending.isGlobal && (SelfTest.isRequested || LayoutProbe.isRequested) {
			undoPhase = .idle
			historyNotice = String(localized: "셀프테스트와 레이아웃 점검은 Finder 기본 보기를 되돌리지 않습니다.")
			return
		}
		#endif
		undoPhase = .running(pending)
		beginWriting(quitsFinder: pending.isGlobal)
		status = pending.isGlobal
			? String(localized: "Finder를 종료하고 Finder 기본 보기를 되돌리는 중… (Finder가 다시 시작됩니다)")
			: String(localized: "되돌리는 중…")
		let store = operationStore
		Task {
			let outcome = await Task.detached(priority: .userInitiated) { Self.runUndo(pending, store: store) }.value
			self.finishUndo(outcome)
		}
	}

	/// `domain` and `finder`: Finder's defaults and Finder itself (tests pass a throwaway domain and a fake Finder).
	nonisolated static func runUndo(_ pending: PendingUndo, store: OperationStore, domain: String = GlobalDefaultsWriter.finderDomain,
	                                finder: any FinderLifecycle = RealFinderLifecycle()) -> UndoOutcome {
		var outcome = UndoOutcome(operationID: pending.operation.id, isGlobal: pending.isGlobal)
		let history: OperationHistory
		do { history = try OperationHistory(store: store) } catch {
			outcome.error = UndoRefusal.unreadable(ErrorText.describe(error)).message
			return outcome
		}
		guard let op = history.operation(pending.operation.id) else {
			outcome.error = UndoRefusal.notFound.message
			return outcome
		}
		if let refusal = refusal(op, in: history, now: Date()) {
			outcome.error = refusal.message
			return outcome
		}
		// Pinning (here or with `finder-presets pin`) is the only change that does not matter.
		var now = op, then = pending.operation
		now.pinned = false
		then.pinned = false
		guard now == then else {
			outcome.error = UndoRefusal.changed.message
			return outcome
		}
		if op.kind.isGlobal {
			do {
				guard let file = op.globalSnapshotFile else { throw UndoRefusal.nothingToUndo }
				let recorded = try store.loadGlobalSnapshot(file, for: op)
				// A confirmation that promised to leave Finder alone never restarts it: the values changed since, so stop.
				if pending.recordsOnly, !GlobalDefaultsWriter.snapshot(domain: domain).hasSameValues(as: recorded) {
					outcome.error = UndoRefusal.globalChanged.message
					return outcome
				}
				// Already the recorded values (also when they became so after the confirmation): recorded, Finder left alone.
				// A confirmation that promised to leave Finder alone never lets GlobalApplier quit it (`leaveFinderAlone`).
				let undoOp = try GlobalApplier(operations: store, domain: domain, finder: finder).undo(op, leaveFinderAlone: pending.recordsOnly)
				outcome.undoOperationID = undoOp.id
				if OperationHistory.foundAlreadyRestored(undoOp) {
					outcome.recordedOnly = true
				} else {
					outcome.finderRelaunched = undoOp.finderRelaunched
				}
			} catch {
				outcome.error = HistoryText.describe(error)
				if case GlobalApplyError.verificationFailed(let id, _) = error { outcome.undoOperationID = id }
				// Every failure after the quit launches Finder again; say so when it is still not running.
				if !finder.isRunning { outcome.finderRelaunched = false }
			}
		} else {
			do {
				let undoOp = try UndoService(operations: store).undo(op)
				outcome.undoOperationID = undoOp.id
				outcome.recordedOnly = OperationHistory.foundAlreadyRestored(undoOp)
				for e in undoOp.entries {
					switch e.status {
					case .changed, .positionsOnly: outcome.restored.append(e.folderPath)
					case .skippedConflict: outcome.conflicts.append(e.folderPath)
					case .skippedMatching: outcome.alreadyRestored.append(e.folderPath)
					case .failed: outcome.failed.append(e.folderPath)
					}
				}
			} catch {
				// UndoService writes a parent store before it records it: a failed save can leave folders already put back.
				outcome.error = HistoryText.describe(error)
					+ String(localized: " (일부 폴더는 이미 되돌려졌을 수 있습니다. 기록을 다시 확인하세요)")
			}
		}
		return outcome
	}

	private func finishUndo(_ outcome: UndoOutcome) {
		isWorking = false
		undoPhase = .result(outcome)
		status = outcome.message
		if recentOperation?.id == outcome.operationID { recentOperation = nil }
		if outcome.isGlobal { refreshGlobals() }
		// A Finder default undo restarts Finder and opens its windows again, in front of the app: when it did not end
		// well, the sheet with the reason comes forward over them. A clean undo leaves Finder in front.
		if outcome.isGlobal && !outcome.succeeded { FinderServiceProvider.shared.showWindow() }
		// Like after an apply: folders Finder has already shown need a Finder restart. Asked in the sheet while it is open.
		// "지금 다시 시작" writes again what Finder overwrites of this undo as it quits and then opens its folders
		// (`relaunchFinder`; none for the undo of "시스템 전체에 적용"'s home folders, `FolderReopen.choose`).
		if !outcome.isGlobal && !outcome.restored.isEmpty {
			if showHistory {
				relaunchOperationID = outcome.undoOperationID
				relaunchReopensFolders = true
				askRelaunchAfterUndo = true
			} else {
				askRelaunchFinder(after: .undo, operation: outcome.undoOperationID)
			}
		}
		afterOperationRecorded()
	}

	// MARK: Pin, backups

	/// "고정" / "고정 해제": the automatic cleanup never removes a pinned record (`OperationStore.setPinned`, which
	/// rewrites only the manifest's `pinned` key and refuses an operation still in progress). Returns true on success.
	@discardableResult
	func setPinned(_ id: UUID, pinned: Bool) async -> Bool {
		historyNotice = nil
		let store = operationStore
		let result: Result<FinderPresetsOperation, any Error> = await Task.detached(priority: .userInitiated) {
			do { return .success(try store.setPinned(id: id, pinned: pinned)) } catch { return .failure(error) }
		}.value
		if case .failure(let error) = result { historyNotice = HistoryText.describe(error) }
		await loadHistory()
		if case .success = result { return true }
		return false
	}

	/// "백업 폴더 보기": the selected operation's folder (manifest.json, backups/, global-before.json) in Finder, or
	/// the `operations` folder when none is selected or its folder is gone.
	func revealBackups(_ id: UUID?) {
		var folder = dirs.operations
		if let id {
			let dir = operationStore.directory(for: id)
			if FileManager.default.fileExists(atPath: dir.path) { folder = dir }
		}
		if !NSWorkspace.shared.open(folder) {
			historyNotice = String(localized: "Finder에서 열지 못했습니다: \(Fmt.abbreviate(folder.path))")
		}
	}

	// MARK: Delete records ("지우기")

	/// "지우기…" (the chosen records, also ⌫ in the list) and "기록 모두 지우기…": the confirmation only — nothing is
	/// removed before `confirmDeleteHistory`.
	func askDeleteHistory(_ ids: Set<UUID>) {
		historyNotice = nil
		pendingHistoryDelete = HistoryDeletion.chosen(ids, in: historyItems)
	}

	func askDeleteAllHistory() {
		historyNotice = nil
		pendingHistoryDelete = HistoryDeletion.all(historyItems)
	}

	/// "지우기" in the confirmation: deletes each record's folder — its manifest, its backups and its global snapshot
	/// (`OperationStore.delete`) — in the background, then reads the list again. A record that is being written when the
	/// delete runs is left alone (its writer would save it again). Nothing in Finder is changed: the folders keep the view
	/// settings the operation wrote, and a deleted record can no longer be undone.
	func confirmDeleteHistory() {
		guard let deletion = pendingHistoryDelete else { return }
		pendingHistoryDelete = nil
		let ids = deletion.ids
		let store = operationStore
		Task {
			let result = await Task.detached(priority: .userInitiated) { Self.deleteRecords(ids, store: store) }.value
			await self.loadHistory()
			if let failed = result.failed {
				self.historyNotice = String(localized: "기록을 지우지 못했습니다: \(failed)")
			} else if result.kept > 0 {
				self.historyNotice = String(localized: "기록하는 중인 작업은 지우지 않았습니다.")
			}
		}
	}

	/// Deletes each record's folder, and reports how many were left alone because they are being written and the first
	/// failure. Runs in the background; it reads each manifest again, so a record that started being written since the
	/// confirmation is kept.
	nonisolated static func deleteRecords(_ ids: [UUID], store: OperationStore, now: Date = Date()) -> (kept: Int, failed: String?) {
		var kept = 0
		var failed: String?
		for id in ids {
			if let op = try? store.load(id: id), op.isInProgress(now: now) {
				kept += 1
				continue
			}
			do { try store.delete(id: id) } catch { failed = failed ?? HistoryText.describe(error) }
		}
		return (kept, failed)
	}

	// MARK: Status line shortcut, cleanup

	/// Offers "되돌리기…" in the status line for `id` while the line just set is shown (nil: no shortcut).
	func offerUndo(_ id: UUID?) {
		recentOperation = id.map { RecentOperation(id: $0, status: status) }
	}

	/// The operation the status line's "되돌리기…" undoes, while the line that reported it is still shown.
	var undoShortcutID: UUID? {
		guard let recent = recentOperation, recent.status == status else { return nil }
		return recent.id
	}

	/// After an apply, a whole-system apply or an undo recorded an operation: the automatic cleanup, then the list.
	func afterOperationRecorded() {
		Task {
			await runRetention()
			if showHistory { await loadHistory() }
		}
	}

	/// A record changed outside the sheet's own calls — "지금 다시 시작" wrote folders again and saved the record with a
	/// new backup and the `after` read back (`relaunchFinder`), or found it deleted: while the history sheet is open it
	/// reads the list again, and the details of `id` when that is the record selected, so the sheet never goes on showing
	/// the record as it was read before. Nothing is read while the sheet is closed (it reads everything when it opens).
	func reloadHistoryIfShown(changed id: UUID?) {
		guard showHistory else { return }
		Task {
			await loadHistory()
			if let id, showHistory, historySelection == id { await loadHistoryDetails(id) }
		}
	}

	/// At launch, once (FinderPresetsApp; not for the self-test or the layout probe).
	func runLaunchRetentionOnce() {
		guard !launchRetentionStarted else { return }
		launchRetentionStarted = true
		Task { await runRetention() }
	}

	/// Removes the records and backups over `policy` in the background (`OperationStore.applyRetention`: pinned ones,
	/// ones in progress, the newest undoable folder and global operations and the undos of kept ones stay; unreadable
	/// manifests are never touched). A failure only adds a note to the status line.
	@discardableResult
	func runRetention(policy: RetentionPolicy = .standard) async -> RetentionResult? {
		retentionRuns += 1
		let store = operationStore
		let result: Result<RetentionResult, any Error> = await Task.detached(priority: .utility) {
			do { return .success(try store.applyRetention(policy: policy)) } catch { return .failure(error) }
		}.value
		switch result {
		case .success(let r):
			retentionRemoved += r.removed.count
			if let first = r.failed.first {
				appendStatusNote(String(localized: "오래된 기록 \(r.failed.count)개 정리 실패: \(first.message)"))
			}
			return r
		case .failure(let error):
			appendStatusNote(String(localized: "오래된 기록 정리 실패: \(ErrorText.describe(error))"))
			return nil
		}
	}

	private func appendStatusNote(_ note: String) {
		let shortcut = undoShortcutID
		status = status.isEmpty ? note : status + " · " + note
		if let shortcut { offerUndo(shortcut) }   // still the same report, with the note
	}
}

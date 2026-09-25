import Foundation
import Testing
import FinderPresetsCore
import DSStore
@testable import FinderPresets

/// The history sheet's model outside the UI: what an undo prepares and does on a real temporary tree (the same static
/// functions the sheet runs in the background), the refusals, the "시스템 전체에 적용" pairs, and the texts that decide
/// the status line's tone. Finder and its defaults are never touched: the global undo runs against a throwaway
/// preferences domain (never com.apple.finder) and a fake Finder.
@MainActor @Suite struct HistoryModelTests {
	/// A throwaway preferences domain (a path under the temporary folder), never com.apple.finder.
	struct TestDomain {
		let directory: URL
		let name: String

		init() {
			directory = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-prefs-\(UUID().uuidString)")
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			name = directory.appendingPathComponent("com.hyunseop.finder-presets.test-\(UUID().uuidString)").path
			precondition(name != GlobalDefaultsWriter.finderDomain && !name.contains("com.apple.finder"))
		}

		func style() -> String? { GlobalDefaultsWriter.readViewStyle(domain: name) }

		func cleanup() {
			precondition(URL(fileURLWithPath: name).lastPathComponent.hasPrefix("com.hyunseop.finder-presets.test-"))
			for key in [GlobalDefaultsWriter.viewStyleKey, GlobalDefaultsWriter.standardViewSettingsKey] {
				CFPreferencesSetAppValue(key as CFString, nil, name as CFString)
			}
			CFPreferencesAppSynchronize(name as CFString)
			try? FileManager.default.removeItem(at: directory)
		}
	}

	/// Records every lifecycle call (and what a test adds with `note`); `quitSucceeds` false keeps "Finder" running,
	/// `launchSucceeds` false leaves it down. `onQuit` runs at each quit that succeeds (Finder writing what it holds in
	/// memory as it quits), `onLaunch` at each launch, `onSettle` while the caller waits for a launched Finder to settle
	/// (Finder writing as it starts; the real one waits `RealFinderLifecycle.settleTime`, this one not at all).
	///
	/// Finder's windows (`FinderWindows`): with `windows` set, `openWindowFolders` answers them and records "windows";
	/// `reopen` records "reopen A,B" (the folders' names in the order asked) and opens them all (`reopened` keeps each
	/// list). Without `windows` the fake has none and records nothing about them, as the fakes before it did.
	final class FakeFinder: FinderLifecycle, @unchecked Sendable {
		var quitSucceeds = true
		var launchSucceeds = true
		var onQuit: (() -> Void)?
		var onLaunch: (() -> Void)?
		var onSettle: (() -> Void)?
		var windows: [URL]?
		private(set) var reopened: [[URL]] = []
		private(set) var events: [String] = []
		private var running = true
		var isRunning: Bool { running }
		func quit() -> Bool {
			events.append("quit")
			guard quitSucceeds else { return false }
			onQuit?()
			running = false
			return true
		}
		func launch() -> Bool { events.append("launch"); onLaunch?(); running = launchSucceeds; return launchSucceeds }
		func settle() { events.append("settle"); onSettle?() }
		func openWindowFolders() -> [URL] {
			guard let windows else { return [] }
			events.append("windows")
			return windows
		}
		func reopen(_ folders: [URL]) -> [URL] {
			reopened.append(folders)
			events.append("reopen " + folders.map(\.lastPathComponent).joined(separator: ","))
			return folders
		}
		/// Finder going away by itself (e.g. while it settles): recorded as "crash".
		func crash() { events.append("crash"); running = false }
		func note(_ event: String) { events.append(event) }
	}
	struct Env {
		let base: URL
		let root: URL
		let store: OperationStore
		let globals = GlobalDefaults.factory
		func cleanUp() { try? FileManager.default.removeItem(at: base) }
	}

	static func makeEnv() throws -> Env {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-history-model-\(UUID().uuidString)")
		let root = base.appendingPathComponent("Root")
		for name in ["A", "B"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		return Env(base: base, root: root, store: OperationStore(dirs: AppDirectories(root: base.appendingPathComponent("AppData"))))
	}

	/// Applies `preset` to `folders` (each on its own, no subfolders) the way the app does, and returns the record.
	static func apply(_ preset: Preset, to folders: [URL], env: Env) throws -> FinderPresetsOperation {
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		let scanned = FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: folders)
		return try Applier(operations: env.store, globals: env.globals)
			.apply(ApplyRequest(plan: planner.plan(scanned: scanned, roots: folders), presetName: preset.name, presetSnapshot: preset.settings))
	}

	static func explicit(_ folder: URL, env: Env) throws -> ViewSettings? {
		let state = try Planner.readState(at: ParentStoreLocator.locate(folder), globals: env.globals)
		return state.hasExplicitRecords ? state.explicit : nil
	}

	@Test func folderUndoPreparesSkipsConflictsAndRestores() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let icon = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 72)))
		let list = Preset(name: "List", settings: ViewSettings(viewStyle: .list))
		let op = try Self.apply(icon, to: [a, b], env: env)
		#expect(op.summary.changed == 2)

		// Prepared: both folders can be undone, nothing is written.
		guard case .success(let pending) = AppModel.makePendingUndo(op.id, store: env.store) else { Issue.record("not prepared"); return }
		func names(_ paths: [String]) -> [String] { paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() }
		#expect(names(pending.restorable) == ["A", "B"] && pending.conflicts.isEmpty && pending.alreadyRestored.isEmpty)
		#expect(!pending.isGlobal && pending.canConfirm && pending.related == nil)
		#expect(pending.overview.id == op.id && pending.overview.canUndo)
		#expect(try Self.explicit(a, env: env)?.icon.iconSize == 72)

		// B changes again after the apply: prepared again, it is a conflict; the undo skips it and keeps the later change.
		_ = try Self.apply(list, to: [b], env: env)
		guard case .success(let again) = AppModel.makePendingUndo(op.id, store: env.store) else { Issue.record("not prepared again"); return }
		#expect(names(again.restorable) == ["A"] && names(again.conflicts) == ["B"])
		let outcome = AppModel.runUndo(again, store: env.store)
		#expect(outcome.error == nil && names(outcome.restored) == ["A"] && names(outcome.conflicts) == ["B"] && outcome.failed.isEmpty)
		#expect(outcome.undoOperationID != nil && !outcome.isGlobal && outcome.succeeded)
		#expect(try Self.explicit(a, env: env) == nil)                      // A had no records of its own before
		#expect(try Self.explicit(b, env: env)?.viewStyle == .list)         // B keeps the later change
		#expect(StatusBar.tone(status: outcome.message, working: false) == .warning)   // a skipped conflict is worth a look

		// Now undone: refused, and the undo record itself is never offered.
		#expect(AppModel.makePendingUndo(op.id, store: env.store) == .failure(.alreadyUndone))
		let undoID = try #require(outcome.undoOperationID)
		#expect(AppModel.makePendingUndo(undoID, store: env.store) == .failure(.isUndoRecord))
		#expect(AppModel.makePendingUndo(UUID(), store: env.store) == .failure(.notFound))
		let history = try OperationHistory(store: env.store)
		#expect(history.status(of: try #require(history.operation(op.id))) == .undone(by: undoID))
	}

	/// A record whose only change is icon positions (a system-wide apply's home folder that follows Finder's new default,
	/// `EntryStatus.positionsOnly`): its row, heading and paired-record note name the positions, its undo confirmation
	/// offers them as positions (not view settings) and can be confirmed, and the undo reports the folder as restored.
	@Test func positionsOnlyRecordTextsAndUndo() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		var positions = DSStore()
		try positions.setIconPosition(for: "A", x: 107, y: 102)
		try StoreEditor.write(positions, to: env.root.appendingPathComponent(".DS_Store"))
		let big = Preset(name: "Big", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 164)))
		let after = big.settings.globalDefaultsPart.filling(from: env.globals.effectiveSettings)
		let planner = Planner(presets: [big], resolver: RuleResolver(rules: [], defaultPresetID: big.id), globals: env.globals,
		                      options: PlanOptions(ownSettingsOnly: true, defaultsAfterApply: after))
		let plan = planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: [env.root]), roots: [env.root])
		let op = try Applier(operations: env.store, globals: env.globals)
			.apply(ApplyRequest(plan: plan, presetName: big.name, presetSnapshot: big.settings))
		#expect(op.summary.changed == 0 && op.summary.positionsOnly == 1)

		let o = OperationHistory([op]).overview(of: op)
		#expect(HistoryText.title(o) == "\"\(Fmt.name("Big"))\" 적용 · 아이콘 자리만 새로 잡은 폴더 1개")
		#expect(HistoryText.foldersTitle(o, count: ChangedFolders(op).total) == "아이콘 자리만 새로 잡은 폴더 1개")
		#expect(HistoryText.relatedNote(o).contains("아이콘 자리"))
		// A home record whose writes all failed wrote no positions either: the note does not say it did.
		let failed = FinderPresetsOperation(kind: .apply, startedAt: op.startedAt, finishedAt: op.startedAt, presetName: "Big", roots: [env.root.path],
		                                    entries: [OperationEntry(folderPath: env.root.path, storePath: "/x/.DS_Store", key: "Root", before: nil, after: nil, status: .failed)])
		#expect(!HistoryText.relatedNote(OperationHistory([failed]).overview(of: failed)).contains("아이콘 자리"))

		guard case .success(let pending) = AppModel.makePendingUndo(op.id, store: env.store) else { Issue.record("not prepared"); return }
		#expect(pending.restorable == [env.root.path] && pending.restorablePositionsOnly == 1)
		#expect(pending.canConfirm && !pending.recordsOnly)
		let outcome = AppModel.runUndo(pending, store: env.store)
		#expect(outcome.error == nil && outcome.restored == [env.root.path] && outcome.succeeded)
		let history = try OperationHistory(store: env.store)
		let undo = try #require(outcome.undoOperationID.flatMap(history.operation))
		let u = history.overview(of: undo)
		#expect(HistoryText.title(u) == "\"\(Fmt.name("Big"))\" 적용을 되돌림 · 아이콘 자리만 되돌린 폴더 1개")
		#expect(HistoryText.foldersTitle(u, count: ChangedFolders(undo).total) == "아이콘 자리만 되돌린 폴더 1개")
	}

	@Test func undoRefusesWhatChangedSinceTheConfirmation() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let icon = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon))
		let list = Preset(name: "List", settings: ViewSettings(viewStyle: .list))

		// Pinned after the confirmation was shown (here or with `finder-presets pin`): still the same record, the undo goes on.
		let pinned = try Self.apply(icon, to: [a], env: env)
		guard case .success(let pendingPinned) = AppModel.makePendingUndo(pinned.id, store: env.store) else { Issue.record("not prepared"); return }
		try env.store.setPinned(id: pinned.id, pinned: true)
		let undone = AppModel.runUndo(pendingPinned, store: env.store)
		#expect(undone.error == nil && undone.restored.count == 1)
		#expect(try Self.explicit(a, env: env) == nil)

		// Undone elsewhere (finder-presets undo) after the confirmation was shown: nothing more is written.
		let elsewhere = try Self.apply(list, to: [a], env: env)
		guard case .success(let pendingElsewhere) = AppModel.makePendingUndo(elsewhere.id, store: env.store) else { Issue.record("not prepared"); return }
		_ = try UndoService(operations: env.store).undo(try env.store.load(id: elsewhere.id))
		let before = try env.store.list().count
		let late = AppModel.runUndo(pendingElsewhere, store: env.store)
		#expect(late.error == UndoRefusal.alreadyUndone.message && late.undoOperationID == nil && late.restored.isEmpty)
		#expect(late.message == "중단: " + UndoRefusal.alreadyUndone.message)
		#expect(try env.store.list().count == before)
		#expect(StatusBar.tone(status: late.message, working: false) == .warning)

		// A record rewritten meanwhile (another manifest under the same ID) is not undone either.
		var rewritten = try Self.apply(icon, to: [a], env: env)
		guard case .success(let pendingRewritten) = AppModel.makePendingUndo(rewritten.id, store: env.store) else { Issue.record("not prepared"); return }
		rewritten.presetName = "rewritten"
		try env.store.save(rewritten)
		#expect(AppModel.runUndo(pendingRewritten, store: env.store).error == UndoRefusal.changed.message)
		#expect(try Self.explicit(a, env: env)?.viewStyle == .icon)
	}

	@Test func unfinishedAndEmptyOperationsAreRefused() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let now = Date()
		let entry = OperationEntry(folderPath: "/finder-presets-history-model/X", storePath: "/finder-presets-history-model/.DS_Store", key: "X",
		                           before: nil, after: ManagedRecordSet(), status: .changed)
		// Without a recorded writer (manifests of earlier versions) an unfinished record counts as running for a day.
		let running = FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-60), roots: ["/finder-presets-history-model"], entries: [entry])
		let crashed = FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-3 * 86400), roots: ["/finder-presets-history-model"], entries: [entry])
		// Written by this app a minute ago, whose apply returned or threw (e.g. its manifest could not be saved): a leftover
		// at once — the status line sent the user to "기록" for it.
		let stopped = FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-60), roots: ["/finder-presets-history-model"], entries: [entry],
		                           writer: OperationWriter.current)
		// Still being written by this app: refused until it is done.
		let writing = FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-5), roots: ["/finder-presets-history-model"], entries: [entry],
		                           writer: OperationWriter.current)
		let empty = FinderPresetsOperation(kind: .apply, startedAt: now.addingTimeInterval(-120), finishedAt: now, roots: ["/finder-presets-history-model"])
		let noSnapshot = FinderPresetsOperation(kind: .applyGlobal, startedAt: now.addingTimeInterval(-30), finishedAt: now, roots: [])
		for op in [running, crashed, stopped, writing, empty, noSnapshot] { try env.store.save(op) }
		OperationWriter.begin(writing.id)
		defer { OperationWriter.end(writing.id) }
		#expect(AppModel.makePendingUndo(running.id, store: env.store, now: now) == .failure(.inProgress))
		#expect(AppModel.makePendingUndo(writing.id, store: env.store, now: now) == .failure(.inProgress))
		#expect(AppModel.makePendingUndo(empty.id, store: env.store, now: now) == .failure(.nothingToUndo))
		#expect(AppModel.makePendingUndo(noSnapshot.id, store: env.store, now: now) == .failure(.nothingToUndo))
		let history = try OperationHistory(store: env.store, now: now)
		let rows = Dictionary(uniqueKeysWithValues: history.overviews.map { ($0.id, $0) })
		#expect(rows[writing.id]?.inProgress == true && rows[running.id]?.inProgress == true)
		#expect(rows[stopped.id]?.inProgress == false && rows[crashed.id]?.inProgress == false)
		let writingRow = try #require(rows[writing.id]), stoppedRow = try #require(rows[stopped.id])
		#expect(HistoryText.badge(writingRow)?.text == "진행 중" && HistoryText.badge(stoppedRow)?.text == "미완료")
		#expect(HistoryText.stateSentence(writingRow, undoneAt: nil).text == "아직 기록하는 중입니다. 끝난 뒤에 되돌릴 수 있습니다.")
		let stoppedState = HistoryText.stateSentence(stoppedRow, undoneAt: nil)
		#expect(stoppedState.text == "중간에 멈춘 작업입니다. 지금 되돌릴 수 있습니다." && stoppedState.warning)
		#expect(HistoryText.undoHelp(writingRow, busy: false) == UndoRefusal.inProgress.message)
		// A crash's leftover (older than a day) and the stopped apply can be undone, like with `finder-presets undo`. Their parent
		// store does not exist (so the folder is as before the apply): nothing to write, only the record.
		for leftoverID in [crashed.id, stopped.id] {
			guard case .success(let leftover) = AppModel.makePendingUndo(leftoverID, store: env.store, now: now) else { Issue.record("leftover refused"); return }
			#expect(leftover.alreadyRestored == ["/finder-presets-history-model/X"] && leftover.restorable.isEmpty && leftover.conflicts.isEmpty)
			#expect(leftover.recordsOnly && leftover.canConfirm)
		}
	}

	/// Every folder already as before (the parent `.DS_Store` deleted after the apply): the confirmation offers to record
	/// the operation as undone, the undo writes nothing, and the operation is no longer offered.
	@Test func foldersAlreadyAsBeforeAreRecordedAsUndone() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let op = try Self.apply(Preset(name: "Icon", settings: ViewSettings(icon: IconViewSettings(iconSize: 80))), to: [a], env: env)
		try FileManager.default.removeItem(at: env.root.appendingPathComponent(".DS_Store"))
		guard case .success(let pending) = AppModel.makePendingUndo(op.id, store: env.store) else { Issue.record("not prepared"); return }
		#expect(pending.recordsOnly && pending.canConfirm && pending.restorable.isEmpty && pending.alreadyRestored.count == 1)
		let outcome = AppModel.runUndo(pending, store: env.store)
		#expect(outcome.error == nil && outcome.recordedOnly && outcome.restored.isEmpty && outcome.alreadyRestored.count == 1 && outcome.succeeded)
		#expect(outcome.message == "완료: 폴더 1개가 모두 이미 적용 전 상태라 아무것도 쓰지 않고 되돌린 것으로 기록했습니다.")
		#expect(StatusBar.tone(status: outcome.message, working: false) == .success)
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent(".DS_Store").path))
		let history = try OperationHistory(store: env.store)
		let undoID = try #require(outcome.undoOperationID)
		let applied = try #require(history.operation(op.id)), undoOp = try #require(history.operation(undoID))
		#expect(history.status(of: applied) == .undone(by: undoID))
		#expect(AppModel.makePendingUndo(op.id, store: env.store) == .failure(.alreadyUndone))
		let undoRow = history.overview(of: undoOp)
		// The undo row names the apply it undid (never the bare word of the "이미 되돌림" badge).
		#expect(HistoryText.title(undoRow) == "\"\(Fmt.name("Icon"))\" 적용을 되돌림 · 바꾼 폴더 없음")
		#expect(HistoryText.stateSentence(undoRow, undoneAt: nil).text
			== "이미 적용 전 상태여서 아무것도 쓰지 않았습니다. " + UndoRefusal.isUndoRecord.message)
	}

	/// A parent `.DS_Store` that cannot be read after the apply: the confirmation lists the folder as unreadable (never as
	/// "already as before"), cannot be confirmed with nothing else to do, and an undo records it as failed.
	@Test func unreadableParentStoreIsShownAsSuch() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let op = try Self.apply(Preset(name: "Icon", settings: ViewSettings(icon: IconViewSettings(iconSize: 80))), to: [a], env: env)
		try Data("not a .DS_Store".utf8).write(to: env.root.appendingPathComponent(".DS_Store"))
		guard case .success(let pending) = AppModel.makePendingUndo(op.id, store: env.store) else { Issue.record("not prepared"); return }
		#expect(pending.unreadable.map { URL(fileURLWithPath: $0).lastPathComponent } == ["A"])
		#expect(pending.alreadyRestored.isEmpty && pending.conflicts.isEmpty && pending.restorable.isEmpty)
		#expect(!pending.recordsOnly && !pending.canConfirm)
		// With another folder that can be put back, the undo goes on and records the unreadable one as failed.
		try FileManager.default.removeItem(at: env.root.appendingPathComponent(".DS_Store"))
		let b1 = b.appendingPathComponent("B1")
		try FileManager.default.createDirectory(at: b1, withIntermediateDirectories: true)
		let two = try Self.apply(Preset(name: "Icon", settings: ViewSettings(icon: IconViewSettings(iconSize: 96))), to: [a, b1], env: env)
		try Data("not a .DS_Store".utf8).write(to: b.appendingPathComponent(".DS_Store"))   // B1's parent store
		guard case .success(let broken) = AppModel.makePendingUndo(two.id, store: env.store) else { Issue.record("not prepared"); return }
		#expect(broken.restorable.map { URL(fileURLWithPath: $0).lastPathComponent } == ["A"])
		#expect(broken.unreadable.map { URL(fileURLWithPath: $0).lastPathComponent } == ["B1"] && broken.canConfirm && !broken.recordsOnly)
		let outcome = AppModel.runUndo(broken, store: env.store)
		#expect(outcome.restored.count == 1 && outcome.failed.count == 1 && !outcome.recordedOnly && !outcome.succeeded)
		#expect(try Self.explicit(a, env: env) == nil)
	}

	/// The global undo from the sheet, against a throwaway domain and a fake Finder (the code path the app runs with
	/// com.apple.finder and the real Finder): the confirmation's values, a real undo, a verification that fails, values that
	/// became the recorded ones just before, a confirmation that promised to leave Finder alone, and a Finder that did not
	/// come back.
	@Test func globalUndoFromTheSheet() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-history-global-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: base) }
		let store = OperationStore(dirs: AppDirectories(root: base))
		func apply(_ settings: ViewSettings) throws -> FinderPresetsOperation {
			try GlobalApplier(operations: store, domain: domain.name, finder: FakeFinder()).apply(settings, presetName: "G")
		}
		func pending(_ op: FinderPresetsOperation) throws -> PendingUndo {
			guard case .success(let p) = AppModel.makePendingUndo(op.id, store: store, domain: domain.name) else { throw CancellationError() }
			return p
		}

		// (1) The values differ: the confirmation shows the current and the recorded values; it restarts Finder.
		let g = try apply(ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 96)))
		let p = try pending(g)
		#expect(p.isGlobal && !p.recordsOnly && p.canConfirm)
		#expect(p.global?.current.viewStyle == .list && p.global?.current.icon.iconSize == 96)
		#expect(p.global?.restored.viewStyle == .icon && p.global?.restored.icon.iconSize == 64 && p.global?.alreadyRestored == false)

		// (2) The undo runs: Finder quit and launched, an undoGlobal record, the apply undone.
		let finder = FakeFinder()
		let done = AppModel.runUndo(p, store: store, domain: domain.name, finder: finder)
		#expect(done.error == nil && done.finderRelaunched == true && !done.recordedOnly && done.succeeded)
		#expect(finder.events == ["quit", "launch", "settle"] && domain.style() == "icnv")
		var history = try OperationHistory(store: store)
		let undoID = try #require(done.undoOperationID)
		let gRecord = try #require(history.operation(g.id))
		#expect(history.operation(undoID)?.kind == .undoGlobal && history.status(of: gRecord) == .undone(by: undoID))
		#expect(done.message.hasPrefix("완료: Finder 기본 보기를 이 작업 전의 값으로 되돌렸습니다."))

		// (3) Finder writes other values back at launch: the verification fails; the undo's record is named.
		let g2 = try apply(ViewSettings(viewStyle: .column))
		let failing = FakeFinder()
		failing.onLaunch = { try? GlobalDefaultsWriter.write(viewStyle: "glyv", standardViewSettings: [:], domain: domain.name) }
		let failed = AppModel.runUndo(try pending(g2), store: store, domain: domain.name, finder: failing)
		#expect(failed.error?.contains("viewStyle: gallery ≠ icon") == true && failed.undoOperationID != nil && !failed.succeeded)
		history = try OperationHistory(store: store)
		#expect(history.operation(try #require(failed.undoOperationID))?.kind == .undoGlobal)
		#expect(!(failed.error ?? "").contains("복원한 값과 되읽은 값이 다릅니다"))   // the app's own words, not the core's text

		// (4) The values became the recorded ones after the confirmation: recorded as undone, Finder left alone.
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: [:], domain: domain.name)
		let g3 = try apply(ViewSettings(viewStyle: .gallery))
		let p3 = try pending(g3)
		#expect(!p3.recordsOnly)
		try GlobalDefaultsWriter.restore(try store.loadGlobalSnapshot(try #require(g3.globalSnapshotFile), for: g3), domain: domain.name)
		let untouched = FakeFinder()
		let recorded = AppModel.runUndo(p3, store: store, domain: domain.name, finder: untouched)
		#expect(recorded.error == nil && recorded.recordedOnly && recorded.finderRelaunched == nil && untouched.events.isEmpty)
		#expect(recorded.message.hasPrefix("완료: Finder 기본 보기는 이미 이 작업 전의 값이라"))
		history = try OperationHistory(store: store)
		let g3Record = try #require(history.operation(g3.id)), recordedID = try #require(recorded.undoOperationID)
		#expect(history.status(of: g3Record) == .undone(by: recordedID))

		// (5) A confirmation that said "already as before" never restarts Finder when the values changed meanwhile.
		let g4 = try apply(ViewSettings(viewStyle: .list))
		try GlobalDefaultsWriter.restore(try store.loadGlobalSnapshot(try #require(g4.globalSnapshotFile), for: g4), domain: domain.name)
		let p4 = try pending(g4)
		#expect(p4.recordsOnly && p4.canConfirm)
		try GlobalDefaultsWriter.write(viewStyle: "clmv", standardViewSettings: [:], domain: domain.name)
		let stopped = FakeFinder()
		let refused = AppModel.runUndo(p4, store: store, domain: domain.name, finder: stopped)
		#expect(refused.error == UndoRefusal.globalChanged.message && stopped.events.isEmpty && refused.undoOperationID == nil)

		// (6) Finder does not come back after the undo: said in the result.
		let noFinder = FakeFinder()
		noFinder.launchSucceeds = false
		let lost = AppModel.runUndo(try pending(g4), store: store, domain: domain.name, finder: noFinder)
		#expect(lost.finderRelaunched == false && !lost.succeeded && lost.message.contains("Finder 재실행에 실패했습니다"))
	}

	/// Which records the sheet chooses once it has read the list. A reload while it is open keeps the choice; opened again
	/// after new records (an apply since it was closed), the newest — never the older record chosen before, which
	/// "되돌리기" would then undo.
	@Test func historyReopenedAfterNewRecordsChoosesTheNewest() {
		let (a, b, c) = (UUID(), UUID(), UUID())
		// Reloads while the sheet is open: the choice stays while it is listed, else the newest.
		#expect(AppModel.chosenHistoryRecords([b], in: [a, b]) == [b])
		#expect(AppModel.chosenHistoryRecords([b, c], in: [a, b]) == [b])
		#expect(AppModel.chosenHistoryRecords([c], in: [a, b]) == [a])
		#expect(AppModel.chosenHistoryRecords([], in: [a, b]) == [a])
		#expect(AppModel.chosenHistoryRecords([b], in: []) == [])
		#expect(AppModel.chosenHistoryRecords([b], in: [c, a, b]) == [b])
		// Opened again: nothing new keeps the choice; a new record chooses the newest; the first opening, the newest.
		#expect(AppModel.chosenHistoryRecords([b], in: [a, b], shownBefore: [a, b]) == [b])
		#expect(AppModel.chosenHistoryRecords([a, b], in: [a, b], shownBefore: [a, b]) == [a, b])
		#expect(AppModel.chosenHistoryRecords([b], in: [c, a, b], shownBefore: [a, b]) == [c])
		#expect(AppModel.chosenHistoryRecords([], in: [a, b], shownBefore: []) == [a])
		// Records removed meanwhile (the automatic cleanup) are not new ones.
		#expect(AppModel.chosenHistoryRecords([b], in: [b], shownBefore: [a, b]) == [b])
		#expect(AppModel.chosenHistoryRecords([a], in: [b], shownBefore: [a, b]) == [b])
	}

	/// The two records of one "시스템 전체에 적용": the home folders are written while Finder is quit, i.e. between the
	/// global record's start and finish, with the same preset.
	@Test func systemApplyPairs() {
		let start = Date(timeIntervalSince1970: 1_000_000)
		let global = FinderPresetsOperation(kind: .applyGlobal, startedAt: start, finishedAt: start.addingTimeInterval(20), presetName: "P", roots: [])
		let homes = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(5), finishedAt: start.addingTimeInterval(8), presetName: "P", roots: ["/Users/x/Documents"])
		let later = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(60), finishedAt: start.addingTimeInterval(61), presetName: "P", roots: ["/x"])
		let otherPreset = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(6), presetName: "Q", roots: ["/y"])
		let pairs = AppModel.systemPairs([later, otherPreset, homes, global])
		#expect(pairs == [global.id: homes.id, homes.id: global.id])
		#expect(AppModel.systemPairs([later, otherPreset]).isEmpty)

		// This version names the home folders' record on the global one: paired exactly, whatever the times.
		let homesNow = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(900), presetName: "P", roots: ["/h"],
		                            recordCodes: ManagedRecordSet.managedCodes)
		let named = FinderPresetsOperation(kind: .applyGlobal, startedAt: start.addingTimeInterval(890), presetName: "P", roots: [],
		                         relatedOperationID: homesNow.id)
		#expect(AppModel.systemPairs([homesNow, named]) == [named.id: homesNow.id, homesNow.id: named.id])
		// A global apply that stopped before it finished (no finishedAt) and an unrelated folder apply of the same preset a
		// few minutes later: written by this version (recordCodes), it is never taken for the home folders' record.
		let stopped = FinderPresetsOperation(kind: .applyGlobal, startedAt: start.addingTimeInterval(2000), presetName: "P", roots: [])
		let unrelated = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(2300), presetName: "P", roots: ["/z"],
		                             recordCodes: ManagedRecordSet.managedCodes)
		#expect(AppModel.systemPairs([stopped, unrelated]).isEmpty)
		// An older record of the same kind (no recordCodes) is still paired by time, as before.
		let olderHomes = FinderPresetsOperation(kind: .apply, startedAt: start.addingTimeInterval(2010), presetName: "P", roots: ["/Users/x/Music"])
		#expect(AppModel.systemPairs([stopped, unrelated, olderHomes]) == [stopped.id: olderHomes.id, olderHomes.id: stopped.id])
		// A named record whose partner is gone (removed by the cleanup) pairs with nothing.
		#expect(AppModel.systemPairs([named]).isEmpty)
	}

	/// Undo results and the cleanup note keep the status line's icon right in both languages (literal texts, so the
	/// test does not depend on the language it runs in; LocalizationTests compares every text with its translation).
	@MainActor @Test func undoMessagesTone() {
		let tone = { (s: String) in StatusBar.tone(status: s, working: false) }
		#expect(tone("완료: 폴더 2개를 되돌림") == .success)
		#expect(tone("Done: 2 folders undone") == .success)
		#expect(tone("완료: 폴더 1개를 되돌림 · 충돌로 건너뜀 1개") == .warning)
		#expect(tone("Done: 1 folder undone · 1 skipped (conflict)") == .warning)
		#expect(tone("완료: 폴더 1개를 되돌림, 2개 실패") == .warning)
		#expect(tone("Done: 1 folder undone, 2 failed") == .warning)
		#expect(tone("중단: 이미 되돌린 작업입니다.") == .warning)
		#expect(tone("Stopped: This operation has already been undone.") == .warning)
		#expect(tone("완료: Finder 기본 보기를 이 작업 전의 값으로 되돌렸습니다. Finder를 다시 시작했습니다.") == .success)
		#expect(tone("Done: Finder's default view is back to the values from before the operation. Finder was restarted.") == .success)
		#expect(tone("완료: Finder 기본 보기를 이 작업 전의 값으로 되돌렸습니다. Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.") == .warning)
		#expect(tone("완료: 3개 폴더 변경 · 오래된 기록 1개 정리 실패: 권한 없음") == .warning)
		#expect(tone("Done: … · Cleanup of old records failed: permission") == .warning)
	}

	/// The texts are Korean here: outside the app bundle there are no tables (LocalizationTests checks the English ones).
	@Test func outcomeMessages() {
		let id = UUID()
		let ok = UndoOutcome(operationID: id, isGlobal: false, undoOperationID: UUID(), restored: ["/a", "/b"])
		// The status line carries the "완료: " / "중단: " its tone comes from; the result view in the sheet shows the body
		// alone (its heading says it went well), with the folders counted as in the list ("폴더 2개").
		#expect(ok.message == "완료: 폴더 2개를 되돌림" && HistoryText.outcomeBody(ok) == "폴더 2개를 되돌림" && ok.succeeded)
		let mixed = UndoOutcome(operationID: id, isGlobal: false, restored: ["/a"], conflicts: ["/b"], alreadyRestored: ["/c"], failed: ["/d"])
		#expect(mixed.message == "완료: 폴더 1개를 되돌림, 1개 실패 · 충돌로 건너뜀 1개 · 이미 적용 전 상태 1개")
		#expect(!mixed.succeeded)
		let nothing = UndoOutcome(operationID: id, isGlobal: false, conflicts: ["/b"])
		#expect(nothing.message == "완료: 되돌린 폴더 없음 · 충돌로 건너뜀 1개")
		let stopped = UndoOutcome(operationID: id, isGlobal: false, error: "E")
		#expect(stopped.message == "중단: E" && HistoryText.outcomeBody(stopped) == "E")
		let partly = UndoOutcome(operationID: id, isGlobal: false, restored: ["/a"], error: "E")
		#expect(partly.message == "중단: E · 폴더 1개를 되돌림")
		let global = UndoOutcome(operationID: id, isGlobal: true, undoOperationID: UUID(), finderRelaunched: true)
		#expect(global.message.hasPrefix("완료: ") && global.succeeded)
		let noFinder = UndoOutcome(operationID: id, isGlobal: true, finderRelaunched: false, error: "E")
		#expect(noFinder.message.hasPrefix("중단: ") && !noFinder.succeeded)
	}


	/// Row and detail texts of the history list: what happened first, then when and where, then the state — plain
	/// sentences, in the language of the run (Korean outside the app bundle).
	@Test func rowTexts() {
		let start = Date(timeIntervalSince1970: 1_000_000)
		let apply = FinderPresetsOperation(kind: .apply, startedAt: start, finishedAt: start, presetName: "P", roots: ["/x/Photos", "/x/Music", "/x/Movies"],
		                         entries: [OperationEntry(folderPath: "/x/Photos", storePath: "/x/.DS_Store", key: "Photos", before: nil, after: ManagedRecordSet(), status: .changed)])
		let undo = FinderPresetsOperation(kind: .undo, startedAt: start.addingTimeInterval(10), finishedAt: start.addingTimeInterval(11), presetName: "P",
		                        roots: apply.roots, entries: apply.entries, undoOfOperationID: apply.id)
		let history = OperationHistory([apply, undo])
		let a = history.overview(of: apply), u = history.overview(of: undo)
		// An apply is worded as something applied (never as the folders becoming the preset), the undo names that apply,
		// and the preset name is set apart with Fmt.name like every user-chosen name inside a sentence.
		#expect(HistoryText.title(a) == "폴더 1개에 \"\(Fmt.name("P"))\" 적용")
		#expect(HistoryText.title(u) == "\"\(Fmt.name("P"))\" 적용을 되돌림 · 폴더 1개")
		#expect(HistoryText.place(a) == "/x/Photos 외 2개")
		// The sentence in the details names the folders, not their paths: paths filled the pane and were cut (the row
		// above shows the path, the sentence's tooltip every one of them).
		#expect(HistoryText.placeNames(a) == "Photos, Music, Movies")
		// What VoiceOver reads of the second line: the "·" the row draws is not part of it.
		#expect(HistoryText.subtitle(a) == HistoryText.time(start) + ", /x/Photos 외 2개")
		#expect(HistoryText.summarySentence(a) == HistoryText.fullTime(start) + "에 Photos, Music, Movies에서 실행했습니다.")
		#expect(HistoryText.countsLine(a) == nil)
		// The badge of an apply that was undone says so in its own words, so the list never holds one word for two things.
		#expect(HistoryText.badge(a)?.text == "이미 되돌림" && HistoryText.badge(u) == nil)
		// Undone by the undo above: the detail says when, the undo row says it is never undone from here.
		#expect(HistoryText.stateSentence(a, undoneAt: undo.startedAt).text == HistoryText.fullTime(undo.startedAt) + "에 되돌렸습니다.")
		#expect(HistoryText.stateSentence(a, undoneAt: nil).text == UndoRefusal.alreadyUndone.message)
		#expect(HistoryText.stateSentence(u, undoneAt: nil).text == UndoRefusal.isUndoRecord.message)
		#expect(HistoryText.undoHelp(u, busy: false) == UndoRefusal.isUndoRecord.message)
		#expect(HistoryText.retentionLine.contains("50") && HistoryText.retentionLine.contains("30") && HistoryText.retentionLine.contains("200"))

		// A global apply, an apply that changed nothing, and the skipped and failed folders of a mixed one.
		let global = FinderPresetsOperation(kind: .applyGlobal, startedAt: start, finishedAt: start, presetName: "P", roots: [],
		                          globalSnapshotFile: OperationStore.globalSnapshotFileName)
		let nothing = FinderPresetsOperation(kind: .apply, startedAt: start, finishedAt: start, presetName: "P", roots: ["/x/Photos"],
		                           entries: [OperationEntry(folderPath: "/x/Photos", storePath: "/x/.DS_Store", key: "Photos", before: nil, after: nil, status: .skippedMatching),
		                                     OperationEntry(folderPath: "/x/Music", storePath: "/x/.DS_Store", key: "Music", before: nil, after: nil, status: .failed)])
		let mixed = OperationHistory([global, nothing])
		let g = mixed.overview(of: global), n = mixed.overview(of: nothing)
		#expect(HistoryText.title(g) == "Finder 기본 보기에 \"\(Fmt.name("P"))\" 적용")
		#expect(HistoryText.place(g) == nil && HistoryText.placeNames(g) == nil)
		#expect(HistoryText.summarySentence(g) == HistoryText.fullTime(start) + "에 실행했습니다.")
		#expect(HistoryText.stateSentence(g, undoneAt: nil).text == "지금 되돌릴 수 있습니다.")
		#expect(HistoryText.title(n) == "\"\(Fmt.name("P"))\" 적용")
		#expect(HistoryText.countsLine(n) == "건너뛴 폴더 1개 · 실패한 폴더 1개")
		// The state sentence and the tooltip of the disabled "되돌리기…" say the same thing about the same record.
		#expect(HistoryText.stateSentence(n, undoneAt: nil).text == "되돌릴 것이 없습니다(바뀐 폴더가 없습니다).")
		#expect(HistoryText.undoHelp(n, busy: false) == "되돌릴 것이 없습니다(바뀐 폴더가 없습니다).")
		#expect(HistoryText.undoHelp(g, busy: false).isEmpty == false)
	}

	/// A record left behind by a writer that stopped partway (no `finishedAt`, older than a day): whatever its status, the
	/// details say it stopped, and an unfinished record with nothing to undo is not silent about it.
	@Test func leftoverRecordsSayTheyStoppedPartway() throws {
		let start = Date(timeIntervalSince1970: 1_000_000)
		let changed = OperationEntry(folderPath: "/x/Photos", storePath: "/x/.DS_Store", key: "Photos", before: nil, after: ManagedRecordSet(), status: .changed)
		let skipped = OperationEntry(folderPath: "/x/Photos", storePath: "/x/.DS_Store", key: "Photos", before: nil, after: nil, status: .skippedMatching)
		let history = OperationHistory([FinderPresetsOperation(kind: .apply, startedAt: start, presetName: "P", roots: ["/x"], entries: [changed]),
		                                FinderPresetsOperation(kind: .apply, startedAt: start, presetName: "P", roots: ["/x"], entries: [skipped])],
		                               now: start.addingTimeInterval(2 * 86400))
		let undoable = try #require(history.overviews.first { $0.folderCount > 0 })
		let nothing = try #require(history.overviews.first { $0.folderCount == 0 })
		#expect(HistoryText.badge(undoable)?.text == "미완료" && HistoryText.badge(nothing)?.text == "미완료")
		#expect(HistoryText.stateSentence(undoable, undoneAt: nil).text == "중간에 멈춘 작업입니다. 지금 되돌릴 수 있습니다.")
		let stopped = HistoryText.stateSentence(nothing, undoneAt: nil)
		#expect(stopped.text == "중간에 멈춘 작업입니다. 되돌릴 것이 없습니다(바뀐 폴더가 없습니다)." && stopped.warning)
		// An unfinished record says when it started; a finished one says when it ran.
		#expect(HistoryText.summarySentence(undoable) == HistoryText.fullTime(start) + "에 x에서 시작했습니다.")
	}

	/// What the details say about the selected record's preset and folders: the preview is drawn only from a recorded
	/// preset, the folder heading counts what the operation changed (an undo: what it put back), a global operation says
	/// it changed Finder's default view, and the rest of the folders are counted.
	@Test func presetPreviewAndFolderListOfARecord() throws {
		func entry(_ path: String, _ status: EntryStatus) -> OperationEntry {
			OperationEntry(folderPath: path, storePath: "/x/.DS_Store", key: (path as NSString).lastPathComponent,
			               before: nil, after: ManagedRecordSet(), status: status)
		}
		let settings = ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .dateModified))
		let apply = FinderPresetsOperation(kind: .apply, presetName: "P", presetSnapshot: settings, roots: ["/x"],
		                         entries: (0..<10).map { entry("/x/f\($0)", .changed) } + [entry("/x/s", .skippedMatching), entry("/x/e", .failed)])
		let undo = FinderPresetsOperation(kind: .undo, presetName: "P", roots: ["/x"], entries: [entry("/x/f0", .changed)],
		                        undoOfOperationID: apply.id)
		let global = FinderPresetsOperation(kind: .applyGlobal, presetName: "P", presetSnapshot: settings, roots: [],
		                          globalSnapshotFile: OperationStore.globalSnapshotFileName)
		let history = OperationHistory([apply, undo, global])
		let (a, u, g) = (history.overview(of: apply), history.overview(of: undo), history.overview(of: global))

		// The preset: drawn for both applies, never for the undo record, which says why in one line.
		let details = HistoryDetails(apply)
		#expect(details.id == apply.id && details.preset == settings)
		#expect(HistoryDetails(global).preset == settings)
		#expect(HistoryDetails(undo).preset == nil)
		#expect(HistoryText.noPreview(u).contains("되돌리기 기록"))
		#expect(HistoryText.noPreview(a) != HistoryText.noPreview(u))
		#expect(HistoryText.previewTitle(drawn: true) != HistoryText.previewTitle(drawn: false))
		// An apply without a snapshot is either a mixed apply or an older record; the line says both, never "no values" alone.
		#expect(HistoryText.noPreview(a).contains("여러 프리셋") && HistoryText.noPreview(a).contains("기록되지 않아"))
		// The undo record's short line (a button beside it goes to the operation it undid) and the unreadable one.
		#expect(HistoryText.noPreviewUndo.contains("되돌리기 기록") && !HistoryText.noPreviewUndo.contains("고르면"))
		#expect(HistoryText.noPreview(u).hasPrefix(HistoryText.noPreviewUndo))
		#expect(!HistoryText.showUndone.isEmpty && HistoryText.detailsUnreadable != HistoryText.noPreview(a))
		#expect(HistoryText.detailsUnreadable.contains("읽지 못"))

		// The folders: counted by kind, capped, and the skipped and failed ones stay in the counts line and its tooltip.
		#expect(HistoryText.foldersTitle(a, count: details.folders.total) == "바뀐 폴더 10개")
		#expect(HistoryText.foldersTitle(u, count: 1) == "되돌린 폴더 1개")
		#expect(HistoryText.foldersTitle(g, count: 0) == "Finder 기본 보기를 바꿨습니다.")
		#expect(HistoryText.foldersTitle(a, count: 0) == "바꾼 폴더 없음")
		#expect(details.folders.shown.count == 8 && HistoryText.moreFolders(details.folders.hidden) == "외 2개")
		#expect(HistoryText.moreFolders(0) == nil)
		#expect(details.skipped == ["/x/s"] && details.failed == ["/x/e"])
		let help = try #require(HistoryText.countsHelp(a, details))
		#expect(help.contains("/x/s") && help.contains("/x/e") && help.hasPrefix("건너뛴 폴더 1개"))
		#expect(HistoryText.countsHelp(a, nil) == HistoryText.countsLine(a))
		#expect(HistoryText.countsLine(u) == nil && HistoryText.countsHelp(u, HistoryDetails(undo)) == nil)
		// A folder row: its own name, and where it sits inside the root it is listed under — never that root's path again,
		// which the heading over the group already shows.
		#expect(HistoryText.folderRow("/x/f0", under: "/x") == (name: "f0", place: ""))
		#expect(HistoryText.folderRow("/x", under: "/x") == (name: "x", place: ""))
		#expect(HistoryText.folderRow("/x/a/b/c", under: "/x") == (name: "c", place: "a/b"))
		#expect(HistoryText.folderRow("/x/a/b/c", under: "/x/a") == (name: "c", place: "b"))
		// A trailing slash on the root, and a folder under none of the roots (root ""): the abbreviated parent path.
		#expect(HistoryText.folderRow("/x/a/b", under: "/x/") == (name: "b", place: "a"))
		#expect(HistoryText.folderRow("/x/f0", under: "") == (name: "f0", place: "/x"))
		#expect(HistoryText.folderRow("/x", under: "").place == "")
		// A root that is not a prefix of the path at all (a record whose roots were rewritten): the path is not cut up.
		#expect(HistoryText.folderRow("/y/f0", under: "/x") == (name: "f0", place: "/y"))
		// The counts line's tooltip names at most `problemLimit` paths and counts the rest, like the folder list.
		let many = FinderPresetsOperation(kind: .apply, presetName: "P", roots: ["/x"],
		                        entries: (0..<(HistoryDetails.problemLimit + 5)).map { entry("/x/s\($0)", .skippedMatching) })
		let manyDetails = HistoryDetails(many)
		#expect(manyDetails.skipped.count == HistoryDetails.problemLimit)
		let manyHelp = try #require(HistoryText.countsHelp(OperationHistory([many]).overview(of: many), manyDetails))
		#expect(manyHelp.hasSuffix(HistoryText.moreFolders(5) ?? "-"))
	}

	/// "지우기…" and "기록 모두 지우기…": which records the confirmation covers, what the delete removes and what it
	/// leaves — the folders keep the view settings the operation wrote, and a record still being written is never touched.
	@Test func deletingRecordsRemovesThemWithTheirBackups() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let icon = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 72)))
		let first = try Self.apply(icon, to: [a], env: env)
		let second = try Self.apply(icon, to: [b], env: env)
		let entry = OperationEntry(folderPath: "/finder-presets-history-model/X", storePath: "/finder-presets-history-model/.DS_Store", key: "X",
		                           before: nil, after: ManagedRecordSet(), status: .changed)
		let writing = FinderPresetsOperation(kind: .apply, startedAt: Date(), roots: ["/finder-presets-history-model"], entries: [entry],
		                           writer: OperationWriter.current)
		try env.store.save(writing)
		OperationWriter.begin(writing.id)
		defer { OperationWriter.end(writing.id) }
		let items = OperationHistory(try env.store.list()).overviews
		// What the confirmation covers: the chosen records, never one being written or one that is not listed.
		#expect(HistoryDeletion.chosen([writing.id], in: items) == nil)
		#expect(HistoryDeletion.chosen([UUID()], in: items) == nil && HistoryDeletion.chosen([], in: items) == nil)
		let one = try #require(HistoryDeletion.chosen([second.id], in: items))
		let secondRow = try #require(items.first { $0.id == second.id })
		#expect(one.ids == [second.id] && one.scope == .one(secondRow) && one.inProgress == 0)
		// Several chosen with ⇧/⌘-click: the ones being written are left out and counted.
		let several = try #require(HistoryDeletion.chosen([first.id, second.id, writing.id], in: items))
		#expect(Set(several.ids) == [first.id, second.id] && several.scope == .chosen && several.inProgress == 1)
		let all = try #require(HistoryDeletion.all(items))
		#expect(Set(all.ids) == [first.id, second.id] && all.scope == .all && all.inProgress == 1)
		#expect(HistoryDeletion.all([]) == nil)
		// The confirmation's words: what goes with the record, and that no folder changes.
		#expect(HistoryText.deleteTitle(one) == "이 기록을 지울까요?" && HistoryText.deleteTitle(all) == "기록을 모두 지울까요?")
		#expect(HistoryText.deleteTitle(several) == "고른 기록을 지울까요?")
		#expect(HistoryText.deleteMessage(several).hasPrefix("고른 기록 2개를") && HistoryText.chosenTitle(3) == "기록 3개를 골랐습니다")
		let message = HistoryText.deleteMessage(all)
		#expect(message.contains("기록 2개") && message.contains("기록하는 중인 작업은 남겨 둡니다."))
		#expect(message.hasSuffix("폴더의 보기 설정은 그대로 둡니다(지금 모습이 그대로 남습니다)."))
		#expect(HistoryText.deleteMessage(one).hasPrefix(HistoryText.title(secondRow)))
		#expect(HistoryText.deleteHelp(nil) == "지울 기록을 고르세요.")
		#expect(HistoryText.deleteHelp(items.first { $0.id == writing.id }) == "기록하는 중인 작업은 지울 수 없습니다.")
		// The delete itself: the record's folder (manifest and backups) is gone, the others stay, and the folder keeps
		// the view settings the apply wrote.
		let applied = try Self.explicit(b, env: env)
		#expect(applied?.icon.iconSize == 72)
		#expect(AppModel.deleteRecords(one.ids, store: env.store) == (kept: 0, failed: nil))
		#expect(!FileManager.default.fileExists(atPath: env.store.directory(for: second.id).path))
		#expect(FileManager.default.fileExists(atPath: env.store.directory(for: first.id).path))
		#expect(try Self.explicit(b, env: env) == applied)
		// Every record at once: the one being written is kept and counted, the rest are gone.
		let rest = AppModel.deleteRecords([first.id, writing.id], store: env.store)
		#expect(rest.kept == 1 && rest.failed == nil)
		#expect(try env.store.list().map(\.id) == [writing.id])
		// A record that is already gone (deleted elsewhere, or by the automatic cleanup) is reported, not ignored.
		#expect(AppModel.deleteRecords([second.id], store: env.store).failed != nil)
	}
}

import Foundation
import Testing
@testable import FinderPresetsCore

/// `OperationHistory` (what can be undone, shared by the app and `finder-presets undo` / `global-undo`) and the retention of
/// recorded operations (`OperationStore.retentionPlan` / `applyRetention` / `setPinned`).
@Suite struct HistoryAndRetentionTests {
	static let day: TimeInterval = 86400

	static func tempDataDir(_ prefix: String) -> AppDirectories {
		AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)"))
	}

	static func entry(_ status: EntryStatus, _ name: String) -> OperationEntry {
		OperationEntry(folderPath: "/finder-presets-history-test/\(name)", storePath: "/finder-presets-history-test/.DS_Store", key: name, before: nil, after: ManagedRecordSet(), status: status)
	}

	/// An operation recorded `age` seconds before `now`: `changed` folder entries (folder kinds), a global snapshot
	/// file name (global kinds, when `snapshot`), finished unless `finished` is false.
	static func op(_ kind: OperationKind, age: TimeInterval, now: Date, changed: Int = 1, skipped: Int = 0, undoOf: UUID? = nil,
	               finished: Bool = true, snapshot: Bool = true, pinned: Bool = false, preset: String? = "P", roots: [String] = ["/finder-presets-history-test"]) -> FinderPresetsOperation {
		let started = now.addingTimeInterval(-age)
		var entries: [OperationEntry] = []
		if !kind.isGlobal {
			entries += (0..<changed).map { entry(.changed, "C\($0)") }
			entries += (0..<skipped).map { entry(.skippedConflict, "S\($0)") }
		}
		return FinderPresetsOperation(kind: kind, startedAt: started, finishedAt: finished ? started.addingTimeInterval(1) : nil, presetName: preset,
		                    roots: kind.isGlobal ? [] : roots, entries: entries, undoOfOperationID: undoOf, pinned: pinned,
		                    globalSnapshotFile: kind.isGlobal && snapshot ? OperationStore.globalSnapshotFileName : nil)
	}

	// MARK: OperationHistory

	@Test func undoStatusFollowsUndoRedoAndFamilies() {
		let now = Date()
		let older = Self.op(.apply, age: 10 * Self.day, now: now)
		let a = Self.op(.apply, age: 9 * Self.day, now: now, roots: ["/finder-presets-history-test/A", "/finder-presets-history-test/B"])
		let nothing = Self.op(.apply, age: 8 * Self.day, now: now, changed: 0, skipped: 3)
		var ops = [older, a, nothing]
		var history = OperationHistory(ops)
		#expect(history.status(of: a) == .undoable)
		#expect(history.status(of: nothing) == .nothingToUndo && !history.isUndoable(nothing))
		#expect(history.latestUndoable(global: false)?.id == a.id)
		#expect(history.operations.filter(history.isUndoable).map(\.id) == [a.id, older.id])

		// An undo that skipped every folder (conflicts) restored nothing: the apply stays undoable.
		let allConflicts = Self.op(.undo, age: 7 * Self.day, now: now, changed: 0, skipped: 2, undoOf: a.id)
		ops.append(allConflicts)
		history = OperationHistory(ops)
		#expect(history.status(of: a) == .undoable)
		#expect(history.status(of: allConflicts) == .nothingToUndo)

		// A real undo: a is undone, the undo itself is never offered (but could be redone by ID).
		let u1 = Self.op(.undo, age: 6 * Self.day, now: now, undoOf: a.id)
		ops.append(u1)
		history = OperationHistory(ops)
		#expect(history.status(of: a) == .undone(by: u1.id))
		#expect(history.status(of: u1) == .undoable && !history.isUndoable(u1))
		#expect(history.latestUndoable(global: false)?.id == older.id)
		#expect(!history.operations.contains { $0.kind.isUndo && history.isUndoable($0) })

		// Redo (undo of the undo): a is undoable again; the redo is not offered either.
		let u2 = Self.op(.undo, age: 5 * Self.day, now: now, undoOf: u1.id)
		ops.append(u2)
		history = OperationHistory(ops)
		#expect(history.status(of: u1) == .undone(by: u2.id))
		#expect(history.status(of: a) == .undoable)
		#expect(history.latestUndoable(global: false)?.id == a.id)
		// ...and undone once more by a newer undo.
		let u3 = Self.op(.undo, age: 4 * Self.day, now: now, undoOf: a.id)
		ops.append(u3)
		history = OperationHistory(ops)
		#expect(history.status(of: a) == .undone(by: u3.id))

		// Global family: an unfinished (failed) global undo does not count; a finished one does. A folder undo that points
		// at a global operation (only possible in an edited manifest) is ignored.
		let g = Self.op(.applyGlobal, age: 3 * Self.day, now: now)
		let noSnapshot = Self.op(.applyGlobal, age: 2 * Self.day, now: now, snapshot: false)
		let failedUndo = Self.op(.undoGlobal, age: 1 * Self.day, now: now, undoOf: g.id, finished: false)
		let wrongFamily = Self.op(.undo, age: 0.5 * Self.day, now: now, undoOf: g.id)
		ops += [g, noSnapshot, failedUndo, wrongFamily]
		history = OperationHistory(ops)
		#expect(history.status(of: g) == .undoable)
		#expect(history.status(of: noSnapshot) == .nothingToUndo)
		#expect(history.latestUndoable(global: true)?.id == g.id)
		#expect(history.latestUndoable(global: false)?.id == older.id)
		#expect(history.operations.filter { $0.kind.isGlobal && history.isUndoable($0) }.map(\.id) == [g.id])
		let ug = Self.op(.undoGlobal, age: 0.2 * Self.day, now: now, undoOf: g.id)
		ops.append(ug)
		history = OperationHistory(ops)
		#expect(history.status(of: g) == .undone(by: ug.id))
		#expect(history.latestUndoable(global: true) == nil)

		// Overview: what the app lists.
		let o = history.overview(of: a)
		#expect(o.kind == .apply && !o.isGlobal && !o.isUndo && o.isFinished && !o.canUndo)
		#expect(o.presetName == "P" && o.roots == a.roots && o.folderCount == 1 && o.startedAt == a.startedAt)
		#expect(o.status == .undone(by: u3.id))
		let og = history.overview(of: ug)
		#expect(og.isGlobal && og.isUndo && og.folderCount == 0 && og.roots.isEmpty && og.undoOfOperationID == g.id)
		#expect(history.overviews.map(\.id) == history.operations.map(\.id))
		#expect(history.operations.first?.id == ug.id)   // newest first, whatever order the input had
		#expect(history.overview(of: older).canUndo)
	}

	@Test func editedManifestsWithACycleDoNotHang() {
		let now = Date()
		let xID = UUID(), yID = UUID()
		let x = FinderPresetsOperation(id: xID, kind: .undo, startedAt: now, finishedAt: now, roots: [], entries: [Self.entry(.changed, "X")], undoOfOperationID: yID)
		let y = FinderPresetsOperation(id: yID, kind: .undo, startedAt: now.addingTimeInterval(-1), finishedAt: now, roots: [], entries: [Self.entry(.changed, "Y")], undoOfOperationID: xID)
		let history = OperationHistory([x, y])
		// Whatever the verdict, it is one of the defined ones and neither is offered for undo.
		#expect(!history.operations.contains(where: history.isUndoable))
		#expect([history.status(of: x), history.status(of: y)].allSatisfy { $0 != .nothingToUndo })
	}

	/// The same verdicts from real folder applies and undos (Applier, UndoService) read back from disk.
	@Test func historyFollowsRealApplyUndoAndRedo() throws {
		let env = try PlanApplyUndoTests.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		func plan(_ name: String) -> Plan {
			let roots = [env.root.appendingPathComponent(name)]
			return planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots), roots: roots)
		}
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let undo = UndoService(operations: ops)

		let op1 = try applier.apply(ApplyRequest(plan: plan("B"), presetName: preset.name))
		#expect(op1.summary.changed == 1)
		// The same apply again changes nothing: never offered, and `last` still means op1.
		let op2 = try applier.apply(ApplyRequest(plan: plan("B"), presetName: preset.name))
		#expect(op2.summary.changed == 0 && op2.summary.skipped == 1)
		var history = try OperationHistory(store: ops)
		#expect(history.status(of: op2) == .nothingToUndo)
		#expect(history.latestUndoable(global: false)?.id == op1.id)

		let u1 = try undo.undo(op1)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: op1) == .undone(by: u1.id))
		#expect(history.latestUndoable(global: false) == nil)
		#expect(history.status(of: u1) == .undoable && !history.isUndoable(u1))

		// Redo, then undo the original again: no conflicts, because the redo put back what op1 wrote.
		let u2 = try undo.undo(u1)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: u1) == .undone(by: u2.id))
		#expect(history.latestUndoable(global: false)?.id == op1.id)
		#expect(undo.preview(op1).conflicts.isEmpty)
		let u3 = try undo.undo(op1)
		#expect(u3.summary.changed == 1 && u3.summary.skipped == 0)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: op1) == .undone(by: u3.id))
		#expect(try StoreEditor.managedRecords(at: env.root.appendingPathComponent(".DS_Store"), key: "B")?.isEmpty ?? true)
		// The undo removed the store the apply had created. Undoing op1 once more (finder-presets undo <ID> --force) finds the folder
		// already as it was: nothing is written or reported as failed, and it does not count as another undo.
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent(".DS_Store").path))
		let again = undo.preview(op1)
		#expect(again.alreadyRestored.count == 1 && again.conflicts.isEmpty)
		let u4 = try undo.undo(op1, force: true)
		#expect(u4.summary.failed == 0 && u4.summary.changed == 0)
		#expect(u4.entries.map(\.status) == [.skippedMatching])
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent(".DS_Store").path))
		history = try OperationHistory(store: ops)
		#expect(history.status(of: op1) == .undone(by: u3.id))
		#expect(history.status(of: u4) == .nothingToUndo)

		// A folder changed after the apply: the undo skips it as a conflict and restores nothing, so the apply stays offered.
		let op3 = try applier.apply(ApplyRequest(plan: plan("C 한글 공간"), presetName: preset.name))
		let store = env.root.appendingPathComponent(".DS_Store")
		if case .present(let s) = try StoreEditor.read(store) {
			try StoreEditor.write(try StoreEditor.apply(ViewSettings(icon: IconViewSettings(iconSize: 16)), to: op3.entries[0].key, in: s, bases: RecordBases()), to: store)
		}
		let skippedAll = try undo.undo(op3)
		#expect(skippedAll.summary.changed == 0 && skippedAll.summary.skipped == 1)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: op3) == .undoable)
		#expect(history.latestUndoable(global: false)?.id == op3.id)
	}

	/// Global applies through GlobalApplier with a fake Finder and a throwaway preferences domain (never com.apple.finder).
	@Test func historyFollowsGlobalApplyUndoAndRedo() throws {
		let domain = GlobalDefaultsTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let dirs = Self.tempDataDir("finder-presets-history-global")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let ops = OperationStore(dirs: dirs)
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: GlobalDefaultsTests.FakeFinder(domain: domain.name))

		let g = try applier.apply(ViewSettings(viewStyle: .list), presetName: "L")
		var history = try OperationHistory(store: ops)
		#expect(history.latestUndoable(global: true)?.id == g.id)
		#expect(history.latestUndoable(global: false) == nil)
		let ug = try applier.undo(g)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: g) == .undone(by: ug.id))
		#expect(history.latestUndoable(global: true) == nil)
		#expect(domain.style() == "icnv")
		let redo = try applier.undo(ug)
		history = try OperationHistory(store: ops)
		#expect(history.status(of: ug) == .undone(by: redo.id))
		#expect(history.latestUndoable(global: true)?.id == g.id)
		#expect(domain.style() == "Nlsv")
		#expect(history.overview(of: g).isGlobal && history.overview(of: g).canUndo)
	}

	// MARK: Retention

	static func save(_ ops: [FinderPresetsOperation], in store: OperationStore, backupBytes: [UUID: Int] = [:]) throws {
		for op in ops {
			try store.save(op)
			if let n = backupBytes[op.id] {
				try Data(count: n).write(to: store.directory(for: op.id).appendingPathComponent("backups/0123456789abcdef.DS_Store"))
			}
		}
	}

	@Test func retentionKeepsProtectedOperationsAndRemovesTheRest() throws {
		let dirs = Self.tempDataDir("finder-presets-retention")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let store = OperationStore(dirs: dirs)
		let now = Date()
		let running = Self.op(.apply, age: 3600, now: now, changed: 0, finished: false)                 // in progress
		let a1 = Self.op(.apply, age: 1 * Self.day, now: now)                                              // latest undoable folder op
		let a2 = Self.op(.apply, age: 2 * Self.day, now: now)                                              // the one kept by maxCount 1
		let a3 = Self.op(.apply, age: 3 * Self.day, now: now)                                              // over count
		let a5 = Self.op(.apply, age: 40 * Self.day, now: now, pinned: true)                               // pinned (too old)
		let u4 = Self.op(.undo, age: 4 * Self.day, now: now, undoOf: a5.id)                                // undo of a kept op
		let a6 = Self.op(.apply, age: 50 * Self.day, now: now)                                             // too old
		let u7 = Self.op(.undo, age: 45 * Self.day, now: now, undoOf: a6.id)                               // undo of a removed op
		let g8 = Self.op(.applyGlobal, age: 60 * Self.day, now: now)                                       // latest undoable global op
		let crashed = Self.op(.apply, age: 10 * Self.day, now: now, finished: false)                       // crash leftover: follows the limits
		let all = [running, a1, a2, a3, u4, a5, a6, u7, g8, crashed]
		try Self.save(all, in: store)
		// Not an operation, and an operation whose manifest cannot be read: both are left alone.
		let notes = dirs.operations.appendingPathComponent("notes")
		try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
		let brokenID = UUID()
		try FileManager.default.createDirectory(at: store.directory(for: brokenID), withIntermediateDirectories: true)
		try Data("{".utf8).write(to: store.directory(for: brokenID).appendingPathComponent("manifest.json"))

		let policy = RetentionPolicy(maxCount: 1, maxAge: 30 * Self.day, maxBytes: 1 << 40)
		let before = OperationHistory(try store.list())
		let plan = try store.retentionPlan(policy: policy, now: now)
		// Planning changes nothing.
		#expect(try store.list().count == all.count)
		#expect(Set(plan.removed.map(\.id)) == [a3.id, a6.id, u7.id, crashed.id])
		let protection = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.protection) })
		#expect(protection[running.id] == .inProgress)
		#expect(protection[a1.id] == .latestUndoable)
		#expect(protection[g8.id] == .latestUndoable)
		#expect(protection[a5.id] == .pinned)
		#expect(protection[u4.id] == .undoOfKeptOperation)
		#expect(protection[a2.id] == .some(nil))
		let a5Item = try #require(plan.items.first { $0.id == a5.id })
		#expect(a5Item.reasons.contains(.tooOld) && !a5Item.isRemoved)
		let a6Item = try #require(plan.items.first { $0.id == a6.id })
		#expect(a6Item.reasons.contains(.tooOld) && a6Item.reasons.contains(.overCount))
		#expect(plan.unreadable.count == 1 && plan.unreadable[0].hasPrefix(brokenID.uuidString))
		#expect(plan.items.map(\.id) == before.operations.map(\.id))
		#expect(plan.removedBytes > 0 && plan.keptBytes > 0)

		let result = store.applyRetention(plan)
		#expect(Set(result.removed) == Set(plan.removed.map(\.id)))
		#expect(result.skipped.isEmpty && result.failed.isEmpty)
		for id in result.removed { #expect(!FileManager.default.fileExists(atPath: store.directory(for: id).path)) }
		#expect(FileManager.default.fileExists(atPath: notes.path))
		#expect(FileManager.default.fileExists(atPath: store.directory(for: brokenID).path))
		let after = OperationHistory(try store.list())
		#expect(Set(after.operations.map(\.id)) == Set(plan.kept.map(\.id)))
		// Every kept operation has the same undo verdict as before, and `last` still picks the same operations.
		for op in after.operations { #expect(after.status(of: op) == before.status(of: op)) }
		#expect(after.latestUndoable(global: false)?.id == a1.id && after.latestUndoable(global: true)?.id == g8.id)
		#expect(after.status(of: a5) == .undone(by: u4.id))

		// A second run finds nothing more to remove.
		#expect(try store.applyRetention(policy: policy, now: now).removed.isEmpty)
	}

	@Test func retentionBySizeKeepsTheNewestThatFit() throws {
		let dirs = Self.tempDataDir("finder-presets-retention-size")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let store = OperationStore(dirs: dirs)
		let now = Date()
		let kb = 1024
		let latest = Self.op(.apply, age: 1 * Self.day, now: now)   // protected: does not use the budget
		let big = Self.op(.apply, age: 2 * Self.day, now: now)
		let bigger = Self.op(.apply, age: 3 * Self.day, now: now)
		let small = Self.op(.apply, age: 4 * Self.day, now: now)
		try Self.save([latest, big, bigger, small], in: store, backupBytes: [latest.id: 500 * kb, big.id: 300 * kb, bigger.id: 200 * kb, small.id: 50 * kb])
		let plan = try store.retentionPlan(policy: RetentionPolicy(maxCount: 100, maxAge: 365 * Self.day, maxBytes: Int64(400 * kb)), now: now)
		#expect(plan.removed.map(\.id) == [bigger.id])
		#expect(plan.removed.first?.reasons == [.overSize])
		#expect(plan.items.first { $0.id == latest.id }?.protection == .latestUndoable)
		#expect(plan.removedBytes >= Int64(200 * kb))
		let result = store.applyRetention(plan)
		#expect(result.removed == [bigger.id])
		#expect(FileManager.default.fileExists(atPath: store.directory(for: small.id).appendingPathComponent("backups/0123456789abcdef.DS_Store").path))
	}

	@Test func retentionOnlyRemovesWhatThePlanSaw() throws {
		let dirs = Self.tempDataDir("finder-presets-retention-stale")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let store = OperationStore(dirs: dirs)
		let now = Date()
		let keep = Self.op(.apply, age: 1 * Self.day, now: now)
		let old1 = Self.op(.apply, age: 40 * Self.day, now: now)
		let old2 = Self.op(.apply, age: 41 * Self.day, now: now)
		let old3 = Self.op(.apply, age: 42 * Self.day, now: now)
		try Self.save([keep, old1, old2, old3], in: store)
		let plan = try store.retentionPlan(now: now)   // the standard policy: the three old ones are over 30 days
		#expect(Set(plan.removed.map(\.id)) == [old1.id, old2.id, old3.id])

		// A plan applied to another data folder removes nothing there.
		let otherDirs = Self.tempDataDir("finder-presets-retention-other")
		defer { try? FileManager.default.removeItem(at: otherDirs.root) }
		let other = OperationStore(dirs: otherDirs)
		try Self.save([old1], in: other)
		let elsewhere = other.applyRetention(plan)
		#expect(elsewhere.removed.isEmpty && elsewhere.skipped.count == 3)
		#expect(try other.list().map(\.id) == [old1.id])

		// Pinned after the plan was made, or removed by someone else meanwhile: left alone, the rest goes.
		try store.setPinned(id: old1.id, pinned: true)
		try store.delete(id: old2.id)
		let result = store.applyRetention(plan)
		#expect(result.removed == [old3.id])
		#expect(Set(result.skipped) == [old1.id, old2.id])
		#expect(Set(try store.list().map(\.id)) == [keep.id, old1.id])
		// The policy form applies the same rules.
		#expect(try store.applyRetention(policy: RetentionPolicy(maxCount: 0, maxAge: 0, maxBytes: 0), now: now).removed.isEmpty)   // keep: latest undoable, old1: pinned
	}

	@Test func setPinnedRewritesOnlyThePinnedFlag() throws {
		let dirs = Self.tempDataDir("finder-presets-pin")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let store = OperationStore(dirs: dirs)
		let now = Date()
		var op = Self.op(.apply, age: 2 * Self.day, now: now, changed: 2, skipped: 1)
		op.presetSnapshot = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 12.5), list: ListViewSettings(textSize: 11, sortColumn: .name, sortAscending: false))
		op.backups = [StoreBackup(storePath: "/finder-presets-history-test/.DS_Store", backupFile: "backups/x.DS_Store", sha256: "ab")]
		try store.save(op)
		let original = try store.load(id: op.id)   // dates as the manifest stores them (microseconds)
		// A key this version does not know (as a newer version could write) must survive the rewrite.
		let manifest = store.directory(for: op.id).appendingPathComponent("manifest.json")
		var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
		object["futureField"] = ["nested": [1, 2, 3], "flag": true]
		try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)

		let pinned = try store.setPinned(id: op.id, pinned: true)
		#expect(pinned.pinned)
		var expected = original
		expected.pinned = true
		#expect(try store.load(id: op.id) == expected)
		let back = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
		#expect((back["futureField"] as? [String: Any])?["nested"] as? [Int] == [1, 2, 3])
		#expect(back["pinned"] as? Bool == true)

		// Same state again: nothing is written.
		let bytes = try Data(contentsOf: manifest)
		#expect(try store.setPinned(id: op.id, pinned: true).pinned)
		#expect(try Data(contentsOf: manifest) == bytes)
		#expect(try store.setPinned(id: op.id, pinned: false).pinned == false)
		#expect(try store.load(id: op.id) == original)

		// Unknown ID, and an operation that is still being written.
		let missing = UUID()
		#expect(throws: OperationStoreError.notFound(missing)) { try store.setPinned(id: missing, pinned: true) }
		let running = Self.op(.apply, age: 60, now: now, finished: false)
		try store.save(running)
		let runningBytes = try Data(contentsOf: store.directory(for: running.id).appendingPathComponent("manifest.json"))
		#expect(throws: OperationStoreError.inProgress(running.id)) { try store.setPinned(id: running.id, pinned: true) }
		#expect(try Data(contentsOf: store.directory(for: running.id).appendingPathComponent("manifest.json")) == runningBytes)
		// A crash leftover (unfinished for longer than the grace period) can be pinned.
		let crashed = Self.op(.apply, age: 2 * Self.day, now: now, finished: false)
		try store.save(crashed)
		#expect(try store.setPinned(id: crashed.id, pinned: true).pinned)
		// An unreadable manifest is reported, not rewritten.
		let brokenID = UUID()
		try FileManager.default.createDirectory(at: store.directory(for: brokenID), withIntermediateDirectories: true)
		try Data("{".utf8).write(to: store.directory(for: brokenID).appendingPathComponent("manifest.json"))
		#expect(throws: OperationStoreError.self) { try store.setPinned(id: brokenID, pinned: true) }
		#expect(try Data(contentsOf: store.directory(for: brokenID).appendingPathComponent("manifest.json")) == Data("{".utf8))
	}

	@Test func listReadableReportsUnreadableManifestsAndOrdersTies() throws {
		let dirs = Self.tempDataDir("finder-presets-list")
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		let store = OperationStore(dirs: dirs)
		let now = Date()
		let t = now.addingTimeInterval(-Self.day)
		let x = FinderPresetsOperation(kind: .apply, startedAt: t, finishedAt: t, roots: [])
		let y = FinderPresetsOperation(kind: .apply, startedAt: t, finishedAt: t, roots: [])
		try store.save(x)
		try store.save(y)
		let brokenID = UUID()
		try FileManager.default.createDirectory(at: store.directory(for: brokenID), withIntermediateDirectories: true)
		let listing = try store.listReadable()
		#expect(listing.operations.map(\.id) == [x, y].sorted { $0.id.uuidString > $1.id.uuidString }.map(\.id))
		#expect(listing.unreadable.count == 1 && listing.unreadable[0].hasPrefix(brokenID.uuidString))
		#expect(try store.list().map(\.id) == listing.operations.map(\.id))
	}

	@Test func inProgressRule() throws {
		let now = Date()
		// Manifests without a recorded writer (written before writers were recorded): the time rule.
		#expect(Self.op(.apply, age: 60, now: now, finished: false).isInProgress(now: now))
		#expect(!Self.op(.apply, age: 60, now: now).isInProgress(now: now))
		#expect(!Self.op(.apply, age: FinderPresetsOperation.inProgressGrace + 1, now: now, finished: false).isInProgress(now: now))
		#expect(Self.op(.apply, age: -3600, now: now, finished: false).isInProgress(now: now))   // clock went back
		#expect(OperationKind.undo.isUndo && OperationKind.undoGlobal.isUndo && !OperationKind.apply.isUndo && !OperationKind.applyGlobal.isUndo)

		// With a writer: this process only while it is inside the writing call; another process while it runs.
		let me = try #require(OperationWriter.current)
		#expect(me.pid == getpid() && me.isCurrentProcess && me.isRunning)
		var mine = Self.op(.apply, age: 60, now: now, finished: false)
		mine.writer = me
		#expect(!mine.isInProgress(now: now))                 // returned or threw (e.g. a manifest save that failed): a leftover
		OperationWriter.begin(mine.id)
		#expect(mine.isInProgress(now: now))
		OperationWriter.end(mine.id)
		#expect(!mine.isInProgress(now: now))
		mine.finishedAt = now
		OperationWriter.begin(mine.id)
		#expect(!mine.isInProgress(now: now))                 // finished is finished
		OperationWriter.end(mine.id)
		let launchd = try #require(OperationWriter.startTime(of: 1))
		var other = Self.op(.apply, age: 3 * Self.day, now: now, finished: false)
		other.writer = OperationWriter(pid: 1, processStart: launchd)
		#expect(other.isInProgress(now: now))                 // a writer that still runs, however long
		other.writer = OperationWriter(pid: 1, processStart: launchd - 100)
		#expect(!other.isInProgress(now: now))                // the pid was reused by another process
		other.writer = OperationWriter(pid: Int32.max, processStart: launchd)
		#expect(!other.isInProgress(now: now))                // the writer is gone (a crash, a forced quit)
		// The manifest keeps the writer; older manifests decode without one.
		let data = try JSONCoding.encoder().encode(other)
		let decoded = try JSONCoding.decoder().decode(FinderPresetsOperation.self, from: data)
		#expect(decoded.writer == other.writer && decoded.writer?.processStart == launchd)
	}

	/// The writers record themselves and are in progress exactly while they write: an apply is in progress inside its
	/// call (seen from its progress callback) and not after it returns.
	@Test func applierIsInProgressOnlyWhileItWrites() throws {
		let env = try PlanApplyUndoTests.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon72", settings: ViewSettings(icon: IconViewSettings(iconSize: 72)))
		let roots = [env.root.appendingPathComponent("B")]
		let plan = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
			.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots), roots: roots)
		let ops = OperationStore(dirs: env.dirs)
		nonisolated(unsafe) var seenWhileWriting: [Bool] = []
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: plan, presetName: preset.name)) { _ in
			seenWhileWriting += ((try? ops.list()) ?? []).map { $0.isInProgress() }
		}
		#expect(seenWhileWriting == [true])
		let saved = try ops.load(id: op.id)
		#expect(op.writer == OperationWriter.current && !op.isInProgress() && !saved.isInProgress())
		// The same record, left without `finishedAt` by a writer that has returned (a save that failed): not in progress,
		// so it can be undone and pinned at once.
		var cut = try ops.load(id: op.id)
		cut.finishedAt = nil
		try ops.save(cut)
		let reloaded = try ops.load(id: op.id)
		#expect(!reloaded.isInProgress())
		#expect(try ops.setPinned(id: op.id, pinned: true).pinned)
		let undo = try UndoService(operations: ops).undo(try ops.load(id: op.id))
		#expect(undo.summary.changed == 1 && undo.writer == OperationWriter.current && !undo.isInProgress())
	}

	/// A folder undo that finds every folder already as before (the parent `.DS_Store` was deleted by a cleanup tool)
	/// writes nothing but counts: the apply is undone, `undo last` moves on to the older one, and retention protects
	/// that one as the newest undoable operation instead of the stuck one.
	@Test func undoOfFoldersAlreadyAsBeforeCountsAndLastMovesOn() throws {
		let env = try PlanApplyUndoTests.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		func plan(_ path: String) -> Plan {
			let roots = [env.root.appendingPathComponent(path)]
			return planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots), roots: roots)
		}
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let undo = UndoService(operations: ops)
		let older = try applier.apply(ApplyRequest(plan: plan("B"), presetName: preset.name))            // Root/.DS_Store
		let newer = try applier.apply(ApplyRequest(plan: plan("A/A1"), presetName: preset.name))         // Root/A/.DS_Store
		#expect(older.summary.changed == 1 && newer.summary.changed == 1 && newer.backups.first?.backupFile == nil)
		try FileManager.default.removeItem(at: env.root.appendingPathComponent("A/.DS_Store"))
		var history = try OperationHistory(store: ops)
		#expect(history.latestUndoable(global: false)?.id == newer.id)
		let preview = undo.preview(newer)
		#expect(preview.alreadyRestored.count == 1 && preview.conflicts.isEmpty && preview.unreadable.isEmpty && preview.restorable.isEmpty)

		let first = try undo.undo(newer)                  // what `undo last` does
		#expect(first.entries.map(\.status) == [.skippedMatching] && OperationHistory.foundAlreadyRestored(first))
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent("A/.DS_Store").path))   // nothing written
		history = try OperationHistory(store: ops)
		#expect(history.status(of: newer) == .undone(by: first.id))
		#expect(history.status(of: first) == .nothingToUndo && !history.isUndoable(first))
		#expect(history.latestUndoable(global: false)?.id == older.id)                          // `undo last` moves on
		#expect(history.overview(of: first).foundAlreadyRestored)

		// Retention: the older apply is the one protected as the newest undoable operation; the stuck one is not.
		let plan = try ops.retentionPlan(policy: RetentionPolicy(maxCount: 0, maxAge: 0, maxBytes: 0), now: Date().addingTimeInterval(60))
		#expect(plan.items.first { $0.id == older.id }?.protection == .latestUndoable)
		#expect(plan.items.first { $0.id == newer.id }?.protection == nil)
		#expect(plan.items.first { $0.id == first.id }?.protection == nil)

		// The second `undo last` undoes the older apply for real.
		let second = try undo.undo(try #require(history.latestUndoable(global: false)))
		#expect(second.undoOfOperationID == older.id && second.summary.changed == 1)
		history = try OperationHistory(store: ops)
		#expect(history.latestUndoable(global: false) == nil)
	}

	/// An undo that only found everything already as before counts for its operation unless the operation's changes came
	/// back later (a redo of an earlier undo); an undo that put something back always wins.
	@Test func alreadyRestoredUndosAndRedos() {
		let now = Date()
		func observed(_ target: FinderPresetsOperation, age: TimeInterval) -> FinderPresetsOperation {
			FinderPresetsOperation(kind: .undo, startedAt: now.addingTimeInterval(-age), finishedAt: now.addingTimeInterval(-age + 1), presetName: "P",
			             roots: target.roots, entries: [Self.entry(.skippedMatching, "C0")], undoOfOperationID: target.id)
		}
		let t = Self.op(.apply, age: 10 * Self.day, now: now)
		let seen1 = observed(t, age: 9 * Self.day)
		#expect(OperationHistory([t, seen1]).status(of: t) == .undone(by: seen1.id))
		// A real undo, then its redo: the changes are back after `seen1`, so `seen1` no longer counts.
		let u1 = Self.op(.undo, age: 8 * Self.day, now: now, undoOf: t.id)
		let redo = Self.op(.undo, age: 7 * Self.day, now: now, undoOf: u1.id)
		var history = OperationHistory([t, seen1, u1])
		#expect(history.status(of: t) == .undone(by: u1.id))          // the undo that put something back
		history = OperationHistory([t, seen1, u1, redo])
		#expect(history.status(of: u1) == .undone(by: redo.id))
		#expect(history.status(of: t) == .undoable)
		// Found as before again after the redo: undone by that one.
		let seen2 = observed(t, age: 6 * Self.day)
		history = OperationHistory([t, seen1, u1, redo, seen2])
		#expect(history.status(of: t) == .undone(by: seen2.id))
		// Mixed with a conflict or a failure, an undo that wrote nothing does not count.
		var conflict = observed(t, age: 5 * Self.day)
		conflict.entries.append(Self.entry(.skippedConflict, "C1"))
		#expect(OperationHistory([t, conflict]).status(of: t) == .undoable)
		var failed = observed(t, age: 5 * Self.day)
		failed.entries.append(Self.entry(.failed, "C1"))
		#expect(OperationHistory([t, failed]).status(of: t) == .undoable)
	}

	/// A parent `.DS_Store` that exists but cannot be read (damaged, no permission) is not "already as before" and not a
	/// conflict: the preview says it cannot be read, the undo records a failure and the operation stays undoable.
	@Test func unreadableParentStoreIsNeitherRestoredNorAConflict() throws {
		let env = try PlanApplyUndoTests.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon72", settings: ViewSettings(icon: IconViewSettings(iconSize: 72)))
		let roots = [env.root.appendingPathComponent("B")]
		let plan = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
			.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots), roots: roots)
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: plan, presetName: preset.name))
		#expect(op.summary.changed == 1 && op.entries.first?.before == nil)   // a new folder: no records before
		let store = env.root.appendingPathComponent(".DS_Store")
		let written = try Data(contentsOf: store)

		for damage in ["garbage", "no permission"] {
			if damage == "garbage" {
				try Data("not a .DS_Store".utf8).write(to: store)
			} else {
				try written.write(to: store)
				try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
			}
			let preview = UndoService(operations: ops).preview(op)
			#expect(preview.unreadable.count == 1 && preview.unreadable.first?.unreadable?.isEmpty == false, "\(damage)")
			#expect(preview.alreadyRestored.isEmpty && preview.conflicts.isEmpty && preview.restorable.isEmpty, "\(damage)")
			#expect(applier.verify(op).count == 1, "\(damage): the written values cannot be confirmed")
			let undo = try UndoService(operations: ops).undo(op)
			#expect(undo.entries.map(\.status) == [.failed] && !OperationHistory.foundAlreadyRestored(undo), "\(damage)")
			#expect(try OperationHistory(store: ops).status(of: op) == .undoable, "\(damage)")
			try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
		}
	}
}

/// `ChangedFolders`: which folders the history sheet lists for one record, in which order, and how the cap counts the
/// rest. Pure — no files, no display text.
@Suite struct ChangedFoldersTests {
	static func op(_ kind: OperationKind, roots: [String], changed: [String], skipped: [String] = [], failed: [String] = []) -> FinderPresetsOperation {
		func entry(_ path: String, _ status: EntryStatus) -> OperationEntry {
			OperationEntry(folderPath: path, storePath: path + "/../.DS_Store", key: (path as NSString).lastPathComponent,
			               before: nil, after: ManagedRecordSet(), status: status)
		}
		return FinderPresetsOperation(kind: kind, roots: roots,
		                    entries: changed.map { entry($0, .changed) } + skipped.map { entry($0, .skippedMatching) }
			                    + failed.map { entry($0, .failed) })
	}

	@Test func onlyChangedFoldersInTheOrderTheOperationWroteThem() {
		let folders = ChangedFolders(Self.op(.apply, roots: ["/a"], changed: ["/a", "/a/x", "/a/y"], skipped: ["/a/s"], failed: ["/a/f"]))
		#expect(folders.shown.map(\.path) == ["/a", "/a/x", "/a/y"])
		#expect(folders.shown.allSatisfy { $0.root == "/a" })
		#expect(folders.total == 3 && folders.hidden == 0 && !folders.isEmpty)
	}

	/// The roots keep the operation's own order, each folder goes under the deepest root that holds it, and folders
	/// under none of them come last.
	@Test func foldersAreGroupedUnderTheirRoot() {
		let op = Self.op(.apply, roots: ["/b", "/a", "/a/deep"],
		                 changed: ["/a/deep/one", "/b/two", "/a/three", "/elsewhere/four", "/a/deep"])
		let folders = ChangedFolders(op)
		#expect(folders.shown.map(\.root) == ["/b", "/a", "/a/deep", "/a/deep", ""])
		#expect(folders.shown.map(\.path) == ["/b/two", "/a/three", "/a/deep/one", "/a/deep", "/elsewhere/four"])
	}

	/// A root whose name is a prefix of another ("/a" and "/ab") never swallows the other's folders.
	@Test func aRootIsOnlyTheWholeFolderName() {
		let folders = ChangedFolders(Self.op(.apply, roots: ["/a"], changed: ["/ab/x", "/a/x"]))
		#expect(folders.shown.map(\.root) == ["/a", ""])
		#expect(folders.shown.map(\.path) == ["/a/x", "/ab/x"])
	}

	/// The cap: every root shows at least one folder before any root shows a second, and the rest are counted.
	@Test func theCapKeepsOneFolderPerRootAndCountsTheRest() {
		let op = Self.op(.apply, roots: ["/a", "/b", "/c"],
		                 changed: ["/a/1", "/a/2", "/a/3", "/b/1", "/b/2", "/c/1"])
		let capped = ChangedFolders(op, limit: 4)
		#expect(capped.shown.map(\.path) == ["/a/1", "/a/2", "/b/1", "/c/1"])   // grouped: the extra slot goes to the first root
		#expect(capped.total == 6 && capped.hidden == 2)
		// More roots than the cap: the first roots are listed, the rest are counted.
		let many = ChangedFolders(Self.op(.apply, roots: ["/a", "/b", "/c"], changed: ["/a/1", "/b/1", "/c/1"]), limit: 2)
		#expect(many.shown.map(\.path) == ["/a/1", "/b/1"] && many.hidden == 1)
		// Everything fits: nothing is counted.
		#expect(ChangedFolders(op, limit: 8).shown.count == 6)
	}

	/// An undo record lists the folders it put back; a global operation changed Finder's defaults, not folders.
	@Test func undoRecordsListWhatTheyRestoredAndGlobalOperationsNothing() {
		let undo = ChangedFolders(Self.op(.undo, roots: ["/a"], changed: ["/a/x"], skipped: ["/a/y"]))
		#expect(undo.shown.map(\.path) == ["/a/x"] && undo.total == 1)
		let global = ChangedFolders(Self.op(.applyGlobal, roots: [], changed: []))
		#expect(global.shown.isEmpty && global.total == 0 && global.isEmpty && global.hidden == 0)
		// An apply that changed nothing (every folder was already as the preset says).
		#expect(ChangedFolders(Self.op(.apply, roots: ["/a"], changed: [], skipped: ["/a/x"])).isEmpty)
	}
}

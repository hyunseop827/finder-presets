import Foundation
import Testing
import DSStore
@testable import FinderPresetsCore

/// Resetting icon positions: in "정렬 없음" and "자동 격자 정렬" Finder keeps the `Iloc` records of a
/// folder's own `.DS_Store`, so an apply that changes the icon layout removes them (and undo puts them back).
@Suite struct IconPositionsTests {
	/// base/Root with the folders A and B and a file; base/AppData for the operations.
	struct Env {
		let root: URL
		let dirs: AppDirectories
		let globals = GlobalDefaults.factory
		var ownStore: URL { root.appendingPathComponent(".DS_Store") }
		var parentStore: URL { root.deletingLastPathComponent().appendingPathComponent(".DS_Store") }
		var operations: OperationStore { OperationStore(dirs: dirs) }
		func cleanUp() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
	}

	static func makeEnv() throws -> Env {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-iloc-\(UUID().uuidString)")
		let root = base.appendingPathComponent("Root")
		for name in ["A", "B"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
		return Env(root: root, dirs: AppDirectories(root: base.appendingPathComponent("AppData")))
	}

	static let gridSmall = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, arrangeBy: .grid, gridSpacing: 54))
	static let big = Preset(name: "Big", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 164)))

	/// A store with the icon positions of A, B and file.txt 110pt apart, a comment on file.txt, and `views` applied.
	static func store(positions: Bool = true, views: [(String, ViewSettings)] = []) throws -> DSStore {
		var s = DSStore()
		if positions {
			for (i, name) in ["A", "B", "file.txt"].enumerated() { try s.setIconPosition(for: name, x: 107 + 110 * i, y: 102) }
		}
		s.add(DSStore.Record(filename: "file.txt", type: .spotlightComment, value: .string("note")))
		for (key, settings) in views { s = try StoreEditor.apply(settings, to: key, in: s, bases: RecordBases()) }
		return s
	}

	static func positions(_ url: URL) throws -> [NamedRecord] {
		guard case .present(let s) = try StoreEditor.read(url) else { return [] }
		return StoreEditor.iconPositions(in: s)
	}

	static func plan(_ env: Env, preset: Preset = big, depth: Int? = 0) -> Plan {
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		return planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: depth)).scan(roots: [env.root]), roots: [env.root])
	}

	@Test func triggerNeedsAnUnsortedArrangementAndALayoutChange() {
		let folder = URL(fileURLWithPath: "/tmp/x/Photos")
		let home = URL(fileURLWithPath: "/tmp/x")
		let big = Self.big.settings
		#expect(Planner.resetsIconPositions(folder: folder, before: Self.gridSmall, target: big, home: home))
		// A nil arrangement counts as "정렬 없음".
		#expect(Planner.resetsIconPositions(folder: folder, before: ViewSettings(icon: IconViewSettings(iconSize: 64)), target: big, home: home))
		// Sorted: Finder lines the icons up itself, before or after the apply.
		#expect(!Planner.resetsIconPositions(folder: folder, before: ViewSettings(icon: IconViewSettings(iconSize: 64, arrangeBy: .name)), target: big, home: home))
		#expect(!Planner.resetsIconPositions(folder: folder, before: Self.gridSmall,
		                                     target: ViewSettings(icon: IconViewSettings(iconSize: 164, arrangeBy: .kind)), home: home))
		// No icon-layout value changes: list options, the view style, the same size.
		#expect(!Planner.resetsIconPositions(folder: folder, before: Self.gridSmall, target: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11)), home: home))
		#expect(!Planner.resetsIconPositions(folder: folder, before: Self.gridSmall, target: ViewSettings(icon: IconViewSettings(iconSize: 64)), home: home))
		#expect(Planner.resetsIconPositions(folder: folder, before: Self.gridSmall, target: ViewSettings(icon: IconViewSettings(showItemInfo: true)), home: home))
		// The Desktop keeps the user's layout.
		#expect(!Planner.resetsIconPositions(folder: home.appendingPathComponent("Desktop"), before: Self.gridSmall, target: big, home: home))
	}

	@Test func desktopIsOnlyTheHomeDesktopItself() {
		let home = URL(fileURLWithPath: "/tmp/finder-presets-home")
		#expect(HomeFolders.isDesktop(home.appendingPathComponent("Desktop"), home: home))
		#expect(HomeFolders.isDesktop(URL(fileURLWithPath: "/tmp/finder-presets-home/desktop/"), home: home))
		#expect(!HomeFolders.isDesktop(home.appendingPathComponent("Desktop/Sub"), home: home))
		#expect(!HomeFolders.isDesktop(home.appendingPathComponent("Documents"), home: home))
		#expect(!HomeFolders.isDesktop(URL(fileURLWithPath: "/tmp/other/Desktop"), home: home))
	}

	/// The planner resets only a folder whose own `.DS_Store` holds positions; without one (or with an unreadable one)
	/// the entry is planned as before.
	@Test func plannerChecksTheFolderOwnStore() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		// No own store.
		var plan = Self.plan(env)
		#expect(plan.changes.count == 1 && plan.iconPositionResets == 0)
		// An own store without positions.
		try StoreEditor.write(try Self.store(positions: false), to: env.ownStore)
		#expect(Self.plan(env).iconPositionResets == 0)
		// An unreadable own store: no reset, still a change.
		try Data("not a store".utf8).write(to: env.ownStore)
		plan = Self.plan(env)
		#expect(plan.changes.count == 1 && plan.iconPositionResets == 0)
		// With positions.
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		plan = Self.plan(env)
		#expect(plan.changes.first?.resetsIconPositions == true && plan.iconPositionResets == 1)
		// A sorting preset leaves them.
		let sorted = Preset(name: "Sorted", settings: ViewSettings(icon: IconViewSettings(iconSize: 164, arrangeBy: .name)))
		#expect(Self.plan(env, preset: sorted).iconPositionResets == 0)
	}

	/// Apply removes only the `Iloc` records of the folder's own store — in the same write as the view records of its
	/// changed children, which live in that file too — and undo puts both back; undoing the undo removes them again.
	@Test func applyAndUndoResetPositionsWithTheChildrenInOneWrite() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		try StoreEditor.write(try Self.store(views: [("A", Self.gridSmall)]), to: env.ownStore)
		let childBefore = try StoreEditor.managedRecords(at: env.ownStore, key: "A")
		let plan = Self.plan(env, depth: 1)
		#expect(plan.changes.count == 3 && plan.iconPositionResets == 1)
		// The positions change between plan and apply: the apply removes and records the ones stored then.
		var moved = StoreEditor.replaceIconPositions(of: ["B"], with: [], in: try DSStore.read(from: env.ownStore))
		try moved.setIconPosition(for: "new.txt", x: 437, y: 102)
		try StoreEditor.write(moved, to: env.ownStore)
		let before = try Self.positions(env.ownStore)
		#expect(before.map(\.name).sorted() == ["A", "file.txt", "new.txt"])

		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: plan, presetName: Self.big.name))
		#expect(op.summary.changed == 3)
		#expect(try Self.positions(env.ownStore).isEmpty)
		let after = try DSStore.read(from: env.ownStore)
		#expect(after.comment(for: "file.txt") == "note")
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: after, key: "A")).icon.iconSize == 164)
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: after, key: "B")).icon.iconSize == 164)
		let rootEntry = try #require(op.entries.first { $0.folderPath == env.root.path })
		#expect(rootEntry.iconPositions == IconPositionsChange(storePath: env.ownStore.path, before: before, after: []))
		#expect(op.entries.filter { $0.iconPositions != nil }.count == 1)
		#expect(op.backups.filter { $0.storePath == env.ownStore.path }.count == 1)
		#expect(Applier(operations: ops, globals: env.globals).verify(op).isEmpty)
		#expect(try ops.load(id: op.id).entries == op.entries)

		// Finder lays the folder out and stores new positions: undo overwrites them with the old ones.
		var laidOut = try DSStore.read(from: env.ownStore)
		try laidOut.setIconPosition(for: "A", x: 107, y: 322)
		try StoreEditor.write(laidOut, to: env.ownStore)
		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.summary.changed == 3)
		#expect(try Self.positions(env.ownStore).sorted { $0.name < $1.name } == before.sorted { $0.name < $1.name })
		#expect(try StoreEditor.managedRecords(at: env.ownStore, key: "A") == childBefore)
		#expect(try DSStore.read(from: env.ownStore).comment(for: "file.txt") == "note")
		#expect(undo.backups.filter { $0.storePath == env.ownStore.path }.count == 1)
		let undoRoot = try #require(undo.entries.first { $0.folderPath == env.root.path })
		#expect(undoRoot.iconPositions?.after == before && undoRoot.iconPositions?.before.map(\.name) == ["A"])

		// Undoing the undo (redo): the positions Finder had stored come back, the rest are removed again.
		let redo = try UndoService(operations: ops).undo(undo)
		#expect(redo.summary.changed == 3)
		#expect(try Self.positions(env.ownStore).map(\.name) == ["A"])
		#expect(try Self.positions(env.ownStore).first?.record == undoRoot.iconPositions?.before.first?.record)
	}

	/// An earlier undo put the view records back but not the positions (its write of the own store failed): undoing
	/// again finds the view records already restored and still puts back the positions, as long as they are as the
	/// apply left them.
	@Test func undoRestoresPositionsLeftBehindWithRestoredViewRecords() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let parentBefore = try Data(contentsOf: env.parentStore)
		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: Self.plan(env), presetName: Self.big.name))
		try parentBefore.write(to: env.parentStore)
		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.entries.map(\.status) == [.skippedMatching])
		#expect(try Self.positions(env.ownStore).count == 3)
		#expect(undo.entries.first?.iconPositions?.after.count == 3)
		// Undoing that undo (a redo) takes the positions away again, although its entry changed no view record.
		let redo = try UndoService(operations: ops).undo(undo)
		#expect(redo.entries.map(\.status) == [.skippedMatching] && redo.entries.first?.iconPositions?.after.isEmpty == true)
		#expect(try Self.positions(env.ownStore).isEmpty)
		_ = try UndoService(operations: ops).undo(redo)
		#expect(try Self.positions(env.ownStore).count == 3)
		// Positions stored since (Finder laid the folder out) are left alone once the view records are back.
		var laidOut = try DSStore.read(from: env.ownStore)
		try laidOut.setIconPosition(for: "A", x: 107, y: 322)
		try StoreEditor.write(laidOut, to: env.ownStore)
		let laidOutPositions = try Self.positions(env.ownStore)
		let again = try UndoService(operations: ops).undo(op)
		#expect(again.entries.first?.iconPositions == nil)
		#expect(try Self.positions(env.ownStore) == laidOutPositions)
	}

	/// A folder whose view records conflict (changed after the apply) is skipped without `force`: its positions stay too.
	@Test func conflictLeavesPositionsAlone() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: Self.plan(env), presetName: Self.big.name))
		#expect(try Self.positions(env.ownStore).isEmpty)
		let changed = try StoreEditor.apply(ViewSettings(icon: IconViewSettings(iconSize: 32)), to: "Root", in: try DSStore.read(from: env.parentStore), bases: RecordBases())
		try StoreEditor.write(changed, to: env.parentStore)
		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.entries.map(\.status) == [.skippedConflict])
		#expect(try Self.positions(env.ownStore).isEmpty)
		#expect(!undo.backups.contains { $0.storePath == env.ownStore.path })
		// Forced, the positions come back with the view records.
		_ = try UndoService(operations: ops).undo(op, force: true)
		#expect(try Self.positions(env.ownStore).count == 3)
	}

	/// The folder's own record (`"."`, the home folder's case): the location store and the own store are one file,
	/// written once with the new view records and without the positions.
	@Test func selfKeyResetsInTheSameWrite() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try Self.store(views: [(".", Self.gridSmall), ("A", Self.gridSmall)]), to: env.ownStore)
		let positions = try Self.positions(env.ownStore)
		let location = StoreLocation(folder: env.root, storeURL: env.ownStore, key: StoreLocation.selfKey)
		var entry = PlanEntry(folder: env.root, depth: 0, location: location, category: .willChange, reason: nil, target: Self.big.settings,
		                      presetID: Self.big.id, ruleSource: .defaultPreset, diffs: [])
		entry.resetsIconPositions = true
		#expect(entry.ownStoreURL == env.ownStore)
		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: Plan(roots: [env.root], entries: [entry])))
		#expect(op.summary.changed == 1 && op.backups.count == 1)
		#expect(op.entries.first?.iconPositions?.before == positions)
		#expect(try Self.positions(env.ownStore).isEmpty)
		#expect(ViewRecordCodec.decode(try #require(try StoreEditor.managedRecords(at: env.ownStore, key: "."))).icon.iconSize == 164)
		_ = try UndoService(operations: ops).undo(op)
		#expect(try Self.positions(env.ownStore).count == 3)
		#expect(ViewRecordCodec.decode(try #require(try StoreEditor.managedRecords(at: env.ownStore, key: "."))).icon.iconSize == 64)
	}

	/// An own store that cannot be read at apply time: the view change stands and the failure is noted on the entry.
	@Test func failedResetKeepsTheViewChange() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let plan = Self.plan(env)
		#expect(plan.iconPositionResets == 1)
		try Data("not a store".utf8).write(to: env.ownStore)
		let op = try Applier(operations: env.operations, globals: env.globals).apply(ApplyRequest(plan: plan))
		let entry = try #require(op.entries.first)
		#expect(entry.status == .changed && entry.iconPositions == nil && entry.iconPositionsError != nil)
		#expect(try Data(contentsOf: env.ownStore) == Data("not a store".utf8))
	}

	/// A manifest entry written before icon positions were recorded decodes without them, and its undo works as before.
	@Test func entryWithoutIconPositionsDecodes() throws {
		let json = #"{"folderPath":"/x/Root","storePath":"/x/.DS_Store","key":"Root","status":"changed"}"#
		let entry = try JSONCoding.decoder().decode(OperationEntry.self, from: Data(json.utf8))
		#expect(entry.iconPositions == nil && entry.iconPositionsError == nil && entry.before == nil)

		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try StoreEditor.apply(Self.gridSmall, to: "Root", in: DSStore(), bases: RecordBases()), to: env.parentStore)
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: Self.plan(env)))
		// The same operation as an older version wrote it: no positions recorded.
		var object = try #require(try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(op)) as? [String: Any])
		object["entries"] = (object["entries"] as? [[String: Any]])?.map { $0.filter { $0.key != "iconPositions" } }
		let legacy = try JSONCoding.decoder().decode(FinderPresetsOperation.self, from: JSONSerialization.data(withJSONObject: object))
		#expect(legacy.entries.allSatisfy { $0.iconPositions == nil })
		let undo = try UndoService(operations: ops).undo(legacy)
		#expect(undo.summary.changed == 1 && undo.entries.first?.iconPositions == nil)
		#expect(try Self.positions(env.ownStore).isEmpty)
		#expect(ViewRecordCodec.decode(try #require(try StoreEditor.managedRecords(at: env.parentStore, key: "Root"))).icon.iconSize == 64)
	}

	// MARK: Positions only (a folder that follows Finder's default view, which the system-wide apply changes)

	/// Finder's defaults after a system-wide apply of `preset` (factory defaults before it).
	static func defaultsAfter(_ preset: Preset = big) -> ViewSettings {
		preset.settings.globalDefaultsPart.filling(from: GlobalDefaults.factory.effectiveSettings)
	}

	/// A plan like the rest of the home folder's in "시스템 전체에 적용": only folders with settings of their own, and
	/// `after` as Finder's new defaults.
	static func ownPlan(_ root: URL, after: ViewSettings?, depth: Int? = 0, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Plan {
		let planner = Planner(presets: [big], resolver: RuleResolver(rules: [], defaultPresetID: big.id), globals: .factory,
		                      options: PlanOptions(ownSettingsOnly: true, defaultsAfterApply: after), home: home)
		return planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: depth)).scan(roots: [root]), roots: [root])
	}

	/// A folder without view settings of its own whose own store holds positions is planned `iconPositionsOnly` when
	/// Finder's new default grows its icons in "없음"/"자동 격자 정렬" — and only then: not without new defaults, not under a
	/// sorted default, not without positions, not for the Desktop. It is no view change but counts as a reset.
	@Test func plannerPlansPositionsOnlyForFoldersFollowingTheDefaults() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let plan = Self.ownPlan(env.root, after: Self.defaultsAfter())
		let entry = try #require(plan.entries.first)
		#expect(plan.entries.count == 1 && entry.category == .iconPositionsOnly && entry.resetsIconPositions)
		#expect(entry.target == nil && entry.diffs.isEmpty && entry.location?.key == "Root" && entry.ownStoreURL == env.ownStore)
		#expect(plan.changes.isEmpty && plan.iconPositionResets == 1 && plan.counts[.iconPositionsOnly] == 1)
		// Finder's defaults are not written: the folder is left out as before.
		#expect(Self.ownPlan(env.root, after: nil).entries.isEmpty)
		// The same icon size, or a sorted default arrangement: nothing to reset.
		#expect(Self.ownPlan(env.root, after: GlobalDefaults.factory.effectiveSettings).entries.isEmpty)
		let sorted = Preset(name: "Sorted", settings: ViewSettings(icon: IconViewSettings(iconSize: 164, arrangeBy: .name)))
		#expect(Self.ownPlan(env.root, after: Self.defaultsAfter(sorted)).entries.isEmpty)
		// A grid default resets like none.
		let grid = Preset(name: "Grid", settings: ViewSettings(icon: IconViewSettings(iconSize: 164, arrangeBy: .grid)))
		#expect(Self.ownPlan(env.root, after: Self.defaultsAfter(grid)).iconPositionResets == 1)
		// A folder with settings of its own is planned as a view change instead (A, depth 1), never positions only.
		try StoreEditor.write(try Self.store(views: [("A", Self.gridSmall)]), to: env.ownStore)
		let deep = Self.ownPlan(env.root, after: Self.defaultsAfter(), depth: 1)
		#expect(deep.changes.map(\.folder.lastPathComponent) == ["A"] && deep.entries.filter { $0.category == .iconPositionsOnly }.map(\.folder.lastPathComponent) == ["Root"],
		        "\(deep.entries.map { ($0.folder.lastPathComponent, $0.category) })")
		// No positions stored.
		try StoreEditor.write(try Self.store(positions: false), to: env.ownStore)
		#expect(Self.ownPlan(env.root, after: Self.defaultsAfter()).entries.isEmpty)
		// The Desktop keeps the user's layout.
		let desktop = env.root.deletingLastPathComponent().appendingPathComponent("Desktop")
		try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
		try StoreEditor.write(try Self.store(), to: desktop.appendingPathComponent(".DS_Store"))
		#expect(Self.ownPlan(desktop, after: Self.defaultsAfter(), home: desktop.deletingLastPathComponent()).entries.isEmpty)
		#expect(Self.ownPlan(desktop, after: Self.defaultsAfter(), home: env.root).entries.count == 1)
	}

	/// The positions-only folder's own store also holds the view records of its changed child (A): one backup, one write
	/// without the positions and with A's new records; the folder is recorded `positionsOnly`. The undo puts the
	/// positions back even after Finder stored new ones, in the same write as A's records, and records them itself.
	@Test func positionsOnlyApplyAndUndoShareTheWrite() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try Self.store(views: [("A", Self.gridSmall)]), to: env.ownStore)
		let before = try Self.positions(env.ownStore)
		let childBefore = try StoreEditor.managedRecords(at: env.ownStore, key: "A")
		let plan = Self.ownPlan(env.root, after: Self.defaultsAfter(), depth: 1)
		#expect(plan.changes.count == 1 && plan.iconPositionResets == 1)

		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: plan, presetName: Self.big.name))
		#expect(op.summary.changed == 1 && op.summary.positionsOnly == 1 && op.summary.failed == 0)
		#expect(op.backups.map(\.storePath) == [env.ownStore.path])
		#expect(try Self.positions(env.ownStore).isEmpty)
		let after = try DSStore.read(from: env.ownStore)
		#expect(after.comment(for: "file.txt") == "note")
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: after, key: "A")).icon.iconSize == 164)
		let rootEntry = try #require(op.entries.first { $0.folderPath == env.root.path })
		#expect(rootEntry.status == .positionsOnly && rootEntry.before == nil && rootEntry.after == nil)
		#expect(rootEntry.storePath == env.parentStore.path && rootEntry.key == "Root")
		#expect(rootEntry.iconPositions == IconPositionsChange(storePath: env.ownStore.path, before: before, after: []))
		#expect(try ops.load(id: op.id).entries == op.entries)
		#expect(ChangedFolders(op).total == 1 && OperationHistory([op]).overview(of: op).positionsOnlyCount == 1)

		// Finder laid the folder out with the new default size: the undo overwrites what it stored.
		var laidOut = try DSStore.read(from: env.ownStore)
		try laidOut.setIconPosition(for: "A", x: 107, y: 322)
		try StoreEditor.write(laidOut, to: env.ownStore)
		let preview = UndoService(operations: ops).preview(op)
		#expect(preview.restorable.count == 2 && preview.conflicts.isEmpty)
		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.summary.changed == 1 && undo.summary.positionsOnly == 1)
		#expect(undo.backups.map(\.storePath) == [env.ownStore.path])
		#expect(try Self.positions(env.ownStore).sorted { $0.name < $1.name } == before.sorted { $0.name < $1.name })
		#expect(try StoreEditor.managedRecords(at: env.ownStore, key: "A") == childBefore)
		let undoRoot = try #require(undo.entries.first { $0.folderPath == env.root.path })
		#expect(undoRoot.status == .positionsOnly && undoRoot.iconPositions?.after == before && undoRoot.iconPositions?.before.map(\.name) == ["A"])
		#expect(OperationHistory([op, undo]).status(of: op) == .undone(by: undo.id))

		// Undoing the undo: A's records and the positions Finder had stored come back, the rest go again.
		let redo = try UndoService(operations: ops).undo(undo)
		#expect(redo.summary.changed == 1 && redo.summary.positionsOnly == 1)
		#expect(try Self.positions(env.ownStore).map(\.record) == undoRoot.iconPositions?.before.map(\.record))
	}

	/// An operation whose only change is a folder's positions can be undone (preview, history), and undone again.
	@Test func positionsOnlyOperationIsUndoable() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let before = try Self.positions(env.ownStore)
		let ops = env.operations
		let op = try Applier(operations: ops, globals: env.globals).apply(ApplyRequest(plan: Self.ownPlan(env.root, after: Self.defaultsAfter())))
		#expect(op.summary.changed == 0 && op.summary.positionsOnly == 1 && op.backups.count == 1)
		#expect(try Self.positions(env.ownStore).isEmpty)
		#expect(OperationHistory([op]).status(of: op) == .undoable && OperationHistory([op]).isUndoable(op))
		#expect(ChangedFolders(op).isEmpty)
		let preview = UndoService(operations: ops).preview(op)
		#expect(preview.items.count == 1 && preview.restorable.count == 1)

		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.entries.map(\.status) == [.positionsOnly])
		#expect(try Self.positions(env.ownStore) == before)
		#expect(OperationHistory.restoredSomething(undo) && !OperationHistory.foundAlreadyRestored(undo))
		#expect(OperationHistory([op, undo]).status(of: op) == .undone(by: undo.id))
		let redo = try UndoService(operations: ops).undo(undo)
		#expect(redo.entries.map(\.status) == [.positionsOnly])
		#expect(try Self.positions(env.ownStore).isEmpty)
		#expect(OperationHistory([op, undo, redo]).status(of: op) == .undoable)
	}

	/// A positions-only folder whose own store cannot be written is recorded as failed; the apply goes on.
	@Test func failedPositionsOnlyIsRecorded() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		try StoreEditor.write(try Self.store(), to: env.ownStore)
		let plan = Self.ownPlan(env.root, after: Self.defaultsAfter())
		try Data("not a store".utf8).write(to: env.ownStore)
		let op = try Applier(operations: env.operations, globals: env.globals).apply(ApplyRequest(plan: plan))
		let entry = try #require(op.entries.first)
		#expect(op.entries.count == 1 && entry.status == .failed && entry.error != nil && entry.folderPath == env.root.path)
		#expect(try Data(contentsOf: env.ownStore) == Data("not a store".utf8))
		#expect(OperationHistory([op]).status(of: op) == .nothingToUndo)
	}
}

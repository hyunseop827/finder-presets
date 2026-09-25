import Foundation
import Testing
import DSStore
@testable import FinderPresetsCore

@Suite struct PlanApplyUndoTests {
	struct Env {
		let root: URL
		let appDir: URL
		let dirs: AppDirectories
		let globals = GlobalDefaults.factory
		/// Removes the whole temporary base folder (root, its parent .DS_Store and the app data).
		func cleanUp() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
	}

	static func makeEnv() throws -> Env {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-e2e-\(UUID().uuidString)")
		let root = base.appendingPathComponent("Root")
		for name in ["A", "A/A1", "B", "C 한글 공간", ".hidden", "Pkg.app", "Pkg.app/Contents"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-A"), withDestinationURL: root.appendingPathComponent("A"))
		// a cycle: A/A1/back -> Root
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("A/A1/back"), withDestinationURL: root)
		let appDir = base.appendingPathComponent("AppData")
		return Env(root: root, appDir: appDir, dirs: AppDirectories(root: appDir))
	}


	@Test func scannerSkipsHiddenPackagesSymlinksAndCycles() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let scanned = FolderScanner(options: ScanOptions()).scan(roots: [env.root])
		let byName: [String: SkipReason?] = Dictionary(uniqueKeysWithValues: scanned.map { ($0.url.lastPathComponent, $0.skipReason) })
		#expect(byName["Root"] == .some(nil))
		#expect(byName["A1"] == .some(nil))
		#expect(byName[".hidden"] == .hidden)
		#expect(byName["Pkg.app"] == .package)
		#expect(byName["link-to-A"] == .symlink)
		#expect(byName["back"] == .symlink)
		#expect(scanned.filter { $0.skipReason == nil }.count == 5) // Root, A, A1, B, C
		let shallow = FolderScanner(options: ScanOptions(maxDepth: 1)).scan(roots: [env.root]).filter { $0.skipReason == nil }
		#expect(!shallow.contains { $0.url.lastPathComponent == "A1" })
	}

	/// A folder's own record — the `"."` key of its own `.DS_Store`, where the home folder's settings live — is applied,
	/// backed up and undone like any other: only that key changes, the records of the folders in it stay as they were.
	@Test func selfRecordApplyAndUndo() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let folder = env.root
		let store = folder.appendingPathComponent(".DS_Store")
		let list = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11))
		// A child's record already in the folder's own store, and the folder's own record as Finder wrote it.
		try StoreEditor.write(try StoreEditor.apply(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 60, arrangeBy: .grid)), to: ".",
		                                            in: try StoreEditor.apply(list, to: "A", in: DSStore(), bases: RecordBases()), bases: RecordBases()), to: store)
		let childBefore = try #require(try StoreEditor.managedRecords(at: store, key: "A"))
		let selfBefore = try #require(try StoreEditor.managedRecords(at: store, key: "."))
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let location = StoreLocation(folder: folder, storeURL: store, key: StoreLocation.selfKey)
		let entry = PlanEntry(folder: folder, depth: 0, location: location, category: .willChange, reason: nil, target: preset.settings,
		                      presetID: preset.id, ruleSource: .defaultPreset, diffs: [])
		let operations = OperationStore(dirs: env.dirs)
		let op = try Applier(operations: operations, globals: env.globals)
			.apply(ApplyRequest(plan: Plan(roots: [folder], entries: [entry]), presetName: preset.name, presetSnapshot: preset.settings))
		#expect(op.summary.changed == 1 && op.entries.first?.key == ".")
		let applied = ViewRecordCodec.decode(try #require(try StoreEditor.managedRecords(at: store, key: ".")))
		// The preset's value, and the folder's other values (the arrangement) kept.
		#expect(applied.icon.iconSize == 88 && applied.icon.arrangeBy == .grid && applied.viewStyle == .icon)
		#expect(try StoreEditor.managedRecords(at: store, key: "A") == childBefore)
		_ = try UndoService(operations: operations).undo(op)
		#expect(try StoreEditor.managedRecords(at: store, key: ".") == selfBefore)
		#expect(try StoreEditor.managedRecords(at: store, key: "A") == childBefore)
	}

	/// "시스템 전체에 적용" outside the standard folders: only folders with view settings of their own are planned —
	/// compared on their own values — and the scan's skipped folders are left out (`PlanOptions.ownSettingsOnly`).
	@Test func ownSettingsOnlyPlansFoldersWithTheirOwnSettings() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let store = env.root.appendingPathComponent(".DS_Store")
		// A differs from the preset, B already holds it, "C 한글 공간" and A1 have nothing of their own.
		let a = try StoreEditor.apply(ViewSettings(viewStyle: .list), to: "A", in: DSStore(), bases: RecordBases())
		try StoreEditor.write(try StoreEditor.apply(preset.settings, to: "B", in: a, bases: RecordBases()), to: store)
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals,
		                      options: PlanOptions(ownSettingsOnly: true))
		let plan = planner.plan(scanned: FolderScanner(options: ScanOptions()).scan(roots: [env.root]), roots: [env.root])
		let byName = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.folder.lastPathComponent, $0.category) })
		#expect(byName == ["A": .willChange, "B": .alreadyMatching], "\(byName)")
		#expect(PlanOptions(ownSettingsOnly: true).pinInheritedDefaults)
	}

	/// What "지금 다시 시작" does after a quitting Finder overwrote parent stores: `holdingWritten` names the
	/// folders that held what the apply wrote before the quit; `writeAgain` puts the recorded `after` back store by store,
	/// each with a backup of its own (the apply's first one stays), keeps every entry's `before`, and reports a store it
	/// cannot read without stopping the others. Folders it was not given are left as they are.
	@Test func writeAgainPutsBackWhatTheOperationWroteStoreByStore() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let finders = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 13))
		let (a, b, a1) = (env.root.appendingPathComponent("A"), env.root.appendingPathComponent("B"), env.root.appendingPathComponent("A/A1"))
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		let roots = [a, b, a1]
		let plan = planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots), roots: roots)
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings))
		#expect(op.summary.changed == 3 && op.backups.count == 2)   // Root/.DS_Store (A, B), A/.DS_Store (A1)
		func name(_ e: OperationEntry) -> String { URL(fileURLWithPath: e.folderPath).lastPathComponent }
		func overwrite(_ folder: URL, with settings: ViewSettings) throws {
			let loc = try ParentStoreLocator.locate(folder)
			let store = try DSStore.read(from: loc.storeURL)
			try StoreEditor.write(try StoreEditor.apply(settings, to: loc.key, in: StoreEditor.restore(ManagedRecordSet(), for: loc.key, in: store),
			                                            bases: env.globals.recordBases), to: loc.storeURL)
		}
		func shown(_ folder: URL) throws -> ViewSettings {
			try Planner.readState(at: ParentStoreLocator.locate(folder), globals: env.globals).explicit
		}
		#expect(Set(applier.holdingWritten(op).map { URL(fileURLWithPath: $0).lastPathComponent }) == ["A", "B", "A1"])

		// Finder's quit: A and A1 overwritten with its own view; A's parent store stays readable, A1's does not.
		try overwrite(a, with: finders)
		try overwrite(a1, with: finders)
		try overwrite(b, with: finders)   // not passed to writeAgain below: stays as it is
		let a1Store = a.appendingPathComponent(".DS_Store")
		let garbage = Data("not a .DS_Store".utf8)
		try garbage.write(to: a1Store)
		let lost = applier.verify(op).filter { ["A", "A1"].contains(name($0)) }
		#expect(lost.count == 2)
		let again = try applier.writeAgain(lost, of: op)
		#expect(Array(again.failed.keys).map { URL(fileURLWithPath: $0).lastPathComponent } == ["A1"])
		#expect(try shown(a).icon.iconSize == 88)
		#expect(try shown(b).list.textSize == 13)
		#expect(try Data(contentsOf: a1Store) == garbage)
		// The record: entries as the apply left them, the first backups kept and one more for Root/.DS_Store.
		let recorded = try ops.load(id: op.id)
		#expect(recorded.entries == again.operation.entries && recorded.backups == again.operation.backups)
		#expect(recorded.entries.map(\.before) == op.entries.map(\.before))
		#expect(recorded.backups.count == 3 && Array(recorded.backups.prefix(2)) == op.backups)
		let extra = try #require(recorded.backups.last)
		#expect(extra.storePath == env.root.appendingPathComponent(".DS_Store").path && extra.backupFile?.hasSuffix("-2.DS_Store") == true)
		let backedUp = try DSStore.read(from: ops.directory(for: op.id).appendingPathComponent(try #require(extra.backupFile)))
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: backedUp, key: "A")).list.textSize == 13)
		#expect(Set(applier.holdingWritten(recorded).map { URL(fileURLWithPath: $0).lastPathComponent }) == ["A"])
		// Undo puts back A's state before the apply (no records of its own), not Finder's.
		_ = try UndoService(operations: ops).undo(recorded)
		#expect(try StoreEditor.managedRecords(at: env.root.appendingPathComponent(".DS_Store"), key: "A")?.isEmpty == true)
	}

	/// `writeAgain` is handed the record as it was read before Finder was quit. It reads it again: a record deleted
	/// meanwhile is not created again (nothing written, every folder failed with `notFound`, no folder for it), and a
	/// pin made meanwhile is kept in the manifest it saves. `removeBackups` takes away only what it is given, and the
	/// folders only when that leaves them empty.
	@Test func writeAgainReadsTheRecordAgain() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88)))
		let finders = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 13))
		let a = env.root.appendingPathComponent("A")
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		let plan = planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: [a]), roots: [a])
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let request = ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings)
		let store = env.root.appendingPathComponent(".DS_Store")
		func overwriteA() throws {
			try StoreEditor.write(try StoreEditor.apply(finders, to: "A", in: StoreEditor.restore(ManagedRecordSet(), for: "A", in: DSStore.read(from: store)),
			                                            bases: env.globals.recordBases), to: store)
		}

		// Deleted before the write again.
		let gone = try applier.apply(request)
		try overwriteA()
		let finderBytes = try Data(contentsOf: store)
		try ops.delete(id: gone.id)
		let refused = try applier.writeAgain(applier.verify(gone), of: gone)
		#expect(refused.failed.count == 1 && (refused.failed.values.first as? OperationStoreError) == .notFound(gone.id))
		#expect(try Data(contentsOf: store) == finderBytes)
		#expect(!FileManager.default.fileExists(atPath: ops.directory(for: gone.id).path) && !ops.hasManifest(id: gone.id))

		// Pinned before the write again: the pin stays, with the new backup.
		let op = try applier.apply(request)
		try overwriteA()
		try ops.setPinned(id: op.id, pinned: true)
		let again = try applier.writeAgain(applier.verify(op), of: op)
		#expect(again.failed.isEmpty && again.operation.pinned && again.operation.backups.count == 2)
		let saved = try ops.load(id: op.id)
		#expect(saved.pinned && saved.backups == again.operation.backups && applier.verify(saved).isEmpty)

		// removeBackups: the files it is given, then the folders it leaves empty — never a folder with anything else in it.
		let extra = try #require(saved.backups.last)
		try ops.delete(id: op.id)
		let dir = ops.directory(for: op.id)
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("backups"), withIntermediateDirectories: true)
		try Data("x".utf8).write(to: dir.appendingPathComponent(try #require(extra.backupFile)))
		try Data("y".utf8).write(to: dir.appendingPathComponent("other"))
		ops.removeBackups([extra], of: op.id)
		#expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("backups").path))
		#expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other").path))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("other"))
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("backups"), withIntermediateDirectories: true)
		try Data("x".utf8).write(to: dir.appendingPathComponent(try #require(extra.backupFile)))
		ops.removeBackups([extra], of: op.id)
		#expect(!FileManager.default.fileExists(atPath: dir.path))
	}

	@Test func planApplyVerifyUndo() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let preset = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88, textSize: 12, arrangeBy: .name)))
		let exception = Preset(name: "List", settings: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11, sortColumn: .dateModified, sortAscending: false)))
		let rules = [FolderRule(path: env.root.appendingPathComponent("B").path, presetID: exception.id)]
		let resolver = RuleResolver(rules: rules, defaultPresetID: preset.id)
		let planner = Planner(presets: [preset, exception], resolver: resolver, globals: env.globals)
		let scanned = FolderScanner(options: ScanOptions()).scan(roots: [env.root])

		// 1. Dry run: nothing written
		let plan = planner.plan(scanned: scanned, roots: [env.root])
		#expect(plan.counts[.willChange] == 5)
		#expect(plan.counts[.excluded] == 4)
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent(".DS_Store").path))
		let bEntry = try #require(plan.entries.first { $0.folder.lastPathComponent == "B" })
		#expect(bEntry.presetID == exception.id)
		#expect(bEntry.target?.viewStyle == .list)

		// 2. Apply
		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings))
		#expect(op.summary.changed == 5 && op.summary.failed == 0)
		#expect(applier.verify(op).isEmpty)
		let stateB = try Planner.readState(at: ParentStoreLocator.locate(env.root.appendingPathComponent("B")), globals: env.globals)
		#expect(stateB.explicit.viewStyle == .list && stateB.explicit.list.textSize == 11)
		let stateA1 = try Planner.readState(at: ParentStoreLocator.locate(env.root.appendingPathComponent("A/A1")), globals: env.globals)
		#expect(stateA1.explicit.icon.iconSize == 88 && stateA1.explicit.viewStyle == .icon)
		// backups recorded: parent of Root (absent), Root, A
		#expect(op.backups.count == 3)
		let loaded = try ops.load(id: op.id)
		#expect(loaded.entries == op.entries && loaded.backups == op.backups && loaded.id == op.id)

		// 3. Second plan: everything matches
		let plan2 = planner.plan(scanned: scanned, roots: [env.root])
		#expect(plan2.counts[.willChange] == nil)
		#expect(plan2.counts[.alreadyMatching] == 5)

		// 4. Undo with a conflict on one folder
		let undo = UndoService(operations: ops)
		let cLoc = try ParentStoreLocator.locate(env.root.appendingPathComponent("C 한글 공간"))
		if case .present(let s) = try StoreEditor.read(cLoc.storeURL) {
			let changed = try StoreEditor.apply(ViewSettings(icon: IconViewSettings(iconSize: 16)), to: cLoc.key, in: s, bases: RecordBases())
			try StoreEditor.write(changed, to: cLoc.storeURL)
		}
		let preview = undo.preview(op)
		#expect(preview.conflicts.map { URL(fileURLWithPath: $0.folderPath).lastPathComponent } == ["C 한글 공간"])
		let undoOp = try undo.undo(op)
		#expect(undoOp.entries.filter { $0.status == .skippedConflict }.count == 1)
		#expect(undoOp.entries.filter { $0.status == .changed }.count == 4)
		let afterUndoB = try StoreEditor.managedRecords(at: cLoc.storeURL, key: "B")
		#expect(afterUndoB?.isEmpty == true)
		let afterUndoC = try StoreEditor.managedRecords(at: cLoc.storeURL, key: "C 한글 공간")
		#expect(afterUndoC?.isEmpty == false)
		// forced undo clears the conflict too
		let undoOp2 = try undo.undo(op, force: true)
		#expect(undoOp2.entries.filter { $0.status == .changed }.map(\.key).contains("C 한글 공간"))
		#expect((try StoreEditor.managedRecords(at: cLoc.storeURL, key: "C 한글 공간") ?? ManagedRecordSet()).isEmpty)  // store itself is gone: apply created it
		#expect(try ops.list().count == 3)
		// stores the apply created (Root's parent, Root, A) are removed again once empty
		#expect(!FileManager.default.fileExists(atPath: env.root.deletingLastPathComponent().appendingPathComponent(".DS_Store").path))
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent("A/.DS_Store").path))
	}

	/// `plan` reads each `.DS_Store` once, however many folders it holds (a parent store: every folder in it; a folder's own
	/// store: its icon positions and its subfolders), checks and lists each parent folder once, and plans exactly what
	/// planning each folder on its own plans, the on-disk spelling of every key included: a parent with many folders (a
	/// decomposed name, a Korean one, some with records of their own), a folder whose own store holds icon positions a
	/// bigger icon size removes, a parent whose store cannot be read and one that cannot be written.
	@Test func planReadsEachStoreOnceAndPlansLikeOneFolderAtATime() throws {
		let fm = FileManager.default
		let base = fm.temporaryDirectory.appendingPathComponent("finder-presets-plan-reads-\(UUID().uuidString)")
		let wide = base.appendingPathComponent("Wide"), broken = base.appendingPathComponent("Broken"), locked = base.appendingPathComponent("Locked")
		defer {
			try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
			try? fm.removeItem(at: base)
		}
		let names = (1...20).map { String(format: "F%02d", $0) } + ["Cafe\u{301}", "한글 폴더"]
		for name in names { try fm.createDirectory(at: wide.appendingPathComponent(name), withIntermediateDirectories: true) }
		for rel in ["F03/Inner", "F04/A/B/C", "F04/A/D"] { try fm.createDirectory(at: wide.appendingPathComponent(rel), withIntermediateDirectories: true) }
		let preset = Preset(name: "Big", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 164)))
		var parent = try StoreEditor.apply(preset.settings, to: "F01", in: DSStore(), bases: RecordBases())
		parent = try StoreEditor.apply(ViewSettings(viewStyle: .list), to: "F02", in: parent, bases: RecordBases())
		parent = try StoreEditor.apply(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, arrangeBy: .grid)), to: "F03", in: parent, bases: RecordBases())
		try StoreEditor.write(parent, to: wide.appendingPathComponent(".DS_Store"))
		var own = try StoreEditor.apply(ViewSettings(viewStyle: .list), to: "Inner", in: DSStore(), bases: RecordBases())
		try own.setIconPosition(for: "Inner", x: 107, y: 102)
		try StoreEditor.write(own, to: wide.appendingPathComponent("F03/.DS_Store"))
		for name in ["X", "Y"] { try fm.createDirectory(at: broken.appendingPathComponent(name), withIntermediateDirectories: true) }
		try Data("not a store".utf8).write(to: broken.appendingPathComponent(".DS_Store"))
		for name in ["P", "Q"] { try fm.createDirectory(at: locked.appendingPathComponent(name), withIntermediateDirectories: true) }
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

		let roots = [wide, broken, locked]
		let scanned = FolderScanner(options: ScanOptions()).scan(roots: roots)
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: .factory, home: base)
		final class Reads { var count: [String: Int] = [:] }
		/// Counts how often each parent folder is checked for writing and listed (`ParentStoreLocator`).
		final class Folders: FileManager, @unchecked Sendable {
			var checks: [String: Int] = [:], listings: [String: Int] = [:]
			override func isWritableFile(atPath path: String) -> Bool {
				checks[path, default: 0] += 1
				return super.isWritableFile(atPath: path)
			}
			override func contentsOfDirectory(atPath path: String) throws -> [String] {
				listings[path, default: 0] += 1
				return try super.contentsOfDirectory(atPath: path)
			}
		}
		let reads = Reads(), folders = Folders()
		let plan = planner.plan(scanned: scanned, roots: roots, stores: StoreReads { url in
			reads.count[url.path, default: 0] += 1
			return try StoreEditor.read(url)
		}, fileManager: folders)
		let oneByOne = scanned.flatMap { planner.plan(scanned: [$0], roots: roots).entries }
		#expect(plan.entries == oneByOne)
		#expect(plan.entries.map { $0.location.map { Array($0.key.unicodeScalars) } } == oneByOne.map { $0.location.map { Array($0.key.unicodeScalars) } })
		#expect(plan.entries.count == scanned.count && scanned.count == 1 + names.count + 5 + 3 + 3)
		#expect(!reads.count.isEmpty && reads.count.values.allSatisfy { $0 == 1 }, "\(reads.count.filter { $0.value > 1 })")
		#expect(reads.count[wide.appendingPathComponent(".DS_Store").path] == 1)
		#expect(folders.checks[wide.path] == 1 && folders.checks.values.allSatisfy { $0 == 1 }, "\(folders.checks.filter { $0.value > 1 })")
		#expect(folders.listings[wide.path] == 1 && folders.listings.values.allSatisfy { $0 == 1 }, "\(folders.listings.filter { $0.value > 1 })")

		func entry(_ url: URL) -> PlanEntry? { plan.entries.first { $0.folder.standardizedFileURL.path == url.standardizedFileURL.path } }
		#expect(entry(wide.appendingPathComponent("F01"))?.category == .alreadyMatching)
		#expect(entry(wide.appendingPathComponent("F02"))?.category == .willChange)
		#expect(entry(wide.appendingPathComponent("F03"))?.resetsIconPositions == true)
		#expect(entry(wide.appendingPathComponent("F03/Inner"))?.diffs.contains { $0.field == "viewStyle" } == true)
		let unreadable = [entry(broken.appendingPathComponent("X")), entry(broken.appendingPathComponent("Y"))]
		#expect(unreadable.allSatisfy { $0?.category == .unreadable } && unreadable[0]?.reason != nil && unreadable[0]?.reason == unreadable[1]?.reason)
		if !fm.isWritableFile(atPath: locked.path) {   // root can write anywhere
			#expect([entry(locked.appendingPathComponent("P")), entry(locked.appendingPathComponent("Q"))].allSatisfy { $0?.category == .unsupported })
		}
	}

	/// The store reads a plan keeps: a file is read once, and dropped once the scan has left its branch (read again when
	/// asked for after that); a file that cannot be read fails the same way each time.
	@Test func storeReadsKeepOnlyTheCurrentBranch() throws {
		var paths: [String] = []
		var reads = StoreReads { url in
			paths.append(url.path)
			if url.path.hasPrefix("/broken/") { throw StoreEditorError.unreadable("x") }
			return .absent
		}
		for path in ["/a/.DS_Store", "/a/b/.DS_Store", "/c/.DS_Store", "/a/.DS_Store", "/c/.DS_Store"] { _ = reads.read(URL(fileURLWithPath: path)) }
		#expect(paths == ["/a/.DS_Store", "/a/b/.DS_Store", "/c/.DS_Store"])
		reads.keepBranch(of: "/a/b/x")
		for path in ["/a/.DS_Store", "/a/b/.DS_Store", "/c/.DS_Store"] { _ = reads.read(URL(fileURLWithPath: path)) }
		#expect(paths == ["/a/.DS_Store", "/a/b/.DS_Store", "/c/.DS_Store", "/c/.DS_Store"])
		reads.keepBranch(of: "/")
		_ = reads.read(URL(fileURLWithPath: "/.DS_Store"))
		reads.keepBranch(of: "/a")
		_ = reads.read(URL(fileURLWithPath: "/.DS_Store"))
		#expect(paths.filter { $0 == "/.DS_Store" }.count == 1)
		let first = reads.read(URL(fileURLWithPath: "/broken/.DS_Store")), again = reads.read(URL(fileURLWithPath: "/broken/.DS_Store"))
		#expect(throws: StoreEditorError.self) { try first.get() }
		#expect(throws: StoreEditorError.self) { try again.get() }
		#expect(paths.filter { $0.hasPrefix("/broken/") }.count == 1)
		#expect(StoreReads.isOnBranch("/", of: "/a") && StoreReads.isOnBranch("/a", of: "/a") && !StoreReads.isOnBranch("/ab", of: "/a/b"))
	}

	/// The grouping (`GRP0`) through plan, apply, verify and undo: a folder without a record of its own is always written
	/// (whether Finder shows it with its global `FXPreferredGroupBy` is unverified), a folder Finder grouped gets the
	/// preset's grouping and its own back on undo, and a manifest recorded before `GRP0` was managed (no `recordCodes`)
	/// is undone without touching the grouping Finder wrote meanwhile.
	@Test func groupByPlanApplyUndo() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let store = env.root.appendingPathComponent(".DS_Store")
		let grp0 = DSStore.RecordType(fourCC: DSStore.FourCC("GRP0")!)
		// B was grouped by kind in Finder; A has no grouping of its own.
		var finder = DSStore()
		finder.add(DSStore.Record(filename: "B", type: grp0, value: .string("Kind")))
		try StoreEditor.write(finder, to: store)
		func group(_ name: String) throws -> DSStore.Value? {
			try DSStore.read(from: store).records.first { $0.filename == name && $0.type == grp0 }?.value
		}
		let preset = Preset(name: "Grouped", settings: ViewSettings(groupBy: GroupBy.none))
		let planner = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: env.globals)
		let roots = [env.root.appendingPathComponent("A"), env.root.appendingPathComponent("B")]
		let scanned = FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: roots)
		let plan = planner.plan(scanned: scanned, roots: roots)
		#expect(plan.counts[.willChange] == 2)
		#expect(plan.entries.first { $0.folder.lastPathComponent == "A" }?.diffs == [FieldDiff(field: "groupBy", current: nil, target: "None")])
		#expect(plan.entries.first { $0.folder.lastPathComponent == "B" }?.diffs == [FieldDiff(field: "groupBy", current: "Kind", target: "None")])

		let ops = OperationStore(dirs: env.dirs)
		let applier = Applier(operations: ops, globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings))
		#expect(op.summary.changed == 2 && op.recordCodes == ManagedRecordSet.managedCodes)
		#expect(applier.verify(op).isEmpty)
		#expect(try group("A") == .string("None") && group("B") == .string("None"))
		#expect(planner.plan(scanned: scanned, roots: roots).counts[.alreadyMatching] == 2)
		// The manifest on disk keeps the grouping in before/after.
		let saved = try #require(try ops.listReadable().operations.first { $0.id == op.id })
		#expect(saved.entries.first { $0.key == "B" }?.before?["GRP0"]?.stringValue == "Kind")

		// Undo: B gets Finder's grouping back, A loses the record the apply added.
		let undo = try UndoService(operations: ops).undo(op)
		#expect(undo.summary.changed == 2 && undo.recordCodes == ManagedRecordSet.managedCodes)
		#expect(try group("A") == nil && group("B") == .string("Kind"))

		// An operation recorded before the grouping was managed, and Finder grouped A afterwards: its undo sees neither a
		// conflict nor a change there, and leaves the grouping alone.
		let iconPreset = Preset(name: "Icon", settings: ViewSettings(icon: IconViewSettings(iconSize: 40)))
		let iconPlanner = Planner(presets: [iconPreset], resolver: RuleResolver(rules: [], defaultPresetID: iconPreset.id), globals: env.globals)
		let a = [env.root.appendingPathComponent("A")]
		var legacy = try applier.apply(ApplyRequest(plan: iconPlanner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: a), roots: a),
		                                            presetName: iconPreset.name, presetSnapshot: iconPreset.settings))
		legacy.recordCodes = nil
		legacy.entries = legacy.entries.map { e in
			var e = e
			e.before = e.before.map { ManagedRecordSet(records: $0.records.filter { $0.type != "GRP0" }) }
			e.after = e.after.map { ManagedRecordSet(records: $0.records.filter { $0.type != "GRP0" }) }
			return e
		}
		try ops.save(legacy)
		var grouped = try DSStore.read(from: store)
		grouped.add(DSStore.Record(filename: "A", type: grp0, value: .string("Date Added")))
		try StoreEditor.write(grouped, to: store)
		let reread = try #require(try ops.listReadable().operations.first { $0.id == legacy.id })
		#expect(reread.recordCodes == nil && reread.managedCodes == ManagedRecordSet.legacyCodes)
		let preview = UndoService(operations: ops).preview(reread)
		#expect(preview.conflicts.isEmpty && preview.restorable.count == 1)
		let legacyUndo = try UndoService(operations: ops).undo(reread)
		#expect(legacyUndo.summary.changed == 1 && legacyUndo.recordCodes == ManagedRecordSet.legacyCodes)
		#expect(try group("A") == .string("Date Added"))
		#expect(try Planner.readState(at: ParentStoreLocator.locate(a[0]), globals: env.globals).explicit.icon.iconSize == nil)
	}

	@Test func presetAndRuleStores() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let ps = PresetStore(dirs: env.dirs)
		let p = Preset(name: "P1", settings: ViewSettings(viewStyle: .column))
		try ps.save(p)
		#expect(try ps.list().map(\.name) == ["P1"])
		let exportURL = env.appDir.appendingPathComponent("p1.json")
		try ps.export(p, to: exportURL)
		let imported = try ps.importPreset(from: exportURL)
		#expect(imported.id != p.id && imported.settings == p.settings)
		#expect(try ps.list().count == 2)
		try ps.delete(id: imported.id)
		#expect(try ps.find(name: "p1")?.id == p.id)
		// One unreadable file (a value this version does not know, as a newer version could write) does not hide the others.
		let future = #"{"createdAt":"0","id":"0E2E0000-0000-4000-8000-0000000000F1","name":"Future","schemaVersion":1,"settings":{"icon":{"arrangeBy":"futureKey"},"list":{}},"updatedAt":"0"}"#
		try Data(future.utf8).write(to: env.dirs.presets.appendingPathComponent("0E2E0000-0000-4000-8000-0000000000F1.json"))
		try Data("{".utf8).write(to: env.dirs.presets.appendingPathComponent("broken.json"))
		let listing = try ps.listReadable()
		#expect(listing.presets.map(\.id) == [p.id])
		#expect(listing.unreadable.count == 2 && listing.unreadable.contains { $0.hasPrefix("broken.json: ") })
		#expect(throws: PresetStoreError.self) { try ps.list() }
		let rs = RuleStore(dirs: env.dirs)
		let doc = RuleStore.Document(rules: [FolderRule(path: "~/Pictures", presetID: p.id)])
		try rs.save(doc)
		#expect(try rs.load() == doc)
		#expect(doc.rules[0].path.hasPrefix("/"))
	}

	/// A rules.json written by an earlier version still has `defaultPresetID` and a rule `note`: it loads, and the next
	/// save (as `finder-presets rule-set` does) keeps the rules and drops the unused keys.
	@Test func legacyRulesFileStillLoads() throws {
		let dirs = AppDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-rules-\(UUID().uuidString)"))
		defer { try? FileManager.default.removeItem(at: dirs.root) }
		try dirs.ensure()
		let legacy = #"""
		{
		  "defaultPresetID" : "0E2E0000-0000-4000-8000-0000000000D1",
		  "rules" : [
		    {
		      "appliesToSubfolders" : false,
		      "id" : "0E2E0000-0000-4000-8000-0000000000A1",
		      "note" : "old note",
		      "path" : "/finder-presets-legacy/Photos",
		      "presetID" : "0E2E0000-0000-4000-8000-0000000000B1"
		    },
		    {
		      "appliesToSubfolders" : true,
		      "id" : "0E2E0000-0000-4000-8000-0000000000A2",
		      "path" : "/finder-presets-legacy/Projects",
		      "presetID" : "0E2E0000-0000-4000-8000-0000000000B2"
		    }
		  ]
		}
		"""#
		try Data(legacy.utf8).write(to: dirs.rules)
		let rs = RuleStore(dirs: dirs)
		var doc = try rs.load()
		#expect(doc.rules.map(\.path) == ["/finder-presets-legacy/Photos", "/finder-presets-legacy/Projects"])
		#expect(doc.rules.map(\.appliesToSubfolders) == [false, true])
		#expect(doc.rules.map(\.presetID.uuidString) == ["0E2E0000-0000-4000-8000-0000000000B1", "0E2E0000-0000-4000-8000-0000000000B2"])
		#expect(doc.rules[0].id.uuidString == "0E2E0000-0000-4000-8000-0000000000A1")

		doc.rules.removeAll { $0.path == "/finder-presets-legacy/Projects" }
		try rs.save(doc)
		#expect(try rs.load() == doc)
		let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dirs.rules)) as? [String: Any])
		let savedRules = try #require(saved["rules"] as? [[String: Any]])
		#expect(Set(saved.keys) == ["rules"])
		#expect(savedRules.map { Set($0.keys) } == [["appliesToSubfolders", "id", "path", "presetID"]])
	}

	@Test func retentionPolicy() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let ops = OperationStore(dirs: env.dirs)
		let now = Date()
		for i in 0..<5 {
			// Finished operations: an unfinished one started a moment ago would count as in progress and be kept outside
			// the limits (HistoryAndRetentionTests has the protection rules).
			let started = now.addingTimeInterval(-Double(i) * 86400 * 10)
			var op = FinderPresetsOperation(kind: .apply, startedAt: started, finishedAt: started, roots: [])
			op.pinned = (i == 4)   // oldest is pinned
			try ops.save(op)
		}
		let removed = try ops.applyRetention(policy: RetentionPolicy(maxCount: 2, maxAge: 25 * 86400), now: now).removed
		let remaining = try ops.list()
		#expect(removed.count == 2)
		#expect(remaining.count == 3)
		#expect(remaining.contains { $0.pinned })
	}
}

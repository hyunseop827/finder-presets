import Foundation
import Testing
import FinderPresetsCore
import DSStore
@testable import FinderPresets

/// "지금 다시 시작" after an apply or a folder undo (`AppModel.restartFinder`), on a temporary tree with a fake Finder
/// (`HistoryModelTests.FakeFinder`) that writes what it holds in memory into the parent store as it quits, as the real
/// one did: what Finder's quit overwrote is written again before Finder is launched, the record keeps the
/// state before the operation (an undo restores it, undoing that undo writes the operation's values again), a folder
/// that had changed before the quit is left alone and named, a pin or a delete made while Finder quits stays, and
/// nothing is written when Finder does not quit. The real Finder, the real home folder and the user's data folder are
/// never touched.
@MainActor @Suite struct FinderRestartTests {
	typealias FakeFinder = HistoryModelTests.FakeFinder

	static let icon = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 72)))
	/// Finder's own list view (text 11) and the one it holds in memory by the time it quits (text 13): they differ, so
	/// a test can tell what the record kept from what Finder wrote.
	static let listBefore = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11))
	static let listInMemory = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 13))

	static func shows(_ folder: URL) -> String { QuickPresetTests.shows(folder) }
	static func names(_ paths: [String]) -> [String] { paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() }
	/// The list text size of the folder's own records (nil: none).
	static func listText(_ records: ManagedRecordSet?) -> Double? { records.flatMap { ViewRecordCodec.decode($0).list.textSize } }
	/// A restart with the folders by name: "quit back leftAlone:B rewritten:A notRewritten: overwritten:".
	static func summary(_ r: FinderRestart) -> String {
		"\(r.quit ? "quit" : "stayed") \(r.back ? "back" : "down") leftAlone:\(names(r.leftAlone).joined(separator: ",")) "
			+ "rewritten:\(names(r.rewritten).joined(separator: ",")) "
			+ "notRewritten:\(names(r.notRewritten).joined(separator: ",")) overwritten:\(names(r.overwritten).joined(separator: ","))"
	}
	static func writes(_ settings: ViewSettings, for folder: URL) { try? QuickPresetTests.finderWrites(settings, for: folder) }
	static func records(_ folder: URL) throws -> ManagedRecordSet? {
		let location = try ParentStoreLocator.locate(folder)
		return try StoreEditor.managedRecords(at: location.storeURL, key: location.key)
	}
	static func tone(_ message: String) -> StatusBar.Tone { StatusBar.tone(status: message, working: false) }

	/// A (list, text 11: Finder's own) and B (no settings) get the icon preset. Before the restart B is changed again
	/// (another tool, or Finder as B's window closed); as Finder quits it writes its own view of both over the parent
	/// store. A — overwritten by the quit alone — is written again before the launch, with the records the apply wrote;
	/// B is left as it is and named, with the advice to apply again. The record keeps A's state before the apply and
	/// gains a backup of the store as Finder left it (the first backup stays), so undoing the apply gives A back its own
	/// list view (text 11, not Finder's 13), and undoing that undo writes the icon view again without a conflict.
	@Test func whatFinderOverwritesAsItQuitsIsWrittenAgain() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		Self.writes(Self.listBefore, for: a)
		let beforeA = try Self.records(a)
		let op = try HistoryModelTests.apply(Self.icon, to: [a, b], env: env)
		#expect(op.summary.changed == 2 && op.backups.count == 1 && Self.shows(a) == "icon 72")
		let entryA = try #require(op.entries.first { Self.names([$0.folderPath]) == ["A"] })
		Self.writes(Self.listInMemory, for: b)   // B changed before the restart: not the quit's doing

		let finder = FakeFinder()
		finder.onQuit = {
			Self.writes(Self.listInMemory, for: a)
			Self.writes(Self.listBefore, for: b)
		}
		finder.onLaunch = { [unowned finder] in finder.note("launch sees A \(Self.shows(a)), B \(Self.shows(b))") }
		let restart = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder)
		#expect(finder.events == ["quit", "launch", "launch sees A icon 72, B Nlsv", "settle"])
		#expect(Self.summary(restart) == "quit back leftAlone:B rewritten:A notRewritten: overwritten:" && restart.reason == nil && !restart.undo)
		#expect(Self.listText(try Self.records(b)) == 11 && Self.shows(b) == "Nlsv")   // B: what Finder wrote, left alone
		// B is named, in warning tone, with what to do; A is said to be written again.
		#expect(restart.message.contains(String(localized: "Finder가 종료하면서 덮어쓴 폴더 \(1)개는 다시 썼습니다.")))
		#expect(restart.message.contains(String(localized: "폴더 \(1)개는 다시 시작하기 전에 이미 쓴 값이 아니어서 다시 쓰지 않았습니다(창을 닫을 때 Finder가 덮어썼거나 다른 곳에서 바뀜).")))
		#expect(restart.message.hasSuffix(String(localized: "폴더가 바뀌지 않았으면 다시 적용하세요.")) && Self.tone(restart.message) == .warning)

		// The record: A's "before" and "after" as the apply recorded them, and a second backup of the parent store that
		// holds it as Finder left it.
		let recorded = try env.store.load(id: op.id)
		let rewrittenA = try #require(recorded.entries.first { $0.folderPath == entryA.folderPath })
		#expect(rewrittenA.before == entryA.before && rewrittenA.before == beforeA)
		#expect(ViewRecordCodec.decode(try #require(rewrittenA.after)) == ViewRecordCodec.decode(try #require(entryA.after)))
		try #require(recorded.backups.count == 2)
		#expect(recorded.backups[0] == op.backups[0] && recorded.backups[1].storePath == op.backups[0].storePath)
		let copy = try #require(recorded.backups[1].backupFile)
		#expect(copy != op.backups[0].backupFile)
		let backup = try DSStore.read(from: env.store.directory(for: op.id).appendingPathComponent(copy))
		#expect(Self.listText(StoreEditor.managedRecords(in: backup, key: "A")) == 13)

		// Undo: A gets back its own list view (the state before the apply); B changed since and is skipped as a conflict.
		let history = try OperationHistory(store: env.store)
		#expect(history.status(of: recorded) == .undoable)
		let undo = try UndoService(operations: env.store).undo(recorded)
		#expect(undo.entries.first { Self.names([$0.folderPath]) == ["A"] }?.status == .changed)
		#expect(undo.entries.first { Self.names([$0.folderPath]) == ["B"] }?.status == .skippedConflict)
		let restoredA = try Self.records(a)
		#expect(restoredA == beforeA && Self.listText(restoredA) == 11)
		// Undoing that undo writes the apply's values again, without a conflict.
		let redo = try UndoService(operations: env.store).undo(undo)
		#expect(redo.entries.first { Self.names([$0.folderPath]) == ["A"] }?.status == .changed && Self.shows(a) == "icon 72")
	}

	/// After a folder undo the same happens the other way: Finder, which still showed the preset, writes it back as it
	/// quits; "지금 다시 시작" writes the undo's result again (no records: the store the apply had created is removed as
	/// the undo left it). The apply stays undone and the undo can itself be undone. A folder the quit overwrote again
	/// after the launch is named with the advice for an undo (the history), not "apply again".
	@Test func whatFinderOverwritesOfAnUndoIsWrittenAgain() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let parentStore = env.root.appendingPathComponent(".DS_Store")
		let op = try HistoryModelTests.apply(Self.icon, to: [a], env: env)
		let undo = try UndoService(operations: env.store).undo(op)
		#expect(Self.shows(a) == "none" && !FileManager.default.fileExists(atPath: parentStore.path))

		let finder = FakeFinder()
		finder.onQuit = { Self.writes(Self.icon.settings, for: a) }   // Finder still showed the preset
		finder.onLaunch = { [unowned finder] in finder.note("launch sees \(Self.shows(a))") }
		let restart = AppModel.restartFinder(after: undo.id, store: env.store, globals: env.globals, finder: finder)
		#expect(finder.events == ["quit", "launch", "launch sees none", "settle"])
		#expect(Self.summary(restart) == "quit back leftAlone: rewritten:A notRewritten: overwritten:" && restart.undo)
		#expect(!FileManager.default.fileExists(atPath: parentStore.path))
		#expect(Self.tone(restart.message) == .success)

		let history = try OperationHistory(store: env.store)
		let recordedUndo = try env.store.load(id: undo.id)
		#expect(history.status(of: try env.store.load(id: op.id)) == .undone(by: undo.id))
		#expect(history.status(of: recordedUndo) == .undoable)
		// The backup of the store as Finder wrote it is there, a file of its own next to the undo's first one.
		try #require(recordedUndo.backups.count == 2)
		#expect(recordedUndo.backups[0] == undo.backups[0])
		#expect(recordedUndo.backups[1].backupFile != nil && recordedUndo.backups[1].backupFile != undo.backups[0].backupFile)
		let redo = try UndoService(operations: env.store).undo(recordedUndo)
		#expect(redo.entries.first?.status == .changed && Self.shows(a) == "icon 72")

		let lost = FinderRestart(quit: true, back: true, undo: true, overwritten: ["/x/A"])
		#expect(lost.message.hasSuffix(String(localized: "툴바의 \"기록\"에서 확인하세요.")) && Self.tone(lost.message) == .warning)
	}

	/// Finder does not quit: nothing is written (the store and the record stay byte for byte), Finder is not launched, and
	/// the status line warns that nothing was written again and to choose "지금 다시 시작" again once Finder can quit (the
	/// app asks the question again; a restart by hand would not write anything again). Without an operation — or with one
	/// whose record is gone — Finder is only restarted. A folder that no longer held the apply's records before the quit
	/// (e.g. Finder wrote over it as its window closed while the question was up) is not written again but named.
	@Test func nothingIsWrittenWhenFinderDoesNotQuitAndNoOperationMeansARestartOnly() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let op = try HistoryModelTests.apply(Self.icon, to: [a], env: env)
		Self.writes(Self.listInMemory, for: a)   // as if Finder had already written over it
		let parentStore = env.root.appendingPathComponent(".DS_Store")
		let manifest = env.store.directory(for: op.id).appendingPathComponent("manifest.json")
		let (storeBytes, manifestBytes) = (try Data(contentsOf: parentStore), try Data(contentsOf: manifest))

		let stays = FakeFinder()
		stays.quitSucceeds = false
		let refused = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: stays)
		#expect(refused == FinderRestart() && stays.events == ["quit"] && stays.isRunning)
		#expect(try Data(contentsOf: parentStore) == storeBytes)
		#expect(try Data(contentsOf: manifest) == manifestBytes)
		#expect(refused.message.contains(String(localized: "지금 다시 시작")) && Self.tone(refused.message) == .warning)

		for id in [nil, UUID()] as [UUID?] {
			let finder = FakeFinder()
			finder.onQuit = { Self.writes(Self.listBefore, for: a) }
			let restart = AppModel.restartFinder(after: id, store: env.store, globals: env.globals, finder: finder)
			#expect(restart == FinderRestart(quit: true, back: true) && finder.events == ["quit", "launch", "settle"])
			#expect(Self.listText(try Self.records(a)) == 11)   // nothing written again
			#expect(Self.tone(restart.message) == .success)
		}
		// The folder no longer held the apply's records before the quit: left alone, and named.
		let finder = FakeFinder()
		let late = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder)
		#expect(late == FinderRestart(quit: true, back: true, leftAlone: [try #require(op.entries.first).folderPath]))
		#expect(try env.store.load(id: op.id).backups.count == 1 && Self.listText(try Self.records(a)) == 11)
		#expect(Self.tone(late.message) == .warning && late.message.hasSuffix(String(localized: "폴더가 바뀌지 않았으면 다시 적용하세요.")))
	}

	/// A parent store Finder left unreadable is not written again: that folder is reported with the reason (the others
	/// are written), Finder is launched all the same, and the status line warns. What is still not as written once Finder
	/// runs again and settled is named too, and a Finder that did not come back is said (nothing waits for it then).
	@Test func failuresAndLossesAreReported() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let op = try HistoryModelTests.apply(Self.icon, to: [a], env: env)
		let parentStore = env.root.appendingPathComponent(".DS_Store")
		let finder = FakeFinder()
		finder.onQuit = { try? Data("not a .DS_Store".utf8).write(to: parentStore) }
		let broken = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder)
		#expect(Self.summary(broken) == "quit back leftAlone: rewritten: notRewritten:A overwritten:A" && broken.reason != nil)
		#expect(finder.events == ["quit", "launch", "settle"])
		#expect(Self.tone(broken.message) == .warning)
		// Named once, as not written again (not a second time as still overwritten), and the advice once.
		#expect(broken.message.contains(broken.reason ?? "?") && !broken.message.contains(String(localized: "폴더 \(1)개는 Finder를 다시 시작한 뒤에도 쓴 값이 아닙니다(Finder가 덮어씀).")))
		#expect(broken.message.hasSuffix(String(localized: "폴더가 바뀌지 않았으면 다시 적용하세요.")))
		#expect((try env.store.load(id: op.id)).backups.count == 1)

		// Written again, then overwritten once more while Finder settles; and Finder that does not come back.
		try FileManager.default.removeItem(at: parentStore)
		let b = env.root.appendingPathComponent("B")
		let second = try HistoryModelTests.apply(Self.icon, to: [b], env: env)
		let settles = FakeFinder()
		settles.onQuit = { Self.writes(Self.listBefore, for: b) }
		settles.onSettle = { Self.writes(Self.listBefore, for: b) }
		let later = AppModel.restartFinder(after: second.id, store: env.store, globals: env.globals, finder: settles)
		#expect(Self.summary(later) == "quit back leftAlone: rewritten:B notRewritten: overwritten:B")
		#expect(later.message.contains(String(localized: "폴더 \(1)개는 Finder를 다시 시작한 뒤에도 쓴 값이 아닙니다(Finder가 덮어씀).")))
		#expect(Self.tone(later.message) == .warning)

		let third = try HistoryModelTests.apply(Self.icon, to: [b], env: env)
		let again = FakeFinder()
		again.onQuit = { Self.writes(Self.listBefore, for: b) }
		again.onLaunch = { Self.writes(Self.listBefore, for: b) }
		again.launchSucceeds = false
		let lost = AppModel.restartFinder(after: third.id, store: env.store, globals: env.globals, finder: again)
		#expect(again.events == ["quit", "launch"])
		#expect(Self.summary(lost) == "quit down leftAlone: rewritten:B notRewritten: overwritten:B")
		#expect(lost.message.hasPrefix(String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")))
		#expect(Self.tone(lost.message) == .warning)

		// Written again and nothing lost: a success that says what was written again.
		let clean = FinderRestart(quit: true, back: true, rewritten: ["/x/A", "/x/B"])
		#expect(Self.tone(clean.message) == .success)
		#expect(clean.message.hasPrefix(String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요.") + " "))
		#expect(Self.tone(FinderRestart(quit: true, back: true).message) == .success)
	}

	/// Writing folders again changes the operation's record after the history sheet read it (a second backup, the
	/// `after` read back), so an open sheet must read it again (`AppModel.relaunchFinder` → `reloadHistoryIfShown`):
	/// `recordMayHaveChanged` says when — whenever `Applier.writeAgain` ran, also when a folder failed or the record was
	/// deleted meanwhile — and not for a restart that wrote nothing again (Finder did not quit, nothing was lost, only
	/// folders left alone), which leaves the record as it was.
	@Test func theHistoryIsReadAgainWhenTheRecordWasWrittenAgain() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A")
		let op = try HistoryModelTests.apply(Self.icon, to: [a], env: env)
		let manifest = env.store.directory(for: op.id).appendingPathComponent("manifest.json")
		let shown = try Data(contentsOf: manifest)   // what the sheet read

		let quiet = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: FakeFinder())
		#expect(Self.summary(quiet) == "quit back leftAlone: rewritten: notRewritten: overwritten:" && !quiet.recordMayHaveChanged)
		#expect(try Data(contentsOf: manifest) == shown)
		let stays = FakeFinder()
		stays.quitSucceeds = false
		#expect(!AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: stays).recordMayHaveChanged)

		let finder = FakeFinder()
		finder.onQuit = { Self.writes(Self.listInMemory, for: a) }
		let restart = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder)
		#expect(Self.summary(restart) == "quit back leftAlone: rewritten:A notRewritten: overwritten:" && restart.recordMayHaveChanged)
		#expect(try Data(contentsOf: manifest) != shown && env.store.load(id: op.id).backups.count == 2)

		#expect(FinderRestart(quit: true, back: true, notRewritten: ["/x/A"], reason: "x").recordMayHaveChanged)
		#expect(!FinderRestart(quit: true, back: true, leftAlone: ["/x/A"], overwritten: ["/x/B"]).recordMayHaveChanged)
	}

	// MARK: Opening the folders again

	/// A record with `roots` and a changed entry for each of `changed` (paths under /x).
	static func record(roots: [String], changed: [String], matching: [String] = [], positionsOnly: [String] = []) -> FinderPresetsOperation {
		func entry(_ path: String, _ status: EntryStatus) -> OperationEntry {
			OperationEntry(folderPath: "/x/" + path, storePath: "/x/.DS_Store", key: path, before: nil, after: ManagedRecordSet(), status: status)
		}
		return FinderPresetsOperation(kind: .apply, roots: roots.map { "/x/" + $0 },
		                              entries: changed.map { entry($0, .changed) } + matching.map { entry($0, .skippedMatching) }
		                                  + positionsOnly.map { entry($0, .positionsOnly) })
	}

	static func opened(_ choice: FolderReopen) -> [String] {
		guard case .open(let folders) = choice else { return ["too many"] }
		return folders.map { String($0.path.dropFirst(3)) }
	}

	/// Which folders "지금 다시 시작" opens: the operation's roots — the rows applied, never their subfolders — in which it
	/// changed something (the root or a folder inside it; a root that was already the same is not opened), each once, in
	/// the record's order, without those that are no longer folders; more than five: none. No operation, or one rooted at
	/// the home folder (the system-wide apply's home folders and their undo): none.
	@Test func theRootsTheOperationChangedAreOpenedAtMostFive() {
		let all: (URL) -> Bool = { _ in true }
		let op = Self.record(roots: ["A", "B", "C", "D", "A"], changed: ["A", "B/B1", "AB"], matching: ["C"], positionsOnly: ["D/D1"])
		// B changed only in its subfolder, D only its icon positions; C was already the same; "AB" is not inside "A".
		#expect(Self.opened(FolderReopen.choose(for: op, isFolder: all)) == ["A", "B", "D"])
		#expect(Self.opened(FolderReopen.choose(for: op, isFolder: { $0.lastPathComponent != "B" })) == ["A", "D"])
		#expect(FolderReopen.choose(for: nil, isFolder: all) == .open([]))
		#expect(FolderReopen.choose(for: Self.record(roots: ["A"], changed: [], matching: ["A"]), isFolder: all) == .open([]))

		let five = ["1", "2", "3", "4", "5"], six = five + ["6"]
		#expect(FolderReopen.limit == 5)
		#expect(Self.opened(FolderReopen.choose(for: Self.record(roots: five, changed: five), isFolder: all)) == five)
		#expect(FolderReopen.choose(for: Self.record(roots: six, changed: six), isFolder: all) == .tooMany(6))
		// A folder that is gone does not count: the other five are opened.
		#expect(Self.opened(FolderReopen.choose(for: Self.record(roots: six, changed: six), isFolder: { $0.lastPathComponent != "3" }))
			== ["1", "2", "4", "5", "6"])

		// A record rooted at the home folder opens nothing: "시스템 전체에 적용"'s home folders ([home] + the standard
		// folders, which that apply's own restart does not open) and the undo of them (it keeps their roots), or a quick
		// preset on the home folder window. The folder list never holds the home folder.
		let home = URL(fileURLWithPath: "/x/Home")
		let system = Self.record(roots: ["Home", "Home/Documents", "Home/Downloads"], changed: ["Home", "Home/Documents/D1", "Home/Downloads"])
		#expect(FolderReopen.choose(for: system, home: home, isFolder: all) == .open([]))
		let undoOfSystem = FinderPresetsOperation(kind: .undo, roots: system.roots, entries: system.entries, undoOfOperationID: system.id)
		#expect(FolderReopen.choose(for: undoOfSystem, home: home, isFolder: all) == .open([]))
		#expect(FolderReopen.choose(for: Self.record(roots: ["Home"], changed: ["Home"]), home: home, isFolder: all) == .open([]))
		// Spelled otherwise (a trailing slash, another case), still the home folder.
		#expect(FolderReopen.choose(for: system, home: URL(fileURLWithPath: "/x/home/"), isFolder: all) == .open([]))
		// Seven of them would not be "too many" either.
		let wide = Self.record(roots: ["Home"] + six.map { "Home/" + $0 }, changed: six.map { "Home/" + $0 })
		#expect(FolderReopen.choose(for: wide, home: home, isFolder: all) == .open([]))
		// Folders inside the home folder that are rows of the list are opened as usual.
		let rows = Self.record(roots: ["Home/Documents", "Home/Downloads"], changed: ["Home/Documents/D1", "Home/Downloads"])
		#expect(Self.opened(FolderReopen.choose(for: rows, home: home, isFolder: all)) == ["Home/Documents", "Home/Downloads"])
	}

	/// "지금 다시 시작" after an apply opens the rows it changed once Finder is back — after the launch, before Finder is
	/// given its moment to settle (what Finder writes as it shows them is still read back) — and names them on the status
	/// line; after a folder undo the same. Six or more: none is opened and the status line says how many and to open them
	/// by hand. Nothing is opened when Finder does not quit or does not come back, nor without an opener (the system-wide
	/// apply's question, and every call that passes none).
	@Test func finderRestartOpensTheFoldersAgain() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let op = try HistoryModelTests.apply(Self.icon, to: [a, b], env: env)
		let finder = FakeFinder()
		let restart = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder) {
			finder.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(finder.events == ["quit", "launch", "open A", "open B", "settle"])
		#expect(Self.names(restart.reopened) == ["A", "B"] && restart.tooManyToReopen == 0)
		let names = Fmt.name("A, B")
		#expect(restart.message == String(localized: "Finder를 다시 시작했습니다.") + " " + String(localized: "폴더 \(2)개를 열었습니다: \(names)."))
		#expect(Self.tone(restart.message) == .success)
		// With the advice after a folder that was not written again, the opened folders still come first.
		let late = FinderRestart(quit: true, back: true, leftAlone: ["/x/A"], reopened: ["/x/A"])
		#expect(late.message.hasPrefix(String(localized: "Finder를 다시 시작했습니다.") + " " + String(localized: "폴더 \(1)개를 열었습니다: \(Fmt.name("A")).")))
		#expect(late.message.hasSuffix(String(localized: "폴더가 바뀌지 않았으면 다시 적용하세요.")) && Self.tone(late.message) == .warning)

		// After undoing it: the same rows.
		let undo = try UndoService(operations: env.store).undo(try env.store.load(id: op.id))
		let undoFinder = FakeFinder()
		let undone = AppModel.restartFinder(after: undo.id, store: env.store, globals: env.globals, finder: undoFinder) {
			undoFinder.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(undoFinder.events == ["quit", "launch", "open A", "open B", "settle"] && undone.undo && Self.names(undone.reopened) == ["A", "B"])
		// A folder the opener could not open is not named as opened.
		let halfFinder = FakeFinder()
		let half = AppModel.restartFinder(after: undo.id, store: env.store, globals: env.globals, finder: halfFinder) { $0.lastPathComponent == "A" }
		#expect(Self.names(half.reopened) == ["A"] && half.message.contains(String(localized: "폴더 \(1)개를 열었습니다: \(Fmt.name("A")).")))
		let noneFinder = FakeFinder()
		let failed = AppModel.restartFinder(after: undo.id, store: env.store, globals: env.globals, finder: noneFinder) { _ in false }
		#expect(failed.reopened.isEmpty && failed.message.hasPrefix(String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요.")))

		// Six rows: none opened.
		var six: [URL] = []
		for name in ["C1", "C2", "C3", "C4", "C5", "C6"] {
			let folder = env.root.appendingPathComponent(name)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			six.append(folder)
		}
		let many = try HistoryModelTests.apply(Self.icon, to: six, env: env)
		let crowded = FakeFinder()
		let tooMany = AppModel.restartFinder(after: many.id, store: env.store, globals: env.globals, finder: crowded) {
			crowded.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(crowded.events == ["quit", "launch", "settle"] && tooMany.reopened.isEmpty && tooMany.tooManyToReopen == 6)
		#expect(tooMany.message == String(localized: "Finder를 다시 시작했습니다.") + " "
			+ String(localized: "폴더가 \(6)개라 열지 않았습니다(한 번에 \(FolderReopen.limit)개까지 엽니다). 필요한 폴더는 직접 여세요."))
		#expect(Self.tone(tooMany.message) == .success)

		// Finder does not quit, does not come back, or no opener: nothing is opened.
		let stays = FakeFinder()
		stays.quitSucceeds = false
		let refused = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: stays) {
			stays.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(stays.events == ["quit"] && refused.reopened.isEmpty)
		let down = FakeFinder()
		down.launchSucceeds = false
		let gone = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: down) {
			down.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(down.events == ["quit", "launch"] && gone.reopened.isEmpty && gone.message.hasPrefix(String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")))
		let quiet = FakeFinder()   // the six rows still hold what they got: a clean restart
		let none = AppModel.restartFinder(after: many.id, store: env.store, globals: env.globals, finder: quiet)
		#expect(quiet.events == ["quit", "launch", "settle"] && none.reopened.isEmpty && none.tooManyToReopen == 0)
		#expect(none.message == String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요."))
		// Without an operation there is nothing to open.
		let bare = FakeFinder()
		let noOperation = AppModel.restartFinder(after: nil, store: env.store, globals: env.globals, finder: bare) {
			bare.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(bare.events == ["quit", "launch", "settle"] && noOperation.reopened.isEmpty)
	}

	/// The record is read before Finder is asked to quit, and the quit can take seconds; what the history does to it
	/// meanwhile stays done. A pin stays (the manifest is saved from a copy read again, with only the new backup and the
	/// `after` values put in). A deleted record is not created again: nothing is written again, the folder keeps what
	/// Finder wrote and is named as not written again, and the operation's folder stays gone.
	@Test func aPinOrADeleteMadeWhileFinderQuitsStays() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let op = try HistoryModelTests.apply(Self.icon, to: [a], env: env)
		let pins = FakeFinder()
		pins.onQuit = {
			_ = try? env.store.setPinned(id: op.id, pinned: true)
			Self.writes(Self.listInMemory, for: a)
		}
		let pinned = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: pins)
		#expect(Self.summary(pinned) == "quit back leftAlone: rewritten:A notRewritten: overwritten:")
		let kept = try env.store.load(id: op.id)
		#expect(kept.pinned && kept.backups.count == 2 && Self.shows(a) == "icon 72")

		let second = try HistoryModelTests.apply(Self.icon, to: [b], env: env)
		let deletes = FakeFinder()
		deletes.onQuit = {
			_ = AppModel.deleteRecords([second.id], store: env.store)
			Self.writes(Self.listInMemory, for: b)
		}
		let deleted = AppModel.restartFinder(after: second.id, store: env.store, globals: env.globals, finder: deletes)
		#expect(Self.summary(deleted) == "quit back leftAlone: rewritten: notRewritten:B overwritten:B")
		#expect(deleted.reason == ErrorText.describe(OperationStoreError.notFound(second.id)))
		#expect(!FileManager.default.fileExists(atPath: env.store.directory(for: second.id).path))
		#expect(Self.listText(try Self.records(b)) == 13)   // what Finder wrote
		#expect(try env.store.load(id: op.id).pinned)   // the other record is untouched
	}
}

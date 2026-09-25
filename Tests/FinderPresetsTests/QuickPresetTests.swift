import Foundation
import Testing
import FinderPresetsCore
import DSStore
@testable import FinderPresets

/// "빠른 적용" (QuickPreset.swift) without Finder: where the star is kept and when it is forgotten, what stops the service
/// before Finder is asked, what Finder's answers to the Apple Event mean, what one folder gets — refused like a folder
/// of the list, the home folder allowed, already the same (Finder left alone) or written (Finder restarted) — and the
/// order of the write with a fake Finder (`HistoryModelTests.FakeFinder`): quit, write, launch, reopen, read back.
/// Temporary folders and an in-memory store only; no AppModel is created (it would open the default data folder), and
/// the real Finder is never asked anything.
@MainActor @Suite struct QuickPresetTests {
	static let icon = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88, arrangeBy: .name)))
	static let list = Preset(name: "List", settings: ViewSettings(viewStyle: .list))

	/// Root/{Folder/Sub, Home/Library, ReadOnly/Inside}; removed by the caller.
	private static func makeTree() throws -> URL {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-quick-\(UUID().uuidString)")
		for name in ["Folder/Sub", "Home/Library", "ReadOnly/Inside"] {
			try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		return base
	}

	/// The star is one preset's ID; it is forgotten (and removed from the store) when that preset is gone — deleted in the
	/// app, or its file removed elsewhere — and a value that is not an ID is removed too.
	@Test func starIsKeptUntilItsPresetIsGone() {
		let setting = QuickPresetSetting.inMemory()
		#expect(setting.id == nil && setting.read() == nil)
		setting.set(Self.icon.id)
		#expect(setting.id == Self.icon.id && setting.read() == Self.icon.id.uuidString)
		#expect(setting.validID(among: [Self.list, Self.icon]) == Self.icon.id && setting.id == Self.icon.id)
		// Its preset deleted: forgotten, also in the store.
		#expect(setting.validID(among: [Self.list]) == nil && setting.read() == nil)
		setting.set(nil)
		#expect(setting.read() == nil)
		let garbage = QuickPresetSetting.inMemory("not an ID")
		#expect(garbage.id == nil && garbage.validID(among: [Self.icon]) == nil && garbage.read() == nil)
		#expect(QuickPresetSetting.key == "quickPresetID")
	}

	/// Before Finder is asked: no star, a star on a preset that is not in the list (a task running and an open dialog come
	/// first: `quickApplyGate`, below).
	@Test func blockerComesBeforeFinderIsAsked() {
		let presets = [Self.icon, Self.list]
		#expect(AppModel.quickApplyBlocker(presets: presets, quickPresetID: Self.icon.id) == nil)
		#expect(AppModel.quickApplyBlocker(presets: presets, quickPresetID: nil) == .noQuickPreset)
		#expect(AppModel.quickApplyBlocker(presets: [Self.list], quickPresetID: Self.icon.id) == .presetMissing)
		// The busy app and the open dialog say so; none of the refusals reads like a finished apply.
		for refusal: QuickApplyRefusal in [.working, .dialogOpen, .noQuickPreset, .presetMissing, .noFolderWindow, .notAllowed, .finderError("x"),
		                                   .missingFolder("/a"), .aboveHome("/"), .unsupported("/a", reason: "r"), .skipped("/a", .excluded),
		                                   .skipped("/a", .permissionDenied), .skipped("/a", .unreadable), .finderDidNotQuit] {
			#expect(!refusal.message.isEmpty && StatusBar.tone(status: refusal.message, working: false) != .success, "\(refusal)")
		}
	}

	/// What is open when the shortcut is pressed (2026-09-25): an error alert that holds only quick-preset refusals is
	/// closed and the press goes on; anything else that is open — a sheet or confirmation of the model, a sheet or panel it
	/// does not know about, an alert with any other message — refuses as before and closes nothing, and a task running
	/// refuses before all of it.
	@Test func aRefusalAlertIsClosedByTheNextPressAndNothingElseIs() {
		typealias Open = QuickApplyOpenDialogs
		func gate(_ open: Open, working: Bool = false) -> QuickApplyGate { AppModel.quickApplyGate(isWorking: working, open: open) }
		#expect(gate(Open()) == .go)
		#expect(gate(Open(errorAlert: .quickRefusals)) == .closeRefusalAlertThenGo)
		// A real error (an unreadable preset file, a failed write) is never closed unseen.
		#expect(gate(Open(errorAlert: .other)) == .refused(.dialogOpen))
		// The editor, the history, the guide, a confirmation, the restart question; a Settings sheet, the rename alert.
		#expect(gate(Open(sheetOrConfirmation: true)) == .refused(.dialogOpen))
		#expect(gate(Open(windowDialog: true)) == .refused(.dialogOpen))
		// A refusal alert with anything else open is left as it is.
		#expect(gate(Open(sheetOrConfirmation: true, errorAlert: .quickRefusals)) == .refused(.dialogOpen))
		#expect(gate(Open(errorAlert: .quickRefusals, windowDialog: true)) == .refused(.dialogOpen))
		#expect(gate(Open(sheetOrConfirmation: true, errorAlert: .other, windowDialog: true)) == .refused(.dialogOpen))
		// Busy first: nothing is closed while a task runs.
		for open in [Open(), Open(errorAlert: .quickRefusals), Open(errorAlert: .other), Open(sheetOrConfirmation: true), Open(windowDialog: true)] {
			#expect(gate(open, working: true) == .refused(.working), "\(open)")
		}
	}

	/// The alert knows whether it holds only quick-preset refusals: a refusal into a closed alert sets that; a second
	/// refusal replaces the first (the new press's reason is what matters); any other message, a text set directly or
	/// closing the alert ends it, and a refusal after another message is added to it without making it closable.
	@Test func theAlertKnowsWhetherItHoldsOnlyRefusals() {
		let first = QuickApplyRefusal.aboveHome("/Users").message, second = QuickApplyRefusal.noFolderWindow.message
		let error = "preset.json: unreadable"
		var alert = ErrorAlert()
		#expect(alert.message == nil && alert.content == .none)
		// Set by a quick refusal.
		alert.reportQuickRefusal(first)
		#expect(alert.message == first && alert.content == .quickRefusals)
		#expect(AppModel.quickApplyGate(isWorking: false, open: QuickApplyOpenDialogs(errorAlert: alert.content)) == .closeRefusalAlertThenGo)
		// Replaced by a second refusal, not stacked.
		alert.reportQuickRefusal(second)
		#expect(alert.message == second && alert.content == .quickRefusals)
		// Cleared by another report, which is added as before.
		alert.report(error)
		#expect(alert.message == "\(second)\n\n\(error)" && alert.content == .other)
		#expect(AppModel.quickApplyGate(isWorking: false, open: QuickApplyOpenDialogs(errorAlert: alert.content)) == .refused(.dialogOpen))
		// A refusal after a real error follows it and does not make the alert closable.
		alert.reportQuickRefusal(first)
		#expect(alert.message == "\(second)\n\n\(error)\n\n\(first)" && alert.content == .other)
		// Cleared by closing the alert ("확인"); a later message is not taken for a refusal.
		alert.set(nil)
		#expect(alert.message == nil && alert.content == .none)
		alert.report(first)
		#expect(alert.message == first && alert.content == .other)
		alert.set(nil)
		// Cleared by a text set directly (`errorMessage = …`), even the same text.
		alert.reportQuickRefusal(first)
		alert.set(first)
		#expect(alert.message == first && alert.content == .other)
		// A refusal into an alert that holds a real error.
		alert.set(error)
		alert.reportQuickRefusal(second)
		#expect(alert.message == "\(error)\n\n\(second)" && alert.content == .other)
		// Closed, then a refusal again: closable again.
		alert.set(nil)
		alert.reportQuickRefusal(second)
		#expect(alert.message == second && alert.content == .quickRefusals)
	}

	@MainActor private final class Sheet { var gone = false }

	/// The wait for a closed alert's sheet to go (`FinderServiceProvider.waitUntilNoDialog`, built on `waitUntil`): it
	/// waits at most `dialogWait` (about a second), checks at once before any sleep, then polls, ends as soon as the
	/// condition holds, gives up after its timeout, and leaves the main actor free in between (a task queued on it runs
	/// while it waits).
	@Test func theWaitForTheAlertToGoIsShortAndLeavesTheMainActorFree() async {
		// The bound `waitUntilNoDialog` uses.
		#expect(FinderServiceProvider.dialogWait > .zero && FinderServiceProvider.dialogWait <= .seconds(1))
		// At once: a condition that already holds returns without sleeping. With a 30-second interval, a wait that slept
		// before its first check would take 30 seconds; nothing suspends here, so a busy main actor cannot slow it.
		let clock = ContinuousClock()
		var checks = 0
		var start = clock.now
		#expect(await FinderServiceProvider.waitUntil(timeout: .seconds(60), interval: .seconds(30)) { checks += 1; return true })
		#expect(checks == 1 && clock.now - start < .seconds(10), "\(clock.now - start), \(checks) checks")
		// The timeouts are long where the wait must succeed: it ends when the condition holds, and the other tests of the
		// run can keep the main actor busy for many seconds.
		checks = 0
		#expect(await FinderServiceProvider.waitUntil(timeout: .seconds(60), interval: .milliseconds(5)) { checks += 1; return checks == 3 })
		#expect(checks == 3)
		// Something else on the main actor makes the condition true while the wait sleeps.
		let sheet = Sheet()
		Task { @MainActor in sheet.gone = true }
		#expect(!sheet.gone)
		#expect(await FinderServiceProvider.waitUntil(timeout: .seconds(60), interval: .milliseconds(5)) { sheet.gone })
		// Never true: false once the timeout has passed, having checked again after sleeping.
		checks = 0
		start = clock.now
		#expect(await !FinderServiceProvider.waitUntil(timeout: .milliseconds(200), interval: .milliseconds(20)) { checks += 1; return false })
		let waited = clock.now - start
		#expect(waited >= .milliseconds(200) && checks >= 2, "\(waited), \(checks) checks")
	}

	/// Finder's answers to "POSIX path of (target of front Finder window as alias)".
	@Test func finderErrorsMeanNoFolderWindowOrNoPermission() {
		#expect(FrontFinderWindow.refusal(errorNumber: -1728, message: "Can’t get Finder window 1.") == .noFolderWindow)
		#expect(FrontFinderWindow.refusal(errorNumber: -1700, message: "Can’t make … into type alias.") == .noFolderWindow)
		#expect(FrontFinderWindow.refusal(errorNumber: -1743, message: "Not authorized to send Apple events to Finder.") == .notAllowed)
		#expect(FrontFinderWindow.refusal(errorNumber: -600, message: "Application isn’t running.") == .finderError("Application isn’t running."))
		#expect(FrontFinderWindow.refusal(errorNumber: nil, message: nil) == .finderError("?"))
		#expect(FrontFinderWindow.source.contains("front Finder window") && FrontFinderWindow.source.contains("POSIX path"))
	}

	/// What the list and "선택한 폴더에 적용" refuse for a single folder is refused here too: no star, a missing preset, a
	/// folder that is gone, the root and the folders above the home folder, ~/Library (always skipped), a folder whose
	/// parent cannot be written. Nothing is written for any of them.
	@Test func refusesWhatTheFolderListRefuses() throws {
		let tree = try Self.makeTree()
		let readOnly = tree.appendingPathComponent("ReadOnly")
		defer {
			try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
			try? FileManager.default.removeItem(at: tree)
		}
		let home = tree.appendingPathComponent("Home")
		let folder = FolderRule.normalize(tree.appendingPathComponent("Folder").path)
		func decide(_ path: String, id: UUID? = Self.icon.id) -> QuickApplyDecision {
			AppModel.quickApplyDecision(folder: path, presets: [Self.icon, Self.list], quickPresetID: id, globals: .factory, home: home)
		}
		#expect(decide(folder, id: nil) == .refused(.noQuickPreset))
		#expect(decide(folder, id: UUID()) == .refused(.presetMissing))
		let gone = FolderRule.normalize(tree.appendingPathComponent("Gone").path)
		#expect(decide(gone) == .refused(.missingFolder(gone)))
		#expect(decide("/") == .refused(.aboveHome("/")))
		#expect(decide(FolderRule.normalize(tree.path)) == .refused(.aboveHome(FolderRule.normalize(tree.path))))
		let library = FolderRule.normalize(home.appendingPathComponent("Library").path)
		#expect(decide(library) == .refused(.skipped(library, .excluded)))
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
		let inside = FolderRule.normalize(readOnly.appendingPathComponent("Inside").path)
		guard case .refused(.unsupported(let path, let reason)) = decide(inside) else {
			Issue.record("a folder whose parent cannot be written: \(decide(inside))")
			return
		}
		#expect(path == inside && reason == ErrorText.describe(LocatorError.parentNotWritable(readOnly.path)))
		#expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent(".DS_Store").path))
	}

	/// The home folder itself is not refused as a folder above home (compared with the `home` given); a folder is planned
	/// alone, without its subfolders. The test's home is planned like any folder (its record in its parent's `.DS_Store`):
	/// `ParentStoreLocator` gives the real home folder its "." record, which unit tests do not reach, as they never read
	/// the real home. A folder that changes is applied (and Finder restarted by the caller); applied once, the same
	/// folder already matches, so nothing is written and Finder is left alone.
	@Test func oneFolderIsAppliedOnceThenMatches() throws {
		let tree = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: tree) }
		let home = tree.appendingPathComponent("Home")
		let folder = tree.appendingPathComponent("Folder")
		func decide(_ url: URL) -> QuickApplyDecision {
			AppModel.quickApplyDecision(folder: url.path, presets: [Self.icon, Self.list], quickPresetID: Self.icon.id, globals: .factory, home: home)
		}
		guard case .apply(let preset, let homePlan) = decide(home) else { Issue.record("home folder refused: \(decide(home))"); return }
		#expect(preset == Self.icon && homePlan.entries.count == 1 && homePlan.changes.count == 1)

		guard case .apply(_, let plan) = decide(folder) else { Issue.record("folder not applied: \(decide(folder))"); return }
		#expect(plan.roots.map { FolderRule.normalize($0.path) } == [FolderRule.normalize(folder.path)])
		#expect(plan.entries.map { FolderRule.normalize($0.folder.path) } == [FolderRule.normalize(folder.path)] && plan.entries[0].depth == 0)
		let store = OperationStore(dirs: AppDirectories(root: tree.appendingPathComponent("AppData")))
		let op = try Applier(operations: store, globals: .factory).apply(ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings))
		#expect(op.summary.changed == 1 && op.kind == .apply && op.presetName == Self.icon.name)
		#expect(try store.load(id: op.id).entries.count == 1)
		// Sub was not written: Folder's own .DS_Store (where Sub's settings would go) does not exist.
		#expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path))
		#expect(decide(folder) == .alreadyMatching(Self.icon))
	}

	// MARK: The write and Finder

	/// Finder's own view of a folder that never had settings of its own, as it wrote it for ~/FinderPresets-Test/Q when it
	/// quit with that window open: list records (text 13, small icons, by name) and no view style.
	static let finderListView = ViewSettings(list: ListViewSettings(textSize: 13, iconSize: 16, sortColumn: .name))

	/// What a quitting Finder did with the folder it showed: every view record of it in the parent store
	/// replaced by its own state.
	static func finderWrites(_ settings: ViewSettings, for folder: URL) throws {
		let location = try ParentStoreLocator.locate(folder)
		var store: DSStore
		switch try StoreEditor.read(location.storeURL) {
		case .absent: store = DSStore()
		case .present(let s): store = s
		}
		store = StoreEditor.restore(ManagedRecordSet(), for: location.key, in: store)
		try StoreEditor.write(try StoreEditor.apply(settings, to: location.key, in: store, bases: GlobalDefaults.factory.recordBases), to: location.storeURL)
	}

	/// What the folder's own records say: "icon 88", "Nlsv", "records without a view style" (Finder's list records), "none".
	static func shows(_ folder: URL) -> String {
		guard let location = try? ParentStoreLocator.locate(folder), let state = try? Planner.readState(at: location, globals: .factory),
		      state.hasExplicitRecords else { return "none" }
		guard let style = state.explicit.viewStyle else { return "records without a view style" }
		return style == .icon ? "icon \(Int(state.explicit.icon.iconSize ?? 0))" : style.rawValue
	}

	/// A tree whose "Folder" the quick preset (Icon88) changes, the request it writes and a store for its record.
	private static func quickRequest() throws -> (tree: URL, folder: URL, request: ApplyRequest, store: OperationStore, applier: Applier) {
		let tree = try makeTree()
		let folder = tree.appendingPathComponent("Folder")
		let decision = AppModel.quickApplyDecision(folder: folder.path, presets: [icon], quickPresetID: icon.id, globals: .factory,
		                                           home: tree.appendingPathComponent("Home"))
		guard case .apply(let preset, let plan) = decision else { throw CancellationError() }
		let store = OperationStore(dirs: AppDirectories(root: tree.appendingPathComponent("AppData")))
		return (tree, folder, ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings), store,
		        Applier(operations: store, globals: .factory))
	}

	/// The first press on Q again, with a fake Finder that writes its own list view of the folder when it quits,
	/// as the real one did: Finder is quit before anything is written, so the write comes after Finder's own last write
	/// and holds — the first press changes the folder. The recorded "before" is what Finder showed (its list records),
	/// the records Finder wrote that the preset does not set are kept, and the launch, the reopening, the wait for Finder
	/// to settle and the read-back come after the write.
	@Test func quitsFinderBeforeTheWriteAndReopensAfterIt() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let finder = HistoryModelTests.FakeFinder()
		finder.onQuit = { [unowned finder] in
			finder.note("quit sees \(Self.shows(q.folder))")
			try? Self.finderWrites(Self.finderListView, for: q.folder)
		}
		finder.onLaunch = { [unowned finder] in finder.note("launch sees \(Self.shows(q.folder))") }
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: true, finder: finder) {
			finder.note("reopen sees \(Self.shows(q.folder))")
		}
		#expect(finder.events == ["quit", "quit sees none", "launch", "launch sees icon 88", "reopen sees icon 88", "settle"])
		#expect(write.finder == .restarted(back: true) && write.changed && write.error == nil && write.overwritten.isEmpty && !write.needsAttention)
		let state = try Planner.readState(at: ParentStoreLocator.locate(q.folder), globals: .factory)
		#expect(state.explicit.viewStyle == .icon && state.explicit.icon.iconSize == 88 && state.explicit.icon.arrangeBy == .name)
		#expect(state.explicit.list.textSize == 13 && state.explicit.list.iconSize == 16)   // Finder's own records, kept
		let op = try #require(write.operation)
		let entry = try #require(op.entries.first)
		#expect(op.entries.count == 1 && entry.status == .changed)
		let before = ViewRecordCodec.decode(try #require(entry.before))   // "before" = what Finder showed
		#expect(before.viewStyle == nil && before.icon == IconViewSettings() && before.list.textSize == 13 && before.list.iconSize == 16)
		// Undoing it brings back Finder's own view, not a folder without settings.
		_ = try UndoService(operations: q.store).undo(try q.store.load(id: op.id))
		#expect(Self.shows(q.folder) == "records without a view style")
	}

	/// Finder does not quit (a copy in progress): nothing is written or recorded, Finder is not launched, the folder is not
	/// opened, and the service refuses like the others.
	@Test func nothingIsWrittenWhenFinderDoesNotQuit() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let finder = HistoryModelTests.FakeFinder()
		finder.quitSucceeds = false
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: true, finder: finder) { finder.note("reopen") }
		#expect(write.finder == .didNotQuit && write.operation == nil && write.error == nil)
		#expect(finder.events == ["quit"] && finder.isRunning)
		#expect(!FileManager.default.fileExists(atPath: q.tree.appendingPathComponent(".DS_Store").path))
		#expect(try q.store.list().isEmpty)
		#expect(Self.shows(q.folder) == "none")
		#expect(QuickApplyRefusal.finderDidNotQuit.message.contains("Finder가 종료되지 않아"))
	}

	/// The read-back runs once Finder was launched, the folder reopened and Finder given a moment to settle: what Finder
	/// writes by then (here while it settles, after the reopening) is reported, and the status line says so instead of
	/// claiming success. When Finder does not come back, the write stays (recorded), the folder is not opened, nothing
	/// waits for it and the status line says to start Finder.
	@Test func whatIsLostAfterTheLaunchIsReportedAndAMissingFinderIsNamed() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let finder = HistoryModelTests.FakeFinder()
		finder.onSettle = { try? Self.finderWrites(Self.finderListView, for: q.folder) }
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: true, finder: finder) { finder.note("reopen") }
		#expect(finder.events == ["quit", "launch", "reopen", "settle"])
		#expect(write.finder == .restarted(back: true) && write.changed && write.overwritten == [q.request.plan.entries[0].folder.path])
		let lost = write.message(folder: "Folder", preset: "Icon88")
		#expect(lost.contains("덮어썼습니다") && StatusBar.tone(status: lost, working: false) == .warning && write.needsAttention)

		let r = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: r.tree) }
		let gone = HistoryModelTests.FakeFinder()
		gone.launchSucceeds = false
		let down = AppModel.quickApplyWrite(r.request, folder: r.folder, applier: r.applier, restartsFinder: true, finder: gone) { gone.note("reopen") }
		#expect(gone.events == ["quit", "launch"] && !gone.isRunning)
		#expect(down.finder == .restarted(back: false) && down.changed && Self.shows(r.folder) == "icon 88")
		#expect(try r.store.list().count == 1)
		let message = down.message(folder: "Folder", preset: "Icon88")
		#expect(message.hasSuffix(String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")))
		#expect(StatusBar.tone(status: message, working: false) == .warning && down.needsAttention)
	}

	/// A write that fails once Finder was already quit (here the parent store Finder left behind cannot be read) still
	/// restarted Finder, which closed its other windows: the status line says that the folder was not written and that
	/// Finder was restarted and the folder opened again, and reads as a warning. A write that stopped with an error (a
	/// manifest that could not be saved) after the restart says so too, as a segment of its own after " · " (the line
	/// before it ends in a parenthesis); a Finder that did not come back is named instead.
	@Test func aFailedWriteStillSaysFinderWasRestarted() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let finder = HistoryModelTests.FakeFinder()
		finder.onQuit = { try? Data("not a .DS_Store".utf8).write(to: q.tree.appendingPathComponent(".DS_Store")) }
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: true, finder: finder) { finder.note("reopen") }
		#expect(finder.events == ["quit", "launch", "reopen", "settle"])
		#expect(write.finder == .restarted(back: true) && !write.changed && write.error == nil && write.operation?.summary.failed == 1)
		let name = "Folder", restarted = " " + String(localized: "Finder를 다시 시작하고 이 폴더를 다시 열었습니다.")
		let message = write.message(folder: name, preset: "Icon88")
		#expect(message == String(localized: "빠른 적용: \(name)에 쓰지 못했습니다(실패). 툴바의 \"기록\"에서 이 작업을 확인하세요.") + restarted)
		#expect(StatusBar.tone(status: message, working: false) == .warning && write.needsAttention)

		// The stopped line ends in a parenthesis: the note is its own " · " segment, not glued to it.
		let stopped = QuickApplyWrite(finder: .restarted(back: true), operation: nil, error: "manifest")
		let changedNote = String(localized: "일부 폴더는 이미 변경됐을 수 있습니다 (되돌리기: 툴바의 \"기록\")")
		#expect(stopped.message(folder: name, preset: "Icon88") == String(localized: "중단: manifest") + " · " + changedNote
			+ " · " + String(localized: "Finder를 다시 시작하고 이 폴더를 다시 열었습니다."))
		let failedLaunch = String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")
		let stoppedDown = QuickApplyWrite(finder: .restarted(back: false), operation: nil, error: "manifest")
		#expect(stoppedDown.message(folder: name, preset: "Icon88").hasSuffix(changedNote + " · " + failedLaunch))
		let stoppedAlone = QuickApplyWrite(finder: .leftAlone, operation: nil, error: "manifest")
		#expect(stoppedAlone.message(folder: name, preset: "Icon88") == String(localized: "중단: manifest") + " · " + changedNote)
		let down = QuickApplyWrite(finder: .restarted(back: false), operation: write.operation)
		let downMessage = down.message(folder: name, preset: "Icon88")
		#expect(!downMessage.contains(restarted) && downMessage.hasSuffix(" " + failedLaunch))
		// The development hooks never restart Finder, and their failed write does not claim it.
		let leftAlone = QuickApplyWrite(finder: .leftAlone, operation: write.operation)
		#expect(!leftAlone.message(folder: name, preset: "Icon88").contains(restarted))
	}

	// MARK: What the front window shows (Finder writes a view changed in a window lazily)

	static func code(_ s: String) -> FourCharCode { FinderCode.make(s) }
	/// What Finder answers for an icon view window: 88 points, arranged by name, text 12, labels at the bottom.
	static let iconWindow = FinderWindowView(view: code("icnv"), iconSize: 88, arrangement: code("nama"), textSize: 12, labelPosition: code("lbot"))

	/// The window against the preset: the view style, and for an icon view the icon size (whole points) and the arrangement,
	/// which must have been read, and the text size and label position when read; for a list view its icon size and text
	/// size when read. What the preset leaves as "유지" and the options of a view the window does not show are never
	/// compared; a view that was not read or is unknown is `unknown`, and so is an icon size or arrangement not read or
	/// not known. A value that differs wins over one that is unknown.
	@Test func theWindowIsComparedWithWhatThePresetSets() {
		let icon = Self.icon.settings   // icon view, 88, by name
		#expect(Self.iconWindow.compared(with: icon) == .same)
		#expect(Self.iconWindow.style == .icon && Self.iconWindow.arrangeBy == .name && Self.iconWindow.labelOnBottom == true)
		var window = Self.iconWindow
		window.iconSize = 87.6   // whole points
		#expect(window.compared(with: icon) == .same)
		// ⌘2 in the window — list view — while the file still holds the icon view.
		#expect(FinderWindowView(view: Self.code("lsvw"), listIconSize: 16, listTextSize: 13).compared(with: icon) == .differs)
		window = Self.iconWindow
		window.iconSize = 64
		#expect(window.compared(with: icon) == .differs)
		let grid = ViewSettings(viewStyle: .icon, icon: IconViewSettings(arrangeBy: .grid))
		window = Self.iconWindow
		window.arrangement = Self.code("narr")   // not arranged
		#expect(window.style == .icon && window.arrangeBy == SortKey.none && window.compared(with: grid) == .differs)
		window.arrangement = Self.code("grda")
		#expect(window.compared(with: grid) == .same)
		// Text size and label position count when read, and only then.
		window = Self.iconWindow
		window.textSize = 16
		#expect(window.compared(with: ViewSettings(viewStyle: .icon, icon: IconViewSettings(textSize: 12))) == .differs)
		window.textSize = nil
		window.labelPosition = nil
		#expect(window.compared(with: ViewSettings(viewStyle: .icon, icon: IconViewSettings(textSize: 12, labelOnBottom: false))) == .same)
		window.labelPosition = Self.code("lrgt")
		#expect(window.compared(with: ViewSettings(icon: IconViewSettings(labelOnBottom: true))) == .differs)

		// Not read, or not known: unknown — also an icon size or an arrangement that is missing or has an unknown code.
		#expect(FinderWindowView.unread.compared(with: icon) == .unknown)
		#expect(FinderWindowView(view: Self.code("zzzz")).compared(with: ViewSettings()) == .unknown)
		#expect(FinderWindowView(view: Self.code("icnv")).compared(with: icon) == .unknown)
		window = Self.iconWindow
		window.arrangement = Self.code("dadd")   // a code Finder's dictionary does not list
		#expect(window.arrangeBy == nil && window.compared(with: icon) == .unknown)
		// A preset arranged by a key the dictionary has no code for is never confirmed, whatever code Finder answers.
		for key in [SortKey.dateAdded, .dateLastOpened] {
			let codeless = ViewSettings(viewStyle: .icon, icon: IconViewSettings(arrangeBy: key))
			#expect(Self.iconWindow.compared(with: codeless) == .unknown)
			var unanswered = Self.iconWindow
			unanswered.arrangement = nil
			#expect(unanswered.compared(with: codeless) == .unknown)
		}
		var smaller = Self.iconWindow
		smaller.iconSize = 64   // differs wins over unknown
		#expect(smaller.compared(with: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88, arrangeBy: .dateAdded))) == .differs)
		window.iconSize = 64
		#expect(window.compared(with: icon) == .differs)

		// Item info and icon preview (icon view), and the list's icon preview, relative dates, calculated sizes and sort
		// column: compared when read, and only then.
		window = Self.iconWindow
		let infoOn = ViewSettings(viewStyle: .icon, icon: IconViewSettings(showItemInfo: true, showIconPreview: true))
		#expect(window.compared(with: infoOn) == .same)
		window.showsItemInfo = true
		window.showsIconPreview = true
		#expect(window.compared(with: infoOn) == .same)
		window.showsItemInfo = false
		#expect(window.compared(with: infoOn) == .differs)
		window.showsItemInfo = true
		window.showsIconPreview = false
		#expect(window.compared(with: infoOn) == .differs)
		let listOptions = ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .kind, showIconPreview: true, useRelativeDates: false, calculateAllSizes: true))
		var listed = FinderWindowView(view: Self.code("lsvw"), listIconSize: 16, listTextSize: 13)
		#expect(listed.compared(with: listOptions) == .same)
		listed.listShowsIconPreview = true
		listed.listUsesRelativeDates = false
		listed.listCalculatesFolderSizes = true
		listed.listSortColumn = Self.code("elsk")
		#expect(listed.sortColumn == .kind && listed.compared(with: listOptions) == .same)
		let changes: [(inout FinderWindowView) -> Void] = [{ $0.listShowsIconPreview = false }, { $0.listUsesRelativeDates = true },
		                                                   { $0.listCalculatesFolderSizes = false }, { $0.listSortColumn = Self.code("elsn") }]
		for change in changes {
			var other = listed
			change(&other)
			#expect(other.compared(with: listOptions) == .differs)
		}
		// A sort column without a code (date added, date last opened) or one Finder answers with a code this app does not
		// know is not compared, like one not read.
		#expect(listed.compared(with: ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .dateAdded))) == .same)
		listed.listSortColumn = Self.code("zzzz")
		#expect(listed.sortColumn == nil && listed.compared(with: listOptions) == .same)
		// The list's options are not compared in an icon view, nor the icon view's in a list view.
		#expect(Self.iconWindow.compared(with: ViewSettings(list: ListViewSettings(showIconPreview: false))) == .same)
		listed.listShowsIconPreview = false
		#expect(listed.compared(with: ViewSettings(icon: IconViewSettings(showIconPreview: true))) == .same)

		// "유지" is not compared: a preset without a view style or an icon size takes the window as it is.
		#expect(FinderWindowView(view: Self.code("clvw")).compared(with: ViewSettings(icon: IconViewSettings(iconSize: 88))) == .same)
		window = Self.iconWindow
		window.iconSize = 32
		#expect(window.compared(with: ViewSettings(viewStyle: .icon, icon: IconViewSettings(arrangeBy: .name))) == .same)
		#expect(window.compared(with: ViewSettings(groupBy: .kind)) == .same)
		// The options of a view the window does not show are not compared.
		let listWindow = FinderWindowView(view: Self.code("lsvw"), listIconSize: 32, listTextSize: 13)
		#expect(listWindow.compared(with: ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 88), list: ListViewSettings(textSize: 13, iconSize: 32))) == .same)
		#expect(listWindow.compared(with: ViewSettings(viewStyle: .list, list: ListViewSettings(iconSize: 16))) == .differs)
		#expect(listWindow.compared(with: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11))) == .differs)
		#expect(FinderWindowView(view: Self.code("lsvw")).compared(with: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11))) == .same)
		// Gallery comes back as "flow view"; column view.
		#expect(FinderWindowView(view: Self.code("flvw")).compared(with: ViewSettings(viewStyle: .gallery)) == .same)
		#expect(FinderWindowView(view: Self.code("clvw")).compared(with: ViewSettings(viewStyle: .gallery)) == .differs)
	}

	/// The script's answer is read by descriptor type and four-char code: the folder first, then the view and the options
	/// of an icon or a list view. A view that was not answered leaves the path; no path is no folder window.
	@Test func finderAnswersAreReadByCode() throws {
		func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
			let list = NSAppleEventDescriptor.list()
			for (i, item) in items.enumerated() { list.insert(item, at: i + 1) }
			return list
		}
		func text(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }
		func enumerator(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(enumCode: Self.code(s)) }
		func int(_ n: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: n) }

		func boolean(_ b: Bool) -> NSAppleEventDescriptor { NSAppleEventDescriptor(boolean: b) }
		func typed(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(descriptorType: Self.code(s), data: nil) ?? text("?") }

		let icon = try #require(FrontFinderWindow.parse(list([text("/x/Folder/"), enumerator("icnv"), int(88), enumerator("nama"), int(12), enumerator("lbot")])))
		#expect(icon == FrontFinderWindow.Answer(path: "/x/Folder/", view: Self.iconWindow))
		let listed = try #require(FrontFinderWindow.parse(list([text("/x/L"), enumerator("lsvw"), enumerator("lgic"), int(13)])))
		#expect(listed.view == FinderWindowView(view: Self.code("lsvw"), listIconSize: 32, listTextSize: 13) && listed.view.style == .list)
		// The booleans and the sort column after them: `bool`, or `true`/`fals` without data; the column as an elsv code.
		let iconAll = try #require(FrontFinderWindow.parse(list([text("/x/I"), enumerator("icnv"), int(88), enumerator("nama"), int(12), enumerator("lbot"),
		                                                        boolean(true), typed("fals")])))
		#expect(iconAll.view.showsItemInfo == true && iconAll.view.showsIconPreview == false && iconAll.view.iconSize == 88)
		let listAll = try #require(FrontFinderWindow.parse(list([text("/x/L"), enumerator("lsvw"), enumerator("smic"), int(12),
		                                                        typed("true"), boolean(false), boolean(true), enumerator("elsm")])))
		#expect(listAll.view == FinderWindowView(view: Self.code("lsvw"), listIconSize: 16, listTextSize: 12, listShowsIconPreview: true,
		                                         listUsesRelativeDates: false, listCalculatesFolderSizes: true, listSortColumn: Self.code("elsm")))
		#expect(listAll.view.sortColumn == .dateModified)
		// Cut short after a step (an option Finder did not answer): the ones before it stay.
		let cut = try #require(FrontFinderWindow.parse(list([text("/x/L"), enumerator("lsvw"), enumerator("lgic"), int(13), boolean(false), boolean(true), boolean(false)])))
		#expect(cut.view.listShowsIconPreview == false && cut.view.listCalculatesFolderSizes == false && cut.view.listSortColumn == nil)
		// A boolean is not read from a number or a text, nor a column from a text.
		let wrong = try #require(FrontFinderWindow.parse(list([text("/x/L"), enumerator("lsvw"), enumerator("lgic"), int(13), int(1), text("true"), int(0), text("name column")])))
		#expect(wrong.view.listShowsIconPreview == nil && wrong.view.listUsesRelativeDates == nil && wrong.view.listCalculatesFolderSizes == nil
			&& wrong.view.listSortColumn == nil)
		let small = try #require(FrontFinderWindow.parse(list([text("/x/L"), enumerator("lsvw"), enumerator("smic")])))
		#expect(small.view.listIconSize == 16 && small.view.listTextSize == nil)
		let column = try #require(FrontFinderWindow.parse(list([text("/x/C"), enumerator("clvw")])))
		#expect(column.view == FinderWindowView(view: Self.code("clvw")) && column.view.style == .column)
		#expect(FrontFinderWindow.parse(list([text("/x/G"), enumerator("flvw")]))?.view.style == .gallery)
		// The view not answered, or an answer that is not the script's list: the path alone.
		#expect(FrontFinderWindow.parse(list([text("/x/U")])) == FrontFinderWindow.Answer(path: "/x/U", view: .unread))
		#expect(FrontFinderWindow.parse(text("/x/T")) == FrontFinderWindow.Answer(path: "/x/T", view: .unread))
		// Values of another type are not read; an unknown view keeps its code (the comparison calls it unknown).
		let odd = try #require(FrontFinderWindow.parse(list([text("/x/O"), enumerator("icnv"), text("88"), int(3), int(12)])))
		#expect(odd.view.iconSize == nil && odd.view.arrangement == nil && odd.view.textSize == 12 && odd.view.labelPosition == nil)
		#expect(FrontFinderWindow.parse(list([text("/x/Z"), enumerator("zzzz"), int(88)]))?.view == FinderWindowView(view: Self.code("zzzz")))
		// No path: no folder window.
		#expect(FrontFinderWindow.parse(list([])) == nil)
		#expect(FrontFinderWindow.parse(list([enumerator("icnv")])) == nil)
		#expect(FrontFinderWindow.parse(text("")) == nil)
		#expect(FrontFinderWindow.parse(list([list([text("/x")])])) == nil)

		// The script reads the folder first and only reads the view: it sets nothing.
		let source = FrontFinderWindow.source
		#expect(source.contains("target of w as alias") && source.contains("current view of w"))
		#expect(source.contains("icon view options of w") && source.contains("list view options of w"))
		#expect(source.contains("shows item info of o") && source.contains("uses relative dates of o") && source.contains("name of sort column of o"))
		// Every `set` gives one of the script's own variables a value; none sets a property of Finder's.
		let sets = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("set ") }
		#expect(sets.count == 12)
		#expect(sets.allSatisfy { line in ["w", "p", "v", "o", "r"].contains { line.hasPrefix("set \($0) to ") } })
		let pathLine = try #require(source.range(of: "POSIX path")), viewLine = try #require(source.range(of: "current view"))
		#expect(pathLine.lowerBound < viewLine.lowerBound)
	}

	/// A file that already matches is "already the same" (Finder left alone) only when the front window matches too; a
	/// window that shows another view, or whose view could not be read, restarts Finder to check (`windowDiffers`). A
	/// folder that changes is applied whatever the window shows, and without a window (the development hooks) the file
	/// alone decides.
	@Test func alreadyTheSameNeedsTheWindowToMatchToo() throws {
		let tree = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: tree) }
		let home = tree.appendingPathComponent("Home"), folder = tree.appendingPathComponent("Folder")
		func decide(_ window: FinderWindowView?) -> QuickApplyDecision {
			AppModel.quickApplyDecision(folder: folder.path, presets: [Self.icon], quickPresetID: Self.icon.id, globals: .factory,
			                            window: window, home: home)
		}
		guard case .apply(_, let plan) = decide(Self.iconWindow) else { Issue.record("not applied: \(decide(Self.iconWindow))"); return }
		let store = OperationStore(dirs: AppDirectories(root: tree.appendingPathComponent("AppData")))
		_ = try Applier(operations: store, globals: .factory).apply(ApplyRequest(plan: plan, presetName: Self.icon.name, presetSnapshot: Self.icon.settings))
		#expect(decide(nil) == .alreadyMatching(Self.icon))
		#expect(decide(Self.iconWindow) == .alreadyMatching(Self.icon))
		#expect(decide(FinderWindowView(view: Self.code("lsvw"), listIconSize: 16, listTextSize: 13)) == .windowDiffers(Self.icon, known: true))
		var small = Self.iconWindow
		small.iconSize = 64
		#expect(decide(small) == .windowDiffers(Self.icon, known: true))
		#expect(decide(.unread) == .windowDiffers(Self.icon, known: false))
		#expect(decide(FinderWindowView(view: Self.code("icnv"))) == .windowDiffers(Self.icon, known: false))
	}

	/// A tree whose "Folder" already holds the quick preset (Icon88), a way to plan it again as the service does after the
	/// quit, and a store for records; the store's record of that first apply is left out of `store`.
	private static func matchingFolder() throws -> (tree: URL, folder: URL, planAgain: () -> QuickApplyDecision, store: OperationStore, applier: Applier) {
		let q = try quickRequest()
		_ = try q.applier.apply(q.request)
		let home = q.tree.appendingPathComponent("Home")
		let store = OperationStore(dirs: AppDirectories(root: q.tree.appendingPathComponent("AppData-recheck")))
		return (q.tree, q.folder, { AppModel.quickApplyDecision(folder: q.folder.path, presets: [icon], quickPresetID: icon.id, globals: .factory, home: home) },
		        store, Applier(operations: store, globals: .factory))
	}

	/// What Finder wrote for Q once the user had pressed ⌘2 in its window: the list view, with its list records.
	static let finderListStyle = ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 13, iconSize: 16, sortColumn: .name))

	/// As a user did it: the file holds the preset, the window shows the list view (⌘2, closed, reopened) that Finder
	/// has not written yet. The decision is `windowDiffers`; Finder is quit and writes the list view as it quits (as the
	/// real one had by the second press); planned again, the folder differs and is written, recorded and undoable — the
	/// first press changes it. The launch, the reopening, the wait and the read-back come after the write, and the record's
	/// "before" is the list view Finder wrote (an undo brings it back).
	@Test func aViewFinderHasNotWrittenYetIsWrittenOverOnTheFirstPress() throws {
		let m = try Self.matchingFolder()
		defer { try? FileManager.default.removeItem(at: m.tree) }
		let listWindow = FinderWindowView(view: Self.code("lsvw"), listIconSize: 16, listTextSize: 13)
		let decision = AppModel.quickApplyDecision(folder: m.folder.path, presets: [Self.icon], quickPresetID: Self.icon.id, globals: .factory,
		                                           window: listWindow, home: m.tree.appendingPathComponent("Home"))
		#expect(decision == .windowDiffers(Self.icon, known: true))
		let finder = HistoryModelTests.FakeFinder()
		finder.onQuit = { [unowned finder] in
			finder.note("quit sees \(Self.shows(m.folder))")
			try? Self.finderWrites(Self.finderListStyle, for: m.folder)
		}
		finder.onLaunch = { [unowned finder] in finder.note("launch sees \(Self.shows(m.folder))") }
		let write = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: finder) {
			finder.note("reopen sees \(Self.shows(m.folder))")
		}
		#expect(finder.events == ["quit", "quit sees icon 88", "launch", "launch sees icon 88", "reopen sees icon 88", "settle"])
		#expect(write.recheck == .changed && write.finder == .restarted(back: true) && write.changed && write.error == nil)
		#expect(write.overwritten.isEmpty && !write.needsAttention)
		let name = "Folder", preset = "Icon88"
		#expect(write.message(folder: name, preset: preset) == String(localized: "완료: \(name)에 \"\(preset)\"을(를) 적용했습니다.") + " "
			+ String(localized: "Finder를 다시 시작하고 이 폴더를 다시 열었습니다."))
		let op = try #require(write.operation)
		#expect(try m.store.list().map(\.id) == [op.id] && op.entries.count == 1)
		let before = ViewRecordCodec.decode(try #require(op.entries.first?.before))
		#expect(before.viewStyle == .list && before.list.textSize == 13)
		_ = try UndoService(operations: m.store).undo(try m.store.load(id: op.id))
		#expect(Self.shows(m.folder) == "Nlsv")
	}

	/// The window showed another view (or one that could not be read) but Finder did not write it as it quit: the store
	/// still matches, so nothing is written or recorded — but Finder was restarted and the folder opened again, so the
	/// window now shows the file. The status line says both, reads as done, and the app's window stays behind Finder. A
	/// Finder that does not come back is named; one that does not quit is not asked anything else and nothing is planned.
	/// A refusal on the store Finder left (here unreadable) writes nothing, says Finder was restarted and asks for attention.
	@Test func whenTheStoreStillMatchesAfterTheQuitNothingIsRecorded() throws {
		let m = try Self.matchingFolder()
		defer { try? FileManager.default.removeItem(at: m.tree) }
		let name = "Folder", preset = "Icon88"
		for known in [true, false] {
			let finder = HistoryModelTests.FakeFinder()
			let write = AppModel.quickApplyRecheck(windowKnown: known, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: finder) { finder.note("reopen") }
			#expect(finder.events == ["quit", "launch", "reopen", "settle"])
			#expect(write.recheck == .unchanged(windowKnown: known) && write.finder == .restarted(back: true))
			#expect(write.operation == nil && !write.changed && write.error == nil && !write.needsAttention)
			let message = write.message(folder: name, preset: preset)
			#expect(message == (known
				? String(localized: "완료: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같았지만 Finder 창은 다른 보기를 보여 주고 있었습니다. Finder를 다시 시작하고 이 폴더를 다시 열었습니다. 파일은 그대로 두었습니다.")
				: String(localized: "완료: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같았습니다. Finder 창의 보기를 확인하지 못해 Finder를 다시 시작하고 이 폴더를 다시 열었습니다. 파일은 그대로 두었습니다.")))
			#expect(StatusBar.tone(status: message, working: false) == .success)
		}
		#expect(try m.store.list().isEmpty && Self.shows(m.folder) == "icon 88")

		let gone = HistoryModelTests.FakeFinder()
		gone.launchSucceeds = false
		let down = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: gone) { gone.note("reopen") }
		#expect(gone.events == ["quit", "launch"] && down.finder == .restarted(back: false) && down.needsAttention)
		let downMessage = down.message(folder: name, preset: preset)
		#expect(downMessage == String(localized: "빠른 적용: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같아 쓰지 않았습니다.") + " "
			+ String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요."))
		#expect(StatusBar.tone(status: downMessage, working: false) == .warning)

		let stays = HistoryModelTests.FakeFinder()
		stays.quitSucceeds = false
		var planned = false
		let refused = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: { planned = true; return m.planAgain() }, applier: m.applier, finder: stays) {
			stays.note("reopen")
		}
		#expect(refused.finder == .didNotQuit && refused.recheck == nil && !planned && stays.events == ["quit"] && stays.isRunning)

		let broken = HistoryModelTests.FakeFinder()
		broken.onQuit = { try? Data("not a .DS_Store".utf8).write(to: m.tree.appendingPathComponent(".DS_Store")) }
		let unreadable = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: broken) { broken.note("reopen") }
		let path = FolderRule.normalize(m.folder.path)
		#expect(broken.events == ["quit", "launch", "reopen", "settle"])
		#expect(unreadable.recheck == .refused(.skipped(path, .unreadable)) && unreadable.operation == nil && unreadable.needsAttention)
		let refusedMessage = unreadable.message(folder: name, preset: preset)
		#expect(refusedMessage == QuickApplyRefusal.skipped(path, .unreadable).message + " " + String(localized: "Finder를 다시 시작했습니다."))
		#expect(StatusBar.tone(status: refusedMessage, working: false) != .success)
		#expect(try m.store.list().isEmpty)
	}

	/// The development hooks (self-test, layout probe) only write: Finder is never asked to quit or launch, the folder
	/// is not reopened, and the status line is the one the self-test expects.
	@Test func withoutARestartFinderIsNeverAsked() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let finder = HistoryModelTests.FakeFinder()
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: false, finder: finder) { finder.note("reopen") }
		#expect(finder.events.isEmpty && finder.isRunning)
		#expect(write.finder == .leftAlone && write.changed && write.overwritten.isEmpty && !write.needsAttention)
		#expect(Self.shows(q.folder) == "icon 88")
		let name = "Folder", preset = "Icon88"
		let message = write.message(folder: name, preset: preset)
		#expect(message == String(localized: "완료: \(name)에 \"\(preset)\"을(를) 적용했습니다."))
		// With a restart the same write says that Finder was restarted and the folder opened again.
		var restarted = write
		restarted.finder = .restarted(back: true)
		let full = restarted.message(folder: name, preset: preset)
		#expect(full == message + " " + String(localized: "Finder를 다시 시작하고 이 폴더를 다시 열었습니다."))
		#expect(StatusBar.tone(status: full, working: false) == .success)
	}

	/// Finder's other windows: read before the quit and opened again once Finder is back, back to front,
	/// before the folder — which is opened last, so it ends up in front, and never twice (its own window is left to
	/// `reopen`) — and before Finder settles and the write is read back. The same when the file already matched and the
	/// folder is only planned again after the quit. Nothing is opened when Finder does not quit or does not come back; a
	/// Finder that goes away while it settles is launched once more; the development hooks read no windows at all.
	@Test func finderWindowsAreOpenedAgainBeforeTheFolder() throws {
		let q = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: q.tree) }
		let other = q.tree.appendingPathComponent("Other"), second = q.tree.appendingPathComponent("Second")
		for folder in [other, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
		let finder = HistoryModelTests.FakeFinder()
		finder.windows = [q.folder, other, second]
		let write = AppModel.quickApplyWrite(q.request, folder: q.folder, applier: q.applier, restartsFinder: true, finder: finder) {
			finder.note("reopen the folder")
		}
		#expect(finder.events == ["windows", "quit", "launch", "reopen Second,Other", "reopen the folder", "settle"])
		#expect(write.finder == .restarted(back: true) && write.changed && write.windowsReopened == 2)

		let m = try Self.matchingFolder()
		defer { try? FileManager.default.removeItem(at: m.tree) }
		let recheckFinder = HistoryModelTests.FakeFinder()
		recheckFinder.windows = [other, m.folder]
		let recheck = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: recheckFinder) {
			recheckFinder.note("reopen the folder")
		}
		#expect(recheckFinder.events == ["windows", "quit", "launch", "reopen Other", "reopen the folder", "settle"])
		#expect(recheck.recheck == .unchanged(windowKnown: true) && recheck.windowsReopened == 1)

		// Finder does not quit, or does not come back: nothing is opened.
		let stays = HistoryModelTests.FakeFinder()
		stays.windows = [other]
		stays.quitSucceeds = false
		_ = AppModel.quickApplyRecheck(windowKnown: true, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: stays) { stays.note("reopen the folder") }
		#expect(stays.events == ["windows", "quit"])
		let r = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: r.tree) }
		let down = HistoryModelTests.FakeFinder()
		down.windows = [other]
		down.launchSucceeds = false
		let gone = AppModel.quickApplyWrite(r.request, folder: r.folder, applier: r.applier, restartsFinder: true, finder: down) { down.note("reopen the folder") }
		#expect(down.events == ["windows", "quit", "launch"] && gone.finder == .restarted(back: false) && gone.windowsReopened == 0)

		// Finder goes away while it settles: launched once more, and the write counts as restarted with Finder back.
		let dying = HistoryModelTests.FakeFinder()
		dying.onSettle = { [unowned dying] in dying.crash() }
		let revived = AppModel.quickApplyRecheck(windowKnown: false, folder: m.folder, planAgain: m.planAgain, applier: m.applier, finder: dying) {
			dying.note("reopen the folder")
		}
		#expect(dying.events == ["quit", "launch", "reopen the folder", "settle", "crash", "launch"] && revived.finder == .restarted(back: true))

		// The development hooks never ask Finder anything, its windows least of all.
		let s = try Self.quickRequest()
		defer { try? FileManager.default.removeItem(at: s.tree) }
		let hooks = HistoryModelTests.FakeFinder()
		hooks.windows = [other]
		_ = AppModel.quickApplyWrite(s.request, folder: s.folder, applier: s.applier, restartsFinder: false, finder: hooks) { hooks.note("reopen the folder") }
		#expect(hooks.events.isEmpty)
	}
}

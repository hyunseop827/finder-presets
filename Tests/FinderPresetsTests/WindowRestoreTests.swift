import Foundation
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// Finder's windows around every restart the app makes: read before the quit, opened again once
/// Finder is back — back to front, each once, without folders that are gone and without the operation's own folders,
/// which are opened after them — and before Finder is given its moment to settle and the writes are read back. Nothing is
/// opened when Finder does not quit or does not come back; a Finder that goes away while it settles is launched once
/// more. With the fake Finder (`HistoryModelTests.FakeFinder`), temporary folders and a throwaway defaults domain: the real
/// Finder, the real home and the data folder are never touched. Also "최신 버전" (ReleaseLink).
@MainActor @Suite struct WindowRestoreTests {
	typealias FakeFinder = HistoryModelTests.FakeFinder

	static let icon = Preset(name: "Icon", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 72)))

	/// Folders named `names` in `env.root`, created.
	static func folders(_ names: [String], in env: HistoryModelTests.Env) throws -> [URL] {
		try names.map {
			let folder = env.root.appendingPathComponent($0)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			return folder
		}
	}

	/// "지금 다시 시작" after an apply of A and B, with Finder showing X (front), A, Y, a folder that is gone and X again:
	/// Y and X are opened again (back to front; A is left to the operation, which opens A and B after them, so they end
	/// up in front), then Finder settles. The status line says how many windows were opened again, after the folders.
	@Test func finderRestartOpensFindersWindowsBeforeTheOperationsFolders() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let a = env.root.appendingPathComponent("A"), b = env.root.appendingPathComponent("B")
		let (x, y) = try { let f = try Self.folders(["X", "Y"], in: env); return (f[0], f[1]) }()
		let op = try HistoryModelTests.apply(Self.icon, to: [a, b], env: env)
		let finder = FakeFinder()
		finder.windows = [x, a, y, env.root.appendingPathComponent("Gone"), x]
		let restart = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: finder) {
			finder.note("open \($0.lastPathComponent)")
			return true
		}
		#expect(finder.events == ["windows", "quit", "launch", "reopen Y,X", "open A", "open B", "settle"])
		#expect(restart.back && restart.windowsReopened == 2 && restart.reopened.count == 2)
		#expect(restart.message == String(localized: "Finder를 다시 시작했습니다.") + " " + String(localized: "폴더 \(2)개를 열었습니다: \(Fmt.name("A, B")).")
			+ " " + String(localized: "열려 있던 Finder 창 \(2)개도 다시 열었습니다."))
		#expect(StatusBar.tone(status: restart.message, working: false) == .success && !restart.needsAttention)

		// Without an opener (the question after "시스템 전체에 적용"): A's window is opened again like any other.
		let bare = FakeFinder()
		bare.windows = [x, a]
		let plain = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: bare)
		#expect(bare.events == ["windows", "quit", "launch", "reopen A,X", "settle"] && plain.windowsReopened == 2)
		// No folder of the operation was opened: the windows' sentence does not say "도" (Also).
		#expect(plain.message == String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요.")
			+ " " + String(localized: "열려 있던 Finder 창 \(2)개를 다시 열었습니다."))
		#expect(StatusBar.tone(status: plain.message, working: false) == .success && !plain.needsAttention)
		// Too many rows to open: none of them is opened, so none of their windows is left out.
		let six = try Self.folders(["C1", "C2", "C3", "C4", "C5", "C6"], in: env)
		let many = try HistoryModelTests.apply(Self.icon, to: six, env: env)
		let crowded = FakeFinder()
		crowded.windows = [six[0], x]
		let tooMany = AppModel.restartFinder(after: many.id, store: env.store, globals: env.globals, finder: crowded) { _ in true }
		#expect(crowded.events == ["windows", "quit", "launch", "reopen X,C1", "settle"] && tooMany.tooManyToReopen == 6)
		#expect(tooMany.message.hasSuffix(String(localized: "필요한 폴더는 직접 여세요.") + " " + String(localized: "열려 있던 Finder 창 \(2)개를 다시 열었습니다.")))
		#expect(!tooMany.message.contains(String(localized: "열려 있던 Finder 창 \(2)개도 다시 열었습니다.")) && !tooMany.needsAttention)
		// No windows (none open, or none that shows a folder): the line is the one it was.
		let none = AppModel.restartFinder(after: nil, store: env.store, globals: env.globals, finder: FakeFinder())
		#expect(none.windowsReopened == 0 && none.message == String(localized: "Finder를 다시 시작했습니다. 폴더를 열어 확인하세요."))

		// Finder does not quit, or does not come back: nothing is opened.
		let stays = FakeFinder()
		stays.windows = [x]
		stays.quitSucceeds = false
		let refused = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: stays) { _ in true }
		#expect(!refused.quit && refused.needsAttention)
		#expect(stays.events == ["windows", "quit"])
		let down = FakeFinder()
		down.windows = [x]
		down.launchSucceeds = false
		let gone = AppModel.restartFinder(after: op.id, store: env.store, globals: env.globals, finder: down) { _ in true }
		#expect(down.events == ["windows", "quit", "launch"] && !gone.back && gone.windowsReopened == 0)
		#expect(gone.message.hasPrefix(String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")) && gone.needsAttention)
	}

	/// `FinderRestart.needsAttention` (the app's window comes forward over the Finder windows just opened again) is
	/// exactly a status line that reads as a warning: a clean restart leaves Finder in front.
	@Test func aRestartNeedsAttentionExactlyWhenItsLineIsAWarning() {
		let clean = FinderRestart(quit: true, back: true, windowsReopened: 3)
		let cases: [FinderRestart] = [
			clean,
			FinderRestart(quit: true, back: true, reopened: ["/w/A"], windowsReopened: 1),
			FinderRestart(quit: true, back: true, tooManyToReopen: 6),
			FinderRestart(quit: true, back: true, rewritten: ["/w/A"]),
			FinderRestart(),
			FinderRestart(quit: true, back: false),
			FinderRestart(quit: true, back: true, notRewritten: ["/w/A"], reason: "x"),
			FinderRestart(quit: true, back: true, overwritten: ["/w/A"]),
			FinderRestart(quit: true, back: true, leftAlone: ["/w/A"]),
			FinderRestart(quit: true, back: true, undo: true, leftAlone: ["/w/A"], overwritten: ["/w/B"]),
		]
		for restart in cases {
			#expect(restart.needsAttention == (StatusBar.tone(status: restart.message, working: false) == .warning), "\(restart)")
		}
		#expect(!clean.needsAttention && FinderRestart().needsAttention)
	}

	/// A Finder that goes away while it settles is launched once more (its windows are not opened a second time); when
	/// that launch fails too, the restart says Finder did not come back.
	@Test func aFinderThatDiesWhileItSettlesIsLaunchedOnceMore() throws {
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let x = try Self.folders(["X"], in: env)[0]
		let dying = FakeFinder()
		dying.windows = [x]
		dying.onSettle = { [unowned dying] in dying.crash() }
		let revived = AppModel.restartFinder(after: nil, store: env.store, globals: env.globals, finder: dying)
		#expect(dying.events == ["windows", "quit", "launch", "reopen X", "settle", "crash", "launch"] && revived.back && dying.isRunning)
		let lost = FakeFinder()
		lost.onSettle = { [unowned lost] in
			lost.crash()
			lost.launchSucceeds = false
		}
		let gone = AppModel.restartFinder(after: nil, store: env.store, globals: env.globals, finder: lost)
		#expect(lost.events == ["quit", "launch", "settle", "crash", "launch"] && !gone.back)
		#expect(gone.message.hasPrefix(String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")))
	}

	/// "시스템 전체에 적용": with Finder's defaults (`GlobalApplier.apply`) and with the home folders alone
	/// (`runWithFinderQuit`), Finder's windows are read before the quit and opened again after the launch, before Finder
	/// settles and the home folders are read back. None when Finder does not come back; a Finder that dies while it
	/// settles is launched again and counted as back.
	@Test func systemApplyOpensFindersWindowsAgainBeforeItSettles() throws {
		let domain = HistoryModelTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "Nlsv", standardViewSettings: [:], domain: domain.name)
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let x = try Self.folders(["X", "C", "D", "E"], in: env)[0]
		func run(_ folder: String, writesDefaults: Bool, finder: FakeFinder) -> SystemApplyRun {
			let root = env.root.appendingPathComponent(folder)
			let planner = Planner(presets: [Self.icon], resolver: RuleResolver(rules: [], defaultPresetID: Self.icon.id), globals: env.globals)
			let plan = planner.plan(scanned: FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: [root]), roots: [root])
			return AppModel.systemApplyWrite(Self.icon, writesDefaults: writesDefaults,
			                                 folderRequest: ApplyRequest(plan: plan, presetName: Self.icon.name, presetSnapshot: Self.icon.settings),
			                                 applier: Applier(operations: env.store, globals: env.globals),
			                                 globalApplier: GlobalApplier(operations: env.store, domain: domain.name, finder: finder))
		}
		let finder = FakeFinder()
		finder.windows = [x]
		let global = run("A", writesDefaults: true, finder: finder)
		#expect(finder.events == ["windows", "quit", "launch", "reopen X", "settle"] && global.relaunched == true && global.flowError == nil)
		let alone = FakeFinder()
		alone.windows = [x]
		let folders = run("B", writesDefaults: false, finder: alone)
		#expect(alone.events == ["windows", "quit", "launch", "reopen X", "settle"] && folders.relaunched == true)

		let down = FakeFinder()
		down.windows = [x]
		down.launchSucceeds = false
		let gone = run("C", writesDefaults: false, finder: down)
		#expect(down.events == ["windows", "quit", "launch"] && gone.relaunched == false)
		let dying = FakeFinder()
		dying.windows = [x]
		dying.onSettle = { [unowned dying] in dying.crash() }
		let revived = run("D", writesDefaults: false, finder: dying)
		#expect(dying.events == ["windows", "quit", "launch", "reopen X", "settle", "crash", "launch"] && revived.relaunched == true)
		let stays = FakeFinder()
		stays.windows = [x]
		stays.quitSucceeds = false
		let refused = run("E", writesDefaults: true, finder: stays)
		#expect(stays.events == ["windows", "quit"] && refused.flowError != nil)
	}

	/// The Finder default undo in the history sheet (`GlobalApplier.undo`): the same windows opened again after the launch.
	@Test func globalUndoOpensFindersWindowsAgain() throws {
		let domain = HistoryModelTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let (x, y) = try { let f = try Self.folders(["X", "Y"], in: env); return (f[0], f[1]) }()
		let op = try GlobalApplier(operations: env.store, domain: domain.name, finder: FakeFinder()).apply(ViewSettings(viewStyle: .list), presetName: "G")
		guard case .success(let pending) = AppModel.makePendingUndo(op.id, store: env.store, domain: domain.name) else {
			Issue.record("not prepared")
			return
		}
		let finder = FakeFinder()
		finder.windows = [y, x]
		let done = AppModel.runUndo(pending, store: env.store, domain: domain.name, finder: finder)
		#expect(done.error == nil && done.finderRelaunched == true && finder.events == ["windows", "quit", "launch", "reopen X,Y", "settle"])
		#expect(domain.style() == "icnv" && done.succeeded)

		// Finder goes away while it settles and does not start again: the undo holds, but it is not a success (the
		// sheet comes forward, `finishUndo`), and nothing is opened a second time.
		let second = try GlobalApplier(operations: env.store, domain: domain.name, finder: FakeFinder()).apply(ViewSettings(viewStyle: .list), presetName: "G2")
		guard case .success(let again) = AppModel.makePendingUndo(second.id, store: env.store, domain: domain.name) else {
			Issue.record("not prepared")
			return
		}
		let dying = FakeFinder()
		dying.windows = [x]
		dying.onSettle = { [unowned dying] in
			dying.crash()
			dying.launchSucceeds = false
		}
		let lost = AppModel.runUndo(again, store: env.store, domain: domain.name, finder: dying)
		#expect(lost.error == nil && lost.finderRelaunched == false && !lost.succeeded)
		#expect(dying.events == ["windows", "quit", "launch", "reopen X", "settle", "crash", "launch"] && domain.style() == "icnv")
	}

	/// "시스템 전체에 적용" without the home folders ("홈 폴더 포함" off, or the home folders already the same): only
	/// Finder's defaults are written, and Finder is still given its moment to settle once its windows are open again,
	/// checked (a Finder that went away is launched once more) and only then read back — what Finder writes as it starts
	/// is seen. `relaunched` is whether it runs after that; a result that did not end well brings the window forward.
	@Test func systemApplyWithoutTheHomeFoldersSettlesAndChecksFinderToo() throws {
		let domain = HistoryModelTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "Nlsv", standardViewSettings: [:], domain: domain.name)
		let env = try HistoryModelTests.makeEnv()
		defer { env.cleanUp() }
		let x = try Self.folders(["X"], in: env)[0]
		let list = Preset(name: "List", settings: ViewSettings(viewStyle: .list))
		func run(_ preset: Preset, finder: FakeFinder) -> SystemApplyRun {
			AppModel.systemApplyWrite(preset, writesDefaults: true, folderRequest: nil,
			                          applier: Applier(operations: env.store, globals: env.globals),
			                          globalApplier: GlobalApplier(operations: env.store, domain: domain.name, finder: finder))
		}
		let finder = FakeFinder()
		finder.windows = [x]
		let clean = run(Self.icon, finder: finder)
		#expect(finder.events == ["windows", "quit", "launch", "reopen X", "settle"])
		#expect(clean.relaunched == true && clean.flowError == nil && clean.folderOp == nil && clean.globalOpID != nil)
		#expect(!AppModel.systemApplyNeedsAttention(clean) && domain.style() == "icnv")

		// Finder goes away while it settles: launched once more (its window not opened again), counted as back.
		let dying = FakeFinder()
		dying.windows = [x]
		dying.onSettle = { [unowned dying] in dying.crash() }
		let revived = run(list, finder: dying)
		#expect(dying.events == ["windows", "quit", "launch", "reopen X", "settle", "crash", "launch"] && revived.relaunched == true)
		#expect(revived.flowError == nil && !AppModel.systemApplyNeedsAttention(revived))

		// And when that launch fails: not back — the record says so too — and the window comes forward.
		let lost = FakeFinder()
		lost.windows = [x]
		lost.onSettle = { [unowned lost] in
			lost.crash()
			lost.launchSucceeds = false
		}
		let gone = run(Self.icon, finder: lost)
		#expect(lost.events == ["windows", "quit", "launch", "reopen X", "settle", "crash", "launch"] && gone.relaunched == false)
		let record = try env.store.load(id: try #require(gone.globalOpID))
		#expect(!record.finderRelaunched && gone.flowError == nil && AppModel.systemApplyNeedsAttention(gone))

		// Finder writes other defaults as it starts: the read-back comes after the settle and sees them. The flow stops
		// with the difference; Finder is back (said on the status line), and the window comes forward over its windows.
		let writing = FakeFinder()
		writing.windows = [x]
		writing.onSettle = { try? GlobalDefaultsWriter.write(viewStyle: "clmv", standardViewSettings: [:], domain: domain.name) }
		let differs = run(list, finder: writing)
		#expect(writing.events == ["windows", "quit", "launch", "reopen X", "settle"])
		if case GlobalApplyError.verificationFailed? = differs.flowError {} else { Issue.record("no verification failure: \(String(describing: differs.flowError))") }
		#expect(differs.relaunched == true && differs.globalOpID != nil && AppModel.systemApplyNeedsAttention(differs))
	}

	/// What brings the window forward after "시스템 전체에 적용" (`AppModel.systemApplyNeedsAttention`): anything but a
	/// clean run — a stopped flow, a home folders' write that stopped or failed for some folders, folders Finder
	/// overwrote, a Finder that did not come back.
	@Test func systemApplyNeedsAttentionUnlessItEndedCleanly() {
		struct Boom: Error {}
		var clean = SystemApplyRun()
		clean.relaunched = true
		#expect(!AppModel.systemApplyNeedsAttention(clean) && !AppModel.systemApplyNeedsAttention(SystemApplyRun()))
		var stopped = clean
		stopped.flowError = Boom()
		var folderError = clean
		folderError.folderError = Boom()
		var overwritten = clean
		overwritten.overwritten = 1
		var down = clean
		down.relaunched = false
		var failed = clean
		var op = FinderPresetsOperation(kind: .apply, roots: ["/w"])
		op.entries = [OperationEntry(folderPath: "/w/A", storePath: "/.DS_Store", key: "A", before: nil, after: nil, status: .failed)]
		failed.folderOp = op
		for run in [stopped, folderError, overwritten, down, failed] { #expect(AppModel.systemApplyNeedsAttention(run)) }
	}

	// MARK: "최신 버전" (ReleaseLink)

	/// One constant, well formed, pointing at this repository's latest release on GitHub; the app's sources spell the
	/// address nowhere else. Opening asks the opener for exactly that address; when it cannot, the status line is a
	/// warning that gives the address. The tooltip names the version when there is one.
	@Test func latestReleaseLinkIsOneWellFormedConstant() throws {
		let url = ReleaseLink.latest
		#expect(url.scheme == "https" && url.host == "github.com" && url.path == "/hyunseop827/finder-presets/releases/latest")
		#expect(url.query == nil && url.fragment == nil && url.user == nil && url.port == nil)
		#expect(url.absoluteString == "https://github.com/hyunseop827/finder-presets/releases/latest")

		var asked: [URL] = []
		#expect(ReleaseLink.open { asked.append($0); return true } == nil && asked == [url])
		let failure = try #require(ReleaseLink.open { _ in false })
		#expect(failure.contains(url.absoluteString) && StatusBar.tone(status: failure, working: false) == .warning)

		let page = String(localized: "GitHub의 최신 릴리스 페이지를 브라우저에서 엽니다. 앱은 업데이트를 직접 확인하지 않습니다.")
		#expect(ReleaseLink.help(version: "1.2.3") == String(localized: "이 앱은 \("1.2.3") 버전입니다.") + " " + page)
		#expect(ReleaseLink.help(version: nil) == page)

		// The address lives in ReleaseLink.swift only.
		let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Sources/FinderPresets")
		let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
			.filter { $0.pathExtension == "swift" } ?? []
		#expect(files.count > 10)
		let spelling = files.filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("finder-presets/releases") == true }
		#expect(spelling.map(\.lastPathComponent) == ["ReleaseLink.swift"])
	}

	/// The toolbar's third button and 도움말 > "최신 버전 열기…" both go through `AppModel.openLatestRelease` (read from the
	/// sources: SwiftUI's toolbar and menu cannot be built without a window), the button with its identifier and symbol;
	/// both names have English texts.
	@Test func toolbarButtonAndHelpMenuOpenTheLatestRelease() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let main = try String(contentsOf: root.appendingPathComponent("Sources/FinderPresets/Views/MainView.swift"), encoding: .utf8)
		let app = try String(contentsOf: root.appendingPathComponent("Sources/FinderPresets/FinderPresetsApp.swift"), encoding: .utf8)
		#expect(main.contains("Button { model.openLatestRelease() } label: {") && main.contains(".accessibilityIdentifier(\"latestRelease\")"))
		#expect(main.contains("Label(ReleaseLink.buttonLabel, systemImage: \"arrow.down.circle\")") && main.contains(".help(ReleaseLink.help())"))
		let help = try #require(app.range(of: "CommandGroup(replacing: .help)"))
		#expect(app[help.upperBound...].prefix(600).contains("Button(ReleaseLink.menuTitle) { model.openLatestRelease() }"))
		let english = try LocalizationTests.strings("en", "Localizable")
		#expect(english[ReleaseLink.buttonLabel] == "Latest Release" && english[ReleaseLink.menuTitle] == "Open Latest Release…")
		#expect(MainView.toolbarLabels.last == ReleaseLink.buttonLabel)
	}
}

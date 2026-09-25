import Foundation
import Testing
@testable import FinderPresetsCore

/// How the app stops and starts Finder, without Finder: Finder's windows around a restart (`FinderWindows`: which folders
/// are opened again, in which order, how many), the script that reads them (only its answer is parsed here; it is never
/// run), `GlobalApplier` opening them again on every path, and the waits and the retry of `FinderController.quit` /
/// `launch` on scripted processes (`FakeProcesses`, a clock that only `sleep` moves). Nothing here talks to Finder,
/// launches anything or reads the real home or data folders.
@Suite struct FinderLifecycleTests {
	/// Scripted Finder processes (`FinderProcesses`). After a quit request Finder leaves the running applications after
	/// `leavesListAfter` seconds and its process exits `exitsAfter` seconds later (nil: never). Each launch request takes
	/// the next of `launches` (the last one repeats): the error `open` reports and when Finder is listed (nil: never),
	/// counted from the request; `open` answers `answersAfter` seconds after the request (the clock moves that far).
	final class FakeProcesses: @unchecked Sendable {
		var clock: TimeInterval = 0
		var listed: [pid_t]
		var alive: Set<pid_t>
		var leavesListAfter: TimeInterval? = 0.3
		var exitsAfter: TimeInterval? = 0.5
		var launches: [(error: String?, startsAfter: TimeInterval?)] = [(nil, 0.4)]
		var answersAfter: TimeInterval = 0
		private(set) var events: [String] = []
		private var timers: [(at: TimeInterval, run: () -> Void)] = []
		private var nextPID: pid_t = 200

		init(running: Bool = true) {
			listed = running ? [100] : []
			alive = running ? [100] : []
		}

		/// Runs `run` once the clock has moved `delay` further.
		func after(_ delay: TimeInterval, _ run: @escaping () -> Void) { timers.append((clock + delay, run)) }

		private func advance(_ time: TimeInterval) {
			clock += time
			let due = timers.filter { $0.at <= clock + 1e-9 }.sorted { $0.at < $1.at }
			timers.removeAll { $0.at <= clock + 1e-9 }
			for timer in due { timer.run() }
		}

		var processes: FinderProcesses {
			FinderProcesses(
				running: { [self] in listed },
				exists: { [self] in alive.contains($0) },
				askToQuit: { [self] in
					events.append("askToQuit")
					let pids = listed
					guard let leaves = leavesListAfter else { return }
					after(leaves) { self.listed = [] }
					if let exits = exitsAfter { after(leaves + exits) { self.alive.subtract(pids) } }
				},
				open: { [self] _ in
					let next = launches.count > 1 ? launches.removeFirst() : launches[0]
					events.append("open")
					if let starts = next.startsAfter {
						after(starts) {
							let pid = self.nextPID
							self.nextPID += 1
							self.listed = [pid]
							self.alive.insert(pid)
						}
					}
					if answersAfter > 0 { advance(answersAfter) }
					return next.error
				},
				sleep: { [self] in advance($0) },
				now: { [self] in Date(timeIntervalSinceReferenceDate: clock) })
		}
	}

	/// A lifecycle that only has windows: what it was asked to open.
	final class WindowFinder: FinderLifecycle, @unchecked Sendable {
		var windows: [URL] = []
		private(set) var opened: [[URL]] = []
		func quit() -> Bool { true }
		func launch() -> Bool { true }
		var isRunning: Bool { true }
		func openWindowFolders() -> [URL] { windows }
		func reopen(_ folders: [URL]) -> [URL] {
			opened.append(folders)
			return folders
		}
	}

	static func url(_ name: String) -> URL { URL(fileURLWithPath: "/w/\(name)") }

	// MARK: FinderWindows

	/// The windows are opened back to front (the frontmost last, so it ends in front), each folder once however it was
	/// spelled, without folders that are gone and without the operation's own folders (opened after them), at most
	/// `FinderWindows.limit` of the frontmost — folders skipped or seen twice do not use the limit up.
	@Test func windowsToReopenAreOrderedDedupedSkippedAndCapped() {
		let exists: (URL) -> Bool = { $0.lastPathComponent != "Gone" }
		let windows = FinderWindows(folders: [Self.url("A"), Self.url("B"), URL(fileURLWithPath: "/w/a/"), Self.url("Gone"), Self.url("C"), Self.url("B")])
		#expect(windows.toReopen(isFolder: exists).map(\.path) == ["/w/C", "/w/B", "/w/A"])
		// The operation opens B itself, after these (spelled otherwise, still B).
		#expect(windows.toReopen(excluding: [URL(fileURLWithPath: "/W/B/")], isFolder: exists).map(\.path) == ["/w/C", "/w/A"])
		#expect(FinderWindows().toReopen(isFolder: exists).isEmpty)
		#expect(FinderWindows(folders: [Self.url("Gone")]).toReopen(isFolder: exists).isEmpty)

		// Fifteen windows: the twelve frontmost, back to front.
		#expect(FinderWindows.limit == 12)
		let many = FinderWindows(folders: (1...15).map { Self.url("W\($0)") }).toReopen(isFolder: { _ in true })
		#expect(many.map(\.lastPathComponent) == (1...12).reversed().map { "W\($0)" })
		// A gone folder and a second window of W1 do not count: still W1…W12, and W13 behind them stays closed.
		let gaps = FinderWindows(folders: [Self.url("Gone")] + (1...12).map { Self.url("W\($0)") } + [Self.url("W1"), Self.url("W13")])
		#expect(gaps.toReopen(isFolder: exists).map(\.lastPathComponent) == (1...12).reversed().map { "W\($0)" })
		// A smaller limit keeps the frontmost.
		#expect(windows.toReopen(limit: 1, isFolder: exists).map(\.path) == ["/w/A"])
	}

	/// `remember` asks the lifecycle for its windows; `reopen(in:)` asks it to open only when there is something to open,
	/// with the folders that exist, and returns what it opened. The real check for a folder: a directory that exists.
	@Test func reopenAsksFinderOnlyWhenThereIsSomethingToOpen() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-windows-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("A"), withIntermediateDirectories: true)
		try Data().write(to: dir.appendingPathComponent("file"))
		defer { try? FileManager.default.removeItem(at: dir) }
		let a = dir.appendingPathComponent("A"), gone = dir.appendingPathComponent("Gone"), file = dir.appendingPathComponent("file")
		#expect(FinderWindows.isFolder(a) && !FinderWindows.isFolder(gone) && !FinderWindows.isFolder(file))
		#expect(!FinderWindows.isFolder(URL(string: "https://example.com/A")!))

		let finder = WindowFinder()
		#expect(FinderWindows.remember(finder).folders.isEmpty)
		#expect(FinderWindows.remember(finder).reopen(in: finder).isEmpty && finder.opened.isEmpty)
		finder.windows = [gone, a, file]
		let windows = FinderWindows.remember(finder)
		#expect(windows.folders == [gone, a, file])
		#expect(windows.reopen(in: finder).map(\.lastPathComponent) == ["A"] && finder.opened.count == 1)
		// Only the operation's own folder: nothing left to open, Finder is not asked.
		#expect(windows.reopen(in: finder, before: [a]).isEmpty && finder.opened.count == 1)
	}

	/// The script's answer is a list of POSIX paths: texts only, empty ones skipped, trailing slashes dropped; a lone
	/// text is one path. The script itself only reads, window by window by index, each event bounded in time.
	@Test func windowFoldersAreReadFromTheScriptsAnswer() throws {
		let list = NSAppleEventDescriptor.list()
		list.insert(NSAppleEventDescriptor(string: "/Users/x/A/"), at: 0)
		list.insert(NSAppleEventDescriptor(int32: 7), at: 0)
		list.insert(NSAppleEventDescriptor(string: ""), at: 0)
		list.insert(NSAppleEventDescriptor(string: "/Users/x/B"), at: 0)
		#expect(FinderController.windowFolders(from: list) == ["/Users/x/A", "/Users/x/B"])
		#expect(FinderController.windowFolders(from: .list()).isEmpty)
		#expect(FinderController.windowFolders(from: NSAppleEventDescriptor(string: "/Users/x/C/")) == ["/Users/x/C"])
		#expect(FinderController.windowFolders(from: NSAppleEventDescriptor(int32: 1)).isEmpty)

		let source = FinderController.windowFoldersSource
		#expect(source.contains("POSIX path of (target of Finder window i as alias)") && source.contains("with timeout of 5 seconds"))
		#expect(source.contains("if n > \(FinderController.windowReadLimit) then set n to \(FinderController.windowReadLimit)"))
		// The first event (`count`) keeps the default timeout: on a Mac that has not allowed the app to control Finder
		// yet it brings up the Automation prompt, and the user's answer must not be cut off after 5 seconds. The windows
		// are read within the limit.
		let count = try #require(source.range(of: "set n to count Finder windows"))
		let limit = try #require(source.range(of: "with timeout of 5 seconds"))
		let loop = try #require(source.range(of: "repeat with i from 1 to n"))
		#expect(count.upperBound <= limit.lowerBound && limit.upperBound <= loop.lowerBound)
		#expect(!source.contains("every Finder window") && !source.contains("front Finder window"))
		#expect(!source.contains("options of") && !source.contains("set current view") && !source.contains("close"))
	}

	// MARK: GlobalApplier

	/// Every path of `GlobalApplier` that quits Finder reads its windows first and opens them again once Finder is back,
	/// before the read-back: the apply, the undo, the down time for other writes (also when that write throws), and a plain
	/// restart (`relaunch-finder`: an empty body). Nothing is read or opened when Finder is left alone (already restored),
	/// and nothing opened when Finder does not quit or does not come back.
	@Test func globalApplierOpensFindersWindowsAgainOnEveryPath() throws {
		let domain = GlobalDefaultsTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let base = GlobalDefaultsTests.tempDir("finder-presets-global-windows")
		defer { try? FileManager.default.removeItem(at: base) }
		let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
		for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
		let ops = OperationStore(dirs: AppDirectories(root: base.appendingPathComponent("AppData")))
		let finder = GlobalDefaultsTests.FakeFinder(domain: domain.name)
		finder.windows = [a, b, base.appendingPathComponent("Gone"), a]
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)

		let op = try applier.apply(ViewSettings(viewStyle: .list), presetName: "P")
		#expect(finder.events == ["windows", "quit:icnv", "launch:Nlsv", "reopen:B,A"] && op.finderRelaunched)
		finder.reset()
		let undo = try applier.undo(op)
		#expect(finder.events == ["windows", "quit:Nlsv", "launch:icnv", "reopen:B,A"] && undo.finderRelaunched)

		// Already the recorded values: Finder is left alone, its windows are not even read.
		let redo = try applier.undo(undo)   // applies again
		try GlobalDefaultsWriter.restore(try ops.loadGlobalSnapshot(try #require(redo.globalSnapshotFile), for: redo), domain: domain.name)
		finder.reset()
		let recorded = try applier.undo(redo)
		#expect(OperationHistory.foundAlreadyRestored(recorded) && finder.events.isEmpty)

		// The down time for other writes, and a plain restart: the windows opened again are returned.
		finder.reset()
		let run = try applier.runWithFinderQuit { 7 }
		#expect(run.result == 7 && run.finderRelaunched && run.reopenedWindows.map(\.lastPathComponent) == ["B", "A"])
		#expect(finder.events == ["windows", "quit:icnv", "launch:icnv", "reopen:B,A"])
		// A body that throws: Finder is launched and its windows opened before the error propagates.
		finder.reset()
		struct Boom: Error {}
		#expect(throws: Boom.self) { try applier.runWithFinderQuit { throw Boom() } }
		#expect(finder.events == ["windows", "quit:icnv", "launch:icnv", "reopen:B,A"])

		// Finder does not come back: nothing is opened.
		finder.reset()
		finder.launchSucceeds = false
		let down = try applier.runWithFinderQuit {}
		#expect(!down.finderRelaunched && down.reopenedWindows.isEmpty && finder.events == ["windows", "quit:icnv", "launch:icnv"])
		finder.reset()
		let lost = try applier.apply(ViewSettings(viewStyle: .column), presetName: "C")
		#expect(!lost.finderRelaunched && finder.events == ["windows", "quit:icnv", "launch:clmv"])
		// Finder does not quit: nothing is written, launched or opened.
		finder.reset()
		finder.launchSucceeds = true
		finder.quitSucceeds = false
		#expect(throws: GlobalApplyError.self) { try applier.runWithFinderQuit {} }
		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(viewStyle: .gallery), presetName: "G") }
		#expect(finder.events == ["windows", "quit:clmv", "windows", "quit:clmv"])
	}

	/// A lifecycle that records its calls, the settle included (`onSettle` runs while it settles: Finder writing as it
	/// starts, or going away), with the windows it answers.
	final class SettlingFinder: FinderLifecycle, @unchecked Sendable {
		var launchSucceeds = true
		var onSettle: (() -> Void)?
		var windows: [URL] = []
		private(set) var events: [String] = []
		private var running = true
		var isRunning: Bool { running }
		func quit() -> Bool { events.append("quit"); running = false; return true }
		func launch() -> Bool { events.append("launch"); running = launchSucceeds; return launchSucceeds }
		func settle() { events.append("settle"); onSettle?() }
		func openWindowFolders() -> [URL] { windows }
		func reopen(_ folders: [URL]) -> [URL] {
			events.append("reopen " + folders.map(\.lastPathComponent).joined(separator: ","))
			return folders
		}
		func crash() { events.append("crash"); running = false }
		func reset() { events = [] }
	}

	/// Every path of `GlobalApplier` gives Finder its moment to settle once its windows are open again, and reads Finder's
	/// defaults back only after it: what Finder writes as it starts is seen. A Finder that goes away meanwhile is launched
	/// once more (its windows are not opened again), and `finderRelaunched` says whether it runs after that — the apply,
	/// the undo and the down time for other writes (`relaunch-finder`, `apply --relaunch`, the home folders alone) alike.
	@Test func globalApplierLetsFinderSettleAndChecksItBeforeItReadsBack() throws {
		let domain = GlobalDefaultsTests.TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let base = GlobalDefaultsTests.tempDir("finder-presets-global-settle")
		defer { try? FileManager.default.removeItem(at: base) }
		let a = base.appendingPathComponent("A")
		try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
		let ops = OperationStore(dirs: AppDirectories(root: base.appendingPathComponent("AppData")))
		let finder = SettlingFinder()
		finder.windows = [a]
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)

		// Finder writes another view style as it starts: the read-back, after the settle, sees it.
		finder.onSettle = { try? GlobalDefaultsWriter.write(viewStyle: "clmv", standardViewSettings: [:], domain: domain.name) }
		var sawIt = false
		do {
			_ = try applier.apply(ViewSettings(viewStyle: .list), presetName: "P")
		} catch GlobalApplyError.verificationFailed(_, let diffs) {
			sawIt = !diffs.isEmpty
		}
		#expect(sawIt && finder.events == ["quit", "launch", "reopen A", "settle"])

		// Finder goes away while it settles: launched once more, its window not opened again; the apply holds.
		finder.reset()
		finder.onSettle = { [unowned finder] in finder.crash() }
		let op = try applier.apply(ViewSettings(viewStyle: .list), presetName: "P")
		#expect(finder.events == ["quit", "launch", "reopen A", "settle", "crash", "launch"] && op.finderRelaunched && finder.isRunning)
		// And that launch fails too: recorded as not relaunched (the undo itself holds; nothing more is opened).
		finder.reset()
		finder.onSettle = { [unowned finder] in
			finder.crash()
			finder.launchSucceeds = false
		}
		let undo = try applier.undo(op)
		#expect(finder.events == ["quit", "launch", "reopen A", "settle", "crash", "launch"] && !undo.finderRelaunched)
		#expect(domain.style() == "clmv")

		// The down time for other writes: the same settle and check.
		finder.reset()
		finder.launchSucceeds = true
		finder.onSettle = nil
		let plain = try applier.runWithFinderQuit {}
		#expect(plain.finderRelaunched && plain.reopenedWindows.map(\.lastPathComponent) == ["A"] && finder.events == ["quit", "launch", "reopen A", "settle"])
		finder.reset()
		finder.onSettle = { [unowned finder] in
			finder.crash()
			finder.launchSucceeds = false
		}
		let lost = try applier.runWithFinderQuit {}
		#expect(!lost.finderRelaunched && finder.events == ["quit", "launch", "reopen A", "settle", "crash", "launch"])
		// A Finder that does not come back is neither given its windows nor waited for.
		finder.reset()
		let down = try applier.runWithFinderQuit {}
		#expect(!down.finderRelaunched && down.reopenedWindows.isEmpty && finder.events == ["quit", "launch"])
	}

	// MARK: FinderController on scripted processes

	/// `quit` returns only once the old process has exited, not as soon as Finder has left the running applications (what
	/// Finder writes as it quits must be on disk before anything is written, and a launch must not find the old one).
	@Test func quitWaitsUntilTheOldProcessHasExited() {
		let fake = FakeProcesses()
		#expect(FinderController.quit(timeout: 10, processes: fake.processes))
		#expect(fake.events == ["askToQuit"] && fake.listed.isEmpty && fake.alive.isEmpty)
		#expect(fake.clock > 0.79 && fake.clock < 1)
	}

	/// A process that has left the list but does not exit is waited for `FinderController.exitTimeout` at most; the quit
	/// still counts as done (a failure would leave Finder quit without a launch). A Finder that stays listed is a failed
	/// quit after the timeout, and its exit is not waited for. A Finder that is not running is not asked anything.
	@Test func quitBoundsTheWaitsAndLeavesAMissingFinderAlone() {
		let slow = FakeProcesses()
		slow.exitsAfter = nil
		#expect(FinderController.quit(timeout: 10, processes: slow.processes))
		#expect(slow.alive == [100] && slow.clock >= 0.3 + FinderController.exitTimeout && slow.clock < 0.3 + FinderController.exitTimeout + 0.2)

		let stays = FakeProcesses()
		stays.leavesListAfter = nil
		#expect(!FinderController.quit(timeout: 3, processes: stays.processes))
		#expect(stays.listed == [100] && stays.clock >= 3 && stays.clock < 3.2)

		let none = FakeProcesses(running: false)
		#expect(FinderController.quit(timeout: 3, processes: none.processes))
		#expect(none.events.isEmpty && none.clock == 0)
	}

	/// `launch` asks once and waits until Finder runs; a Finder that already runs is not asked.
	@Test func launchWaitsForFinderAndLeavesARunningOneAlone() {
		let fake = FakeProcesses(running: false)
		let outcome = FinderController.launchReporting(timeout: 10, processes: fake.processes)
		#expect(outcome == FinderLaunch(running: true, attempts: 1, problems: []))
		#expect(fake.events == ["open"] && fake.clock >= 0.4 && fake.clock < 0.6)

		let running = FakeProcesses()
		#expect(FinderController.launchReporting(timeout: 10, processes: running.processes) == FinderLaunch(running: true, attempts: 0))
		#expect(running.events.isEmpty)
	}

	/// An error from `openApplication` is reported and Finder asked once more (after looking for it
	/// `FinderController.afterErrorWait`); a Finder that came up anyway is taken. A request after which Finder does not
	/// run in time is reported and asked once more too. Two failed attempts: not running, both reported.
	@Test func launchRetriesOnceAndReportsWhatWentWrong() {
		let failsOnce = FakeProcesses(running: false)
		failsOnce.launches = [("boom", nil), (nil, 0.2)]
		let retried = FinderController.launchReporting(timeout: 10, processes: failsOnce.processes)
		#expect(retried == FinderLaunch(running: true, attempts: 2, problems: ["openApplication (attempt 1): boom"]))
		#expect(failsOnce.events == ["open", "open"] && failsOnce.clock >= FinderController.afterErrorWait + 0.2)

		let upAnyway = FakeProcesses(running: false)
		upAnyway.launches = [("late", 0.5)]
		let late = FinderController.launchReporting(timeout: 10, processes: upAnyway.processes)
		#expect(late.running && late.attempts == 1 && late.problems.count == 1 && upAnyway.events == ["open"])

		let slow = FakeProcesses(running: false)
		slow.launches = [(nil, nil), (nil, 0.5)]
		let second = FinderController.launchReporting(timeout: 3, processes: slow.processes)
		#expect(second.running && second.attempts == 2 && second.problems == ["not running 3 s after the request (attempt 1)"])
		#expect(slow.events == ["open", "open"] && slow.clock >= 3.5 && slow.clock < 3.8)

		let never = FakeProcesses(running: false)
		never.launches = [(nil, nil)]
		let failed = FinderController.launchReporting(timeout: 3, processes: never.processes)
		#expect(!failed.running && failed.attempts == 2 && failed.problems.count == 2)
		#expect(never.events == ["open", "open"] && never.clock >= 6 && never.clock < 6.4)
		#expect(!FinderController.launch(timeout: 3, processes: FakeProcesses(running: false).withLaunches([(nil, nil)]).processes))
	}

	/// After an error from the last request Finder is looked for until that request's timeout has passed (LaunchServices
	/// can report an error for a Finder that still comes up), not only `afterErrorWait`: a Finder that shows up 3 or 4
	/// seconds after such an error is taken. One that never comes is given up once the timeout has passed.
	@Test func afterTheLastRequestsErrorFinderIsLookedForUntilItsTimeout() {
		let slowThenError = FakeProcesses(running: false)
		slowThenError.launches = [(nil, nil), ("boom", 3.0)]
		let late = FinderController.launchReporting(timeout: 10, processes: slowThenError.processes)
		#expect(late.running && late.attempts == 2 && late.problems.count == 2)
		#expect(slowThenError.events == ["open", "open"] && slowThenError.clock >= 13 && slowThenError.clock < 13.3)

		let twoErrors = FakeProcesses(running: false)
		twoErrors.launches = [("e", nil), ("e", 4.0)]
		let up = FinderController.launchReporting(timeout: 10, processes: twoErrors.processes)
		#expect(up == FinderLaunch(running: true, attempts: 2, problems: ["openApplication (attempt 1): e", "openApplication (attempt 2): e"]))
		#expect(twoErrors.clock >= FinderController.afterErrorWait + 4 && twoErrors.clock < FinderController.afterErrorWait + 4.3)

		let never = FakeProcesses(running: false)
		never.launches = [("e", nil)]
		let failed = FinderController.launchReporting(timeout: 3, processes: never.processes)
		#expect(!failed.running && failed.attempts == 2 && failed.problems.count == 2)
		#expect(never.clock >= FinderController.afterErrorWait + 3 && never.clock < FinderController.afterErrorWait + 3.3)
		// An error that comes at the very end of the timeout: still looked for `afterErrorWait`.
		let lastMoment = FakeProcesses(running: false)
		lastMoment.launches = [("e", nil)]
		lastMoment.answersAfter = 3
		#expect(!FinderController.launchReporting(timeout: 3, processes: lastMoment.processes).running)
		#expect(lastMoment.clock >= 2 * (3 + FinderController.afterErrorWait) && lastMoment.clock < 2 * (3 + FinderController.afterErrorWait) + 0.3)
	}

	/// With one attempt (the launch as the app quits, on the main thread: `AppModel.relaunchFinderLeftQuit`) Finder is
	/// asked once, and the wait stays within the timeout — `afterErrorWait` more when the error comes at its very end.
	@Test func aSingleAttemptAsksOnceAndStaysWithinItsTimeout() {
		let never = FakeProcesses(running: false)
		never.launches = [(nil, nil)]
		let outcome = FinderController.launchReporting(timeout: 5, attempts: 1, processes: never.processes)
		#expect(outcome == FinderLaunch(running: false, attempts: 1, problems: ["not running 5 s after the request (attempt 1)"]))
		#expect(never.events == ["open"] && never.clock >= 5 && never.clock < 5.2)

		let errorAtOnce = FakeProcesses(running: false)
		errorAtOnce.launches = [("e", nil)]
		#expect(!FinderController.launch(timeout: 5, attempts: 1, processes: errorAtOnce.processes))
		#expect(errorAtOnce.events == ["open"] && errorAtOnce.clock >= 5 && errorAtOnce.clock < 5.2)

		let errorAtTheEnd = FakeProcesses(running: false)
		errorAtTheEnd.launches = [("e", nil)]
		errorAtTheEnd.answersAfter = 5
		#expect(!FinderController.launch(timeout: 5, attempts: 1, processes: errorAtTheEnd.processes))
		#expect(errorAtTheEnd.events == ["open"] && errorAtTheEnd.clock >= 5 + FinderController.afterErrorWait && errorAtTheEnd.clock < 6.2)

		let upAfterError = FakeProcesses(running: false)
		upAfterError.launches = [("e", 2.5)]
		#expect(FinderController.launch(timeout: 5, attempts: 1, processes: upAfterError.processes) && upAfterError.events == ["open"])
		// Zero attempts still asks once.
		let zero = FakeProcesses(running: false)
		#expect(FinderController.launchReporting(timeout: 5, attempts: 0, processes: zero.processes).attempts == 1)
	}

	/// `RealFinderLifecycle` runs on the primitives it is given (here the scripted ones; its window read is only asked
	/// while they say Finder is not running, so no script is run), and `settleAndCheck` launches a Finder that went away
	/// while it settled once more.
	@Test func realLifecycleUsesTheInjectedPrimitivesAndRelaunchesAFinderThatDied() {
		let fake = FakeProcesses()
		let finder = RealFinderLifecycle(timeout: 5, processes: fake.processes)
		#expect(finder.quit() && !finder.isRunning)
		// A Finder that is not running is not asked for its windows (nothing is sent: `tell` would launch it).
		#expect(finder.openWindowFolders().isEmpty)
		#expect(finder.launch() && finder.isRunning)
		let beforeSettle = fake.clock
		#expect(finder.settleAndCheck())
		#expect(fake.clock - beforeSettle >= RealFinderLifecycle.settleTime && fake.events == ["askToQuit", "open"])

		// Finder goes away half a second into the settle: launched once more.
		fake.after(0.5) { fake.listed = [] }
		#expect(finder.settleAndCheck() && finder.isRunning && fake.events == ["askToQuit", "open", "open"])
		// And when that launch fails too: false.
		fake.launches = [(nil, nil)]
		fake.after(0.5) { fake.listed = [] }
		#expect(!finder.settleAndCheck() && !finder.isRunning)
	}
}

extension FinderLifecycleTests.FakeProcesses {
	func withLaunches(_ launches: [(error: String?, startsAfter: TimeInterval?)]) -> Self {
		self.launches = launches
		return self
	}
}

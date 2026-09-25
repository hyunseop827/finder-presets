import Foundation
import AppKit
import os

/// The process primitives `FinderController` quits and launches Finder with. `system` is the real Finder; the tests pass
/// fakes (scripted processes and a clock that `sleep` moves on), so the waits and the retry run without Finder.
public struct FinderProcesses: Sendable {
	/// The pids of the running Finder processes, as `NSRunningApplication` lists them.
	public var running: @Sendable () -> [pid_t]
	/// Whether the process still exists (`kill(pid, 0)`). `NSRunningApplication` stops listing Finder before its process
	/// has exited, i.e. possibly before it has written what it writes as it quits.
	public var exists: @Sendable (pid_t) -> Bool
	/// Asks Finder to quit: an Apple Event (needs the Automation permission), and `NSRunningApplication.terminate()` when
	/// that fails.
	public var askToQuit: @Sendable () -> Void
	/// Asks LaunchServices to open Finder and waits at most the given time for its answer: the error it reported, or nil
	/// (none, or no answer in time — the caller then looks whether Finder runs).
	public var open: @Sendable (TimeInterval) -> String?
	public var sleep: @Sendable (TimeInterval) -> Void
	public var now: @Sendable () -> Date

	public init(running: @escaping @Sendable () -> [pid_t], exists: @escaping @Sendable (pid_t) -> Bool,
	            askToQuit: @escaping @Sendable () -> Void, open: @escaping @Sendable (TimeInterval) -> String?,
	            sleep: @escaping @Sendable (TimeInterval) -> Void, now: @escaping @Sendable () -> Date) {
		self.running = running
		self.exists = exists
		self.askToQuit = askToQuit
		self.open = open
		self.sleep = sleep
		self.now = now
	}

	public var isRunning: Bool { !running().isEmpty }

	/// Looks every `FinderController.pollInterval` until `done` or `timeout` has passed; returns `done()` at the end.
	func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
		let deadline = now().addingTimeInterval(timeout)
		while !done() {
			guard now() < deadline else { return false }
			sleep(FinderController.pollInterval)
		}
		return true
	}

	public static let system = FinderProcesses(
		running: {
			NSRunningApplication.runningApplications(withBundleIdentifier: FinderController.bundleID).map(\.processIdentifier)
		},
		exists: { pid in kill(pid, 0) == 0 || errno == EPERM },
		askToQuit: {
			let apps = NSRunningApplication.runningApplications(withBundleIdentifier: FinderController.bundleID)
			var error: NSDictionary?
			if let script = NSAppleScript(source: "tell application \"Finder\" to quit") {
				script.executeAndReturnError(&error)
				if error == nil { return }
			}
			_ = apps.first?.terminate()
		},
		open: { timeout in
			let answer = OpenAnswer()
			NSWorkspace.shared.openApplication(at: FinderController.appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
				answer.finish(error.map { $0.localizedDescription })
			}
			return answer.wait(timeout)
		},
		sleep: { Thread.sleep(forTimeInterval: $0) },
		now: { Date() })

	/// The answer of `openApplication`'s completion handler, which runs on a queue of its own.
	private final class OpenAnswer: @unchecked Sendable {
		private let lock = NSLock()
		private let done = DispatchSemaphore(value: 0)
		private var error: String?

		func finish(_ error: String?) {
			lock.lock()
			self.error = error
			lock.unlock()
			done.signal()
		}

		func wait(_ timeout: TimeInterval) -> String? {
			guard done.wait(timeout: .now() + timeout) == .success else { return nil }
			lock.lock()
			defer { lock.unlock() }
			return error
		}
	}
}

/// What `FinderController.launchReporting` did.
public struct FinderLaunch: Equatable, Sendable {
	/// Finder runs.
	public var running = false
	/// How many times Finder was asked to open (0: it was already running).
	public var attempts = 0
	/// What went wrong on the way, in the order it happened: an error `openApplication` reported, a launch after which
	/// Finder did not run in time. Not empty after a retry.
	public var problems: [String] = []

	public init(running: Bool = false, attempts: Int = 0, problems: [String] = []) {
		self.running = running
		self.attempts = attempts
		self.problems = problems
	}
}

/// Minimal Finder control. Never used to write view options (that would change Finder's global defaults).
public enum FinderController {
	public static let bundleID = "com.apple.finder"
	public static let appURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
	/// How long `quit` waits, once Finder has left the running applications, for its old process to exit.
	public static let exitTimeout: TimeInterval = 5
	/// How long `launchReporting` looks for Finder after `openApplication` reported an error, before it asks again (after
	/// the last request: at least this long, and until that request's timeout has passed).
	public static let afterErrorWait: TimeInterval = 1
	/// How often the waits look again.
	public static let pollInterval: TimeInterval = 0.1
	/// At most this many windows are read (`openWindowFolders`), so a pathological count cannot make the read long.
	public static let windowReadLimit = 50

	static let log = Logger(subsystem: "com.hyunseop.FinderPresets", category: "Finder")

	public static var isRunning: Bool { FinderProcesses.system.isRunning }

	/// Quits Finder: asks it to quit (`FinderProcesses.askToQuit`), waits until it has left the running applications and
	/// then — at most `exitTimeout` — until the processes it had (their pids, taken before the request) have exited, so
	/// what Finder writes as it quits is on disk before the caller writes, and a launch cannot find the old process. A
	/// process that has left the list but is still exiting after that wait is logged, and the quit counts as done (Finder is
	/// no longer running as far as anyone can ask; reporting a failure would leave it quit without a launch). Returns
	/// false when Finder is still listed after `timeout`; true at once when it was not running (nothing is sent: `tell`
	/// would launch it first).
	@discardableResult
	public static func quit(timeout: TimeInterval = 10, processes: FinderProcesses = .system) -> Bool {
		let pids = processes.running()
		guard !pids.isEmpty else { return true }
		processes.askToQuit()
		guard processes.wait(timeout, until: { !processes.isRunning }) else { return false }
		if !processes.wait(exitTimeout, until: { !pids.contains(where: processes.exists) }) {
			log.error("Finder left the running applications but its process has not exited after \(exitTimeout, privacy: .public) s")
		}
		return true
	}

	/// Launches Finder and waits until it is running (`launchReporting`). Returns true once it is.
	@discardableResult
	public static func launch(timeout: TimeInterval = 10, attempts: Int = 2, processes: FinderProcesses = .system) -> Bool {
		let outcome = launchReporting(timeout: timeout, attempts: attempts, processes: processes)
		for problem in outcome.problems { log.error("Finder launch: \(problem, privacy: .public)") }
		return outcome.running
	}

	/// Asks LaunchServices to open Finder and waits — at most `timeout` from the request — until it runs. When the
	/// request reports an error or Finder does not run in time, it is asked again, `attempts` times in all (at least
	/// once); what went wrong is in `problems`. After an error Finder is looked for all the same (LaunchServices can
	/// report one for a Finder that still comes up): `afterErrorWait` before it is asked again, and after the last request
	/// until that request's `timeout` has passed (`afterErrorWait` at least). Nothing is asked when Finder already runs.
	/// The longest it takes: `attempts` × `timeout`, plus `afterErrorWait` after each error.
	public static func launchReporting(timeout: TimeInterval = 10, attempts: Int = 2, processes: FinderProcesses = .system) -> FinderLaunch {
		var outcome = FinderLaunch()
		let last = max(1, attempts)
		for attempt in 1...last {
			if processes.isRunning {
				outcome.running = true
				return outcome
			}
			outcome.attempts = attempt
			let deadline = processes.now().addingTimeInterval(timeout)
			if let error = processes.open(timeout) {
				outcome.problems.append("openApplication (attempt \(attempt)): \(error)")
				let look = attempt < last ? afterErrorWait : max(afterErrorWait, deadline.timeIntervalSince(processes.now()))
				if processes.wait(look, until: { processes.isRunning }) {
					outcome.running = true
					return outcome
				}
				continue
			}
			let left = max(0, deadline.timeIntervalSince(processes.now()))
			if processes.wait(left, until: { processes.isRunning }) {
				outcome.running = true
				return outcome
			}
			outcome.problems.append("not running \(Int(timeout)) s after the request (attempt \(attempt))")
		}
		return outcome
	}

	// MARK: Windows

	/// Asks Finder for the folder of each of its windows, front to back (`Finder window 1` is the frontmost; a tab counts
	/// as a window). Indices, never `every Finder window` (a loop over it fails silently). A window that shows no folder —
	/// a search, Recents, AirDrop, the computer — does not coerce to an alias and is skipped. The first event (`count`)
	/// keeps AppleScript's default timeout (2 minutes, like the quit): on a Mac where the app has not been allowed to
	/// control Finder yet it is the one that brings up the Automation prompt, and the time the user takes to answer is
	/// reported to count against the event's timeout (not checked here: a 5-second limit could fail the read, and the
	/// restart would go on without the windows). Every event after it waits at most 5 seconds; one that times out ends
	/// the read with what it has. At most `windowReadLimit` windows. Only reads.
	public static let windowFoldersSource = """
	tell application "Finder"
		set r to {}
		set n to count Finder windows
		if n > \(windowReadLimit) then set n to \(windowReadLimit)
		with timeout of 5 seconds
			repeat with i from 1 to n
				try
					set end of r to POSIX path of (target of Finder window i as alias)
				on error number e
					if e is -1712 then exit repeat
				end try
			end repeat
		end timeout
		return r
	end tell
	"""

	/// The folders Finder's windows show, front to back (`windowFoldersSource`); empty when Finder is not running (it is
	/// never launched for this: `processes` tells), when the Automation permission is missing or when the script fails.
	/// Off the main thread.
	public static func openWindowFolders(processes: FinderProcesses = .system) -> [URL] {
		guard processes.isRunning else { return [] }
		guard let script = NSAppleScript(source: windowFoldersSource) else { return [] }
		var error: NSDictionary?
		let answer = script.executeAndReturnError(&error)
		if let error {
			log.error("Reading Finder's windows failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public)")
			return []
		}
		return windowFolders(from: answer).map { URL(fileURLWithPath: $0) }
	}

	/// The script's answer: a list of POSIX paths, each normalized (no trailing slash); items that are not texts, and
	/// empty ones, are skipped. A lone text is one path.
	public static func windowFolders(from answer: NSAppleEventDescriptor) -> [String] {
		let items: [NSAppleEventDescriptor] = answer.descriptorType == fourCharCode("list")
			? (answer.numberOfItems > 0 ? (1...answer.numberOfItems).compactMap { answer.atIndex($0) } : [])
			: [answer]
		let texts = Set(["utxt", "utf8", "TEXT"].map(fourCharCode))
		return items.compactMap { item in
			guard texts.contains(item.descriptorType), let path = item.stringValue, !path.isEmpty else { return nil }
			return FolderRule.normalize(path)
		}
	}

	/// Asks Finder to open each folder in a window (`NSWorkspace.open`, the handler for folders), in this order: each lands
	/// in front of the ones before it. Returns those the request went out for.
	public static func open(_ folders: [URL]) -> [URL] {
		folders.filter { NSWorkspace.shared.open($0) }
	}

	static func fourCharCode(_ code: String) -> FourCharCode { code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}

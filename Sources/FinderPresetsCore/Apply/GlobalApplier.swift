import Foundation

/// How `GlobalApplier` — and the app's quick preset, "지금 다시 시작" and `finder-presets apply --relaunch` /
/// `relaunch-finder` — stop and start Finder. Abstracted so tests can run the whole sequence without touching the real
/// Finder. The order every path keeps: read the windows (`openWindowFolders`) → `quit` → write → `launch` → open the
/// windows again (`reopen`, `FinderWindows`) → the operation's own folders (the quick preset's, "지금 다시 시작"'s; none
/// on `GlobalApplier`'s paths) → `settleAndCheck` → read back. Only after a launch that brought Finder back: when it did
/// not, nothing is opened or waited for.
public protocol FinderLifecycle: Sendable {
	/// Returns true once Finder is no longer running.
	func quit() -> Bool
	/// Returns true once Finder is running again.
	func launch() -> Bool
	/// Whether Finder is running now (e.g. after a failure, to tell whether it came back).
	var isRunning: Bool { get }
	/// Waits a moment after a launch (and after a folder was asked to open) before what Finder may have written is read
	/// back. `launch` returns as soon as Finder's process exists, before it has opened anything; a read-back right then
	/// could not see what Finder writes while it starts. The real one pauses `RealFinderLifecycle.settleTime`; a fake
	/// returns at once (the default). Callers use `settleAndCheck`, which also makes sure Finder still runs afterwards.
	func settle()
	/// The folders of Finder's open windows, front to back, read right before a quit (`FinderWindows.remember`): Finder
	/// does not open its windows again after an Apple Event quit. Read only; nothing when Finder is not running. The
	/// default (a fake that does not care) has none.
	func openWindowFolders() -> [URL]
	/// Opens `folders` in Finder in this order, each in front of the ones before (`FinderWindows.reopen(in:before:)`, only
	/// after a launch that brought Finder back). Returns those it asked Finder to open. The default opens nothing.
	func reopen(_ folders: [URL]) -> [URL]
}

extension FinderLifecycle {
	public func settle() {}
	public func openWindowFolders() -> [URL] { [] }
	public func reopen(_ folders: [URL]) -> [URL] { [] }

	/// `settle`, then makes sure Finder still runs: a Finder that went away while it settled is launched once more (its
	/// windows are not opened a second time). Returns whether Finder runs.
	public func settleAndCheck() -> Bool {
		settle()
		return isRunning || launch()
	}
}

public struct RealFinderLifecycle: FinderLifecycle {
	/// How long `settle` waits: Finder's start-up write, if it makes one, has to happen within it to be seen. What Finder
	/// writes later (a window closed, Finder quit again) is never seen by the read-back.
	public static let settleTime: TimeInterval = 1.5
	public let timeout: TimeInterval
	public let processes: FinderProcesses
	public init(timeout: TimeInterval = 10, processes: FinderProcesses = .system) {
		self.timeout = timeout
		self.processes = processes
	}
	public func quit() -> Bool { FinderController.quit(timeout: timeout, processes: processes) }
	public func launch() -> Bool { FinderController.launch(timeout: timeout, processes: processes) }
	public var isRunning: Bool { processes.isRunning }
	public func settle() { processes.sleep(Self.settleTime) }
	public func openWindowFolders() -> [URL] { FinderController.openWindowFolders(processes: processes) }
	public func reopen(_ folders: [URL]) -> [URL] { FinderController.open(folders) }
}

public enum GlobalApplyError: Error, LocalizedError, Sendable {
	case nothingToApply
	case snapshotIncomplete
	case finderDidNotQuit
	case notUndoable(String)
	/// `undo(_:leaveFinderAlone:)` was asked to only record an undo, but the domain no longer holds the recorded values.
	case notAlreadyRestored
	/// The values read back after Finder was launched again are not the ones written. `diffs`: the properties this app
	/// understands that differ (empty when only values it does not decode differ). The caller words it (the app in its
	/// language, `finder-presets` with `errorDescription`).
	case verificationFailed(operationID: UUID, diffs: [FieldDiff])

	public var errorDescription: String? {
		switch self {
		case .nothingToApply: "프리셋에 Finder 기본값으로 쓸 값이 없습니다 (그룹 기준은 폴더에만 씁니다)"
		case .snapshotIncomplete: "현재 전역 설정을 기록하지 못해 중단했습니다 (아무것도 바꾸지 않음)"
		case .finderDidNotQuit: "Finder를 종료하지 못해 중단했습니다 (아무것도 바꾸지 않음). 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Finder 제어를 허용했는지 확인하세요"
		case .notUndoable(let m): "되돌릴 수 없는 작업입니다: \(m)"
		case .notAlreadyRestored: "전역 설정이 이미 기록한 값이 아니어서 기록만 하지 않았습니다 (Finder를 건드리지 않음)"
		case .verificationFailed(let id, let diffs):
			"적용 후 되읽은 값이 다릅니다 (작업 \(id.uuidString)): \(diffs.isEmpty ? "기록한 값과 다릅니다" : diffs.map(\.text).joined(separator: ", ")). 'global-undo \(id.uuidString)'로 되돌릴 수 있습니다"
		}
	}
}

/// Applies a preset to Finder's global defaults (`com.apple.finder`), with undo.
///
/// A running Finder holds these values in memory and writes them back to disk when it quits, so the
/// only order that sticks is: snapshot → quit Finder → write → launch Finder → verify. The snapshot is
/// saved to `operations/<id>/global-before.json` before Finder is touched (crash-safe), and refreshed
/// after the quit so the recorded "before" is what Finder itself last wrote. The folders of Finder's windows are read
/// right before the quit and opened again once Finder is back (`FinderWindows`); then Finder is given its moment to
/// settle and launched once more if it went away meanwhile (`FinderLifecycle.settleAndCheck`), before the read-back —
/// on every path that quit it, also when a write failed after the quit. `finderRelaunched` says whether it ran after
/// that check.
public struct GlobalApplier: Sendable {
	public let operations: OperationStore
	public let domain: String
	public let finder: any FinderLifecycle

	public init(operations: OperationStore, domain: String = GlobalDefaultsWriter.finderDomain, finder: any FinderLifecycle) {
		self.operations = operations
		self.domain = domain
		self.finder = finder
	}

	/// Merges the non-nil fields of `settings` into the domain. Throws before touching anything if Finder
	/// does not quit. Throws after saving the operation if the values read back do not match.
	///
	/// `whileFinderIsQuit` runs after Finder has quit and before the domain is written, so a caller can put
	/// other writes Finder would otherwise overwrite from its cache (e.g. the home folder's `.DS_Store`) into
	/// the same Finder-down window. It must not throw: report its own outcome and let this apply finish.
	/// `relatedOperation`, asked right after it, names the operation those writes recorded (the home folders' `apply`):
	/// it is saved as `relatedOperationID` before the domain is written, so the two records stay paired even when this
	/// apply fails later.
	///
	/// Only the part Finder's defaults hold is written (`ViewSettings.globalDefaultsPart`): a grouping is never written
	/// to `FXPreferredGroupBy`, and a preset that has nothing else throws `nothingToApply`.
	public func apply(_ settings: ViewSettings, presetName: String?, whileFinderIsQuit: () -> Void = {}, relatedOperation: () -> UUID? = { nil }) throws -> FinderPresetsOperation {
		let settings = settings.normalized().globalDefaultsPart
		guard !settings.isEmpty else { throw GlobalApplyError.nothingToApply }
		var op = FinderPresetsOperation(kind: .applyGlobal, presetName: presetName, presetSnapshot: settings, roots: [], writer: .current)
		OperationWriter.begin(op.id)
		defer { OperationWriter.end(op.id) }
		var before = try takeSnapshot()
		op.globalSnapshotFile = try operations.saveGlobalSnapshot(before, for: op)
		try operations.save(op)   // crash-safe: snapshot and manifest exist before Finder is touched

		let windows = FinderWindows.remember(finder)
		try quitFinder(discarding: op)
		whileFinderIsQuit()
		do {
			if let related = relatedOperation() {
				op.relatedOperationID = related
				try operations.save(op)
			}
			before = try refreshSnapshot(before, for: &op)
			let planned = GlobalDefaultsWriter.plannedValues(for: settings, current: before.standardViewSettingsDictionary)
			try GlobalDefaultsWriter.write(viewStyle: planned.viewStyle, standardViewSettings: planned.standardViewSettings, domain: domain)
		} catch {
			_ = relaunch(windows)   // never leave the user without a Finder; the manifest stays for undo
			throw error
		}
		op.finderRelaunched = relaunch(windows)

		let after = GlobalDefaultsWriter.snapshot(domain: domain)
		op.globalAfter = after
		op.finishedAt = Date()
		try operations.save(op)
		let diffs = after.decodedSettings.differences(to: settings)
		guard diffs.isEmpty else {
			throw GlobalApplyError.verificationFailed(operationID: op.id, diffs: diffs)
		}
		return op
	}

	/// Restores the domain to the snapshot `op` recorded, in the same quit → write → launch order.
	/// Undoing an `undoGlobal` operation redoes the apply.
	///
	/// When the domain already holds the recorded values, nothing is written and Finder is left alone: the undo is
	/// recorded all the same (finished, without a snapshot — there is nothing to redo), so `OperationHistory` counts `op`
	/// as undone and `global-undo last` moves on (`OperationHistory.foundAlreadyRestored`). With `leaveFinderAlone` (a
	/// confirmation that promised not to restart Finder), a domain that does not hold the recorded values throws
	/// `notAlreadyRestored` instead of quitting Finder.
	public func undo(_ op: FinderPresetsOperation, leaveFinderAlone: Bool = false) throws -> FinderPresetsOperation {
		guard op.kind.isGlobal else { throw GlobalApplyError.notUndoable("전역 작업이 아닙니다 (\(op.kind.rawValue))") }
		guard let file = op.globalSnapshotFile else { throw GlobalApplyError.notUndoable("스냅샷 파일이 기록되지 않았습니다") }
		let target = try operations.loadGlobalSnapshot(file, for: op)
		if target.standardViewSettings != nil, target.standardViewSettingsDictionary == nil { throw GlobalDefaultsError.corruptSnapshot }

		var undoOp = FinderPresetsOperation(kind: .undoGlobal, presetName: op.presetName, roots: [], undoOfOperationID: op.id, writer: .current)
		OperationWriter.begin(undoOp.id)
		defer { OperationWriter.end(undoOp.id) }
		let before = try takeSnapshot()
		if before.hasSameValues(as: target) {
			undoOp.globalAfter = before
			undoOp.finishedAt = Date()
			try operations.save(undoOp)
			return undoOp
		}
		guard !leaveFinderAlone else { throw GlobalApplyError.notAlreadyRestored }
		undoOp.globalSnapshotFile = try operations.saveGlobalSnapshot(before, for: undoOp)
		try operations.save(undoOp)

		let windows = FinderWindows.remember(finder)
		try quitFinder(discarding: undoOp)
		do {
			_ = try refreshSnapshot(before, for: &undoOp)
			try GlobalDefaultsWriter.restore(target, domain: domain)
		} catch {
			_ = relaunch(windows)
			throw error
		}
		undoOp.finderRelaunched = relaunch(windows)

		let after = GlobalDefaultsWriter.snapshot(domain: domain)
		undoOp.globalAfter = after
		undoOp.finishedAt = Date()
		try operations.save(undoOp)
		guard after.hasSameValues(as: target) else {
			throw GlobalApplyError.verificationFailed(operationID: undoOp.id, diffs: after.decodedSettings.differences(to: target.decodedSettings))
		}
		return undoOp
	}

	/// Quits Finder, runs `body` while it is down, then launches Finder again, opens its windows again and lets it settle
	/// (`relaunch`) — for writes that a running Finder would overwrite from its cache even though the domain itself is not
	/// touched, and for a plain restart (`finder-presets relaunch-finder`, with an empty body). A caller can read back
	/// what `body` wrote as soon as this returns. Throws `finderDidNotQuit` without running `body` when Finder stays
	/// alive; if `body` throws, Finder is launched again (and its windows opened) before the error propagates. Returns
	/// `body`'s value, whether Finder runs after the settle and the windows it opened again.
	public func runWithFinderQuit<T>(_ body: () throws -> T) throws -> (result: T, finderRelaunched: Bool, reopenedWindows: [URL]) {
		let windows = FinderWindows.remember(finder)
		guard finder.quit() else { throw GlobalApplyError.finderDidNotQuit }
		let result: T
		do { result = try body() } catch {
			_ = relaunch(windows)
			throw error
		}
		var reopened: [URL] = []
		let back = relaunch(windows) { reopened = $0 }
		return (result, back, reopened)
	}

	// MARK: Steps

	/// Launches Finder and, once it is back, opens the windows it showed before the quit (`FinderWindows`), then gives it
	/// its moment to settle and launches it once more if it went away meanwhile (`FinderLifecycle.settleAndCheck`: its
	/// windows are not opened a second time). Nothing is opened or waited for when it did not come back. Returns whether
	/// Finder runs at the end; `opened` gets the windows opened again.
	private func relaunch(_ windows: FinderWindows, opened: ([URL]) -> Void = { _ in }) -> Bool {
		guard finder.launch() else { return false }
		opened(windows.reopen(in: finder))
		return finder.settleAndCheck()
	}

	private func takeSnapshot() throws -> GlobalSnapshot {
		let s = GlobalDefaultsWriter.snapshot(domain: domain)
		// A dictionary that exists but could not be serialized must never be recorded as "absent": undo would delete it.
		if s.standardViewSettings == nil, GlobalDefaultsWriter.readStandardViewSettings(domain: domain) != nil {
			throw GlobalApplyError.snapshotIncomplete
		}
		return s
	}

	/// Aborts without writing when Finder stays alive; the operation directory is removed because nothing happened.
	private func quitFinder(discarding op: FinderPresetsOperation) throws {
		guard finder.quit() else {
			try? operations.delete(id: op.id)
			throw GlobalApplyError.finderDidNotQuit
		}
	}

	/// Finder writes its in-memory defaults on quit; if that changed anything, record those values as the real "before".
	private func refreshSnapshot(_ initial: GlobalSnapshot, for op: inout FinderPresetsOperation) throws -> GlobalSnapshot {
		let now = try takeSnapshot()
		guard !now.hasSameValues(as: initial) else { return initial }
		op.globalSnapshotFile = try operations.saveGlobalSnapshot(now, for: op)
		try operations.save(op)
		return now
	}
}

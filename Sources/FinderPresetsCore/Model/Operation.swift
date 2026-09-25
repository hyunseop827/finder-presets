import Foundation

public enum EntryStatus: String, Codable, Sendable, Equatable {
	case changed
	case skippedMatching
	case skippedConflict
	case failed
	/// No view record changed: only the icon positions in the folder's own `.DS_Store` (`OperationEntry.iconPositions`),
	/// for a folder that follows Finder's default view, which the same system-wide apply changed
	/// (`PlanCategory.iconPositionsOnly`); `before`/`after` stay nil. An undo puts the positions back unconditionally and
	/// records its own `positionsOnly` entry. Manifests written before it existed never hold it.
	case positionsOnly
}

/// One folder touched by an operation, with the managed records before and after.
public struct OperationEntry: Codable, Equatable, Sendable, Identifiable {
	public var id: String { folderPath }
	public var folderPath: String
	public var storePath: String
	public var key: String
	public var before: ManagedRecordSet?    // nil = parent .DS_Store did not exist
	public var after: ManagedRecordSet?
	public var status: EntryStatus
	public var error: String?
	/// The icon positions (`Iloc`) the operation changed in the folder's own `.DS_Store` together with its view records,
	/// or alone (`positionsOnly`): nil when it changed none. Optional, so manifests written before it
	/// existed still decode.
	public var iconPositions: IconPositionsChange?
	/// Why the icon positions could not be reset (the view change itself stands: the entry stays `changed`).
	public var iconPositionsError: String?

	public init(folderPath: String, storePath: String, key: String, before: ManagedRecordSet?, after: ManagedRecordSet?, status: EntryStatus, error: String? = nil,
	            iconPositions: IconPositionsChange? = nil, iconPositionsError: String? = nil) {
		self.folderPath = folderPath
		self.storePath = storePath
		self.key = key
		self.before = before
		self.after = after
		self.status = status
		self.error = error
		self.iconPositions = iconPositions
		self.iconPositionsError = iconPositionsError
	}
}

/// One record of a `.DS_Store` with the item name it belongs to (an `Iloc` of a file in the folder).
public struct NamedRecord: Codable, Equatable, Sendable {
	public var name: String
	public var record: RawRecord

	public init(name: String, record: RawRecord) {
		self.name = name
		self.record = record
	}
}

/// The icon positions (`Iloc` records) an operation changed in a folder's own `.DS_Store` (`storePath`). Finder keeps
/// them in "없음" (no arrangement) and "자동 격자 정렬": after an apply that changes the icon size or spacing on disk they would put
/// the new icons at the old places, overlapping, so the apply removes them and Finder lays the folder out anew
/// (`PlanEntry.resetsIconPositions`). `before` is what was stored for those items, `after` what the operation left
/// (an apply: nothing). Undoing puts `before` back for every item named in either list, so the same value serves the
/// undo of an undo.
public struct IconPositionsChange: Codable, Equatable, Sendable {
	public var storePath: String
	public var before: [NamedRecord]
	public var after: [NamedRecord]

	public init(storePath: String, before: [NamedRecord], after: [NamedRecord]) {
		self.storePath = storePath
		self.before = before
		self.after = after
	}

	/// Every item the change covers.
	public var names: [String] { Array(Set(before.map(\.name) + after.map(\.name))).sorted() }
}

public struct StoreBackup: Codable, Equatable, Sendable {
	public var storePath: String
	public var backupFile: String?     // relative to the operation directory; nil = store was absent
	public var sha256: String?

	public init(storePath: String, backupFile: String?, sha256: String?) {
		self.storePath = storePath
		self.backupFile = backupFile
		self.sha256 = sha256
	}
}

public enum OperationKind: String, Codable, Sendable {
	case apply, undo
	case applyGlobal, undoGlobal   // Finder's global defaults (com.apple.finder), see GlobalApplier

	public var isGlobal: Bool { self == .applyGlobal || self == .undoGlobal }
	/// An undo operation (`undo`, `undoGlobal`): it points at the operation it undid with `undoOfOperationID`.
	public var isUndo: Bool { self == .undo || self == .undoGlobal }
}

public struct FinderPresetsOperation: Codable, Identifiable, Equatable, Sendable {
	public var id: UUID
	public var kind: OperationKind
	public var startedAt: Date
	public var finishedAt: Date?
	public var presetName: String?
	public var presetSnapshot: ViewSettings?
	public var roots: [String]
	public var entries: [OperationEntry]
	public var backups: [StoreBackup]
	public var undoOfOperationID: UUID?
	public var finderRelaunched: Bool
	public var pinned: Bool
	// Global-defaults operations only (optional so manifests written before they existed still decode).
	public var globalSnapshotFile: String?      // relative to the operation directory: the domain's values before the write
	public var globalAfter: GlobalSnapshot?     // the domain's values re-read after Finder was relaunched
	/// The process that writes the manifest (optional: manifests written before it existed still decode). Tells an
	/// unfinished operation that is still being written from one its writer left behind (`isInProgress`).
	public var writer: OperationWriter?
	/// The record codes the entries' `before`/`after` cover (folder operations). Nil in manifests written before the
	/// grouping `GRP0` was managed: those cover `ManagedRecordSet.legacyCodes` (see `managedCodes`).
	public var recordCodes: [String]?
	/// The other record of the same "시스템 전체에 적용": on the `applyGlobal` record, the home folders' `apply` written in
	/// the same Finder-down window (nil when no folder changed, and in manifests written before it was recorded).
	public var relatedOperationID: UUID?

	public init(id: UUID = UUID(), kind: OperationKind, startedAt: Date = Date(), finishedAt: Date? = nil, presetName: String? = nil, presetSnapshot: ViewSettings? = nil, roots: [String], entries: [OperationEntry] = [], backups: [StoreBackup] = [], undoOfOperationID: UUID? = nil, finderRelaunched: Bool = false, pinned: Bool = false, globalSnapshotFile: String? = nil, globalAfter: GlobalSnapshot? = nil, writer: OperationWriter? = nil, recordCodes: [String]? = nil, relatedOperationID: UUID? = nil) {
		self.id = id
		self.kind = kind
		self.startedAt = startedAt
		self.finishedAt = finishedAt
		self.presetName = presetName
		self.presetSnapshot = presetSnapshot
		self.roots = roots
		self.entries = entries
		self.backups = backups
		self.undoOfOperationID = undoOfOperationID
		self.finderRelaunched = finderRelaunched
		self.pinned = pinned
		self.globalSnapshotFile = globalSnapshotFile
		self.globalAfter = globalAfter
		self.writer = writer
		self.recordCodes = recordCodes
		self.relatedOperationID = relatedOperationID
	}

	/// The record codes an undo of this operation reads, compares and restores (`recordCodes`, or the legacy set).
	public var managedCodes: [String] { recordCodes ?? ManagedRecordSet.legacyCodes }

	/// How long an operation without `finishedAt` and without a recorded `writer` (a manifest written before writers were
	/// recorded) counts as still being written. Applier, UndoService and GlobalApplier record `finishedAt` last, and a
	/// crash leaves it nil forever, so such an operation older than this is treated as a leftover. See `isInProgress(now:)`.
	public static let inProgressGrace: TimeInterval = 24 * 3600

	/// True while the operation is still being written: no `finishedAt` yet, and
	/// - written by this process: it is still inside the Applier / UndoService / GlobalApplier call that writes it (a call
	///   that returned or threw — e.g. a manifest that could not be saved — is over at once, whatever the manifest says);
	/// - written by another process (the app, `finder-presets`): that process is still running (same pid and start time);
	/// - no `writer` recorded (older manifests): started less than `inProgressGrace` ago (or, with a clock that went back,
	///   in the future).
	/// An unfinished operation that is not in progress was left behind (a crash, a forced quit, a failed save): the
	/// folders it recorded can be undone. Retention never removes an operation in progress, and `OperationStore.setPinned`
	/// does not rewrite its manifest.
	public func isInProgress(now: Date = Date()) -> Bool {
		guard finishedAt == nil else { return false }
		guard let writer else { return now.timeIntervalSince(startedAt) < Self.inProgressGrace }
		if writer.isCurrentProcess { return OperationWriter.isWriting(id) }
		return writer.isRunning
	}

	public var summary: OperationSummary {
		OperationSummary(
			changed: entries.filter { $0.status == .changed }.count,
			skipped: entries.filter { $0.status == .skippedMatching || $0.status == .skippedConflict }.count,
			failed: entries.filter { $0.status == .failed }.count,
			positionsOnly: entries.filter { $0.status == .positionsOnly }.count
		)
	}
}

public struct OperationSummary: Equatable, Sendable {
	/// Folders whose view records changed (what "N개 폴더 변경" counts).
	public let changed: Int
	public let skipped: Int
	public let failed: Int
	/// Folders whose icon positions alone changed (`EntryStatus.positionsOnly`), not counted in `changed`.
	public let positionsOnly: Int
}

/// The process that writes an operation (`FinderPresetsOperation.writer`): its pid and when it started, as the kernel reports them,
/// so a pid the system reuses later (another process, or after a restart) never counts as the same writer.
public struct OperationWriter: Codable, Equatable, Sendable {
	public var pid: Int32
	/// The process's start time (seconds since 1970, microsecond precision).
	public var processStart: Double

	public init(pid: Int32, processStart: Double) {
		self.pid = pid
		self.processStart = processStart
	}

	/// This process (nil only if the kernel does not report its start time).
	public static var current: OperationWriter? {
		let pid = getpid()
		return startTime(of: pid).map { OperationWriter(pid: pid, processStart: $0) }
	}

	/// The start time of process `pid`, or nil when there is no such process.
	public static func startTime(of pid: Int32) -> Double? {
		guard pid > 0 else { return nil }
		var info = kinfo_proc()
		var size = MemoryLayout<kinfo_proc>.stride
		var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
		guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
		let started = info.kp_proc.p_un.__p_starttime
		return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
	}

	/// The process that wrote the operation is this one.
	public var isCurrentProcess: Bool { self == Self.current }

	/// The process that wrote the operation is still running.
	public var isRunning: Bool { Self.startTime(of: pid).map { abs($0 - processStart) < 0.000_5 } ?? false }

	// Operations this process is writing right now (`begin` … `end`, around the whole write).

	private static let lock = NSLock()
	nonisolated(unsafe) private static var writing: Set<UUID> = []

	/// Called by the writers before an operation's first save.
	public static func begin(_ id: UUID) {
		lock.lock(); defer { lock.unlock() }
		writing.insert(id)
	}

	/// Called when the writing call returns or throws.
	public static func end(_ id: UUID) {
		lock.lock(); defer { lock.unlock() }
		writing.remove(id)
	}

	public static func isWriting(_ id: UUID) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return writing.contains(id)
	}
}

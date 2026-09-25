import Foundation

/// Which recorded operations can still be undone, and a short description of each. The app and `finder-presets undo` /
/// `finder-presets global-undo` use the same rules, so both offer the same operations.
///
/// - **Offered for undo** (`latestUndoable`, `isUndoable`): only folder applies (`apply`) and global
///   applies (`applyGlobal`) whose status is `.undoable`. An undo operation (`undo`, `undoGlobal`) is never offered;
///   `finder-presets undo <its ID>` / `finder-presets global-undo <its ID>` still take one explicitly and redo what it undid.
/// - **Undone**: an undo of the same family (folders or Finder's global defaults) points at the operation
///   (`undoOfOperationID`), took effect, and has not been undone itself. Undoing that undo (a redo) makes the original
///   undoable again. An undo takes effect when
///   - it put something back: a folder undo that restored at least one folder, a global undo that finished writing
///     (`restoredSomething`); or
///   - it found everything already as before and wrote nothing (`foundAlreadyRestored`: a folder undo whose every folder
///     was already back — e.g. its parent `.DS_Store` was deleted —, a global undo recorded without touching Finder).
///     Such an undo counts only when no undo that put something back is in effect and it is newer than the last time
///     the operation's changes came back (the operation itself, or the redo of an earlier undo). It is never undone
///     itself: there is nothing to redo.
///   An undo that skipped every folder as a conflict, or failed, leaves the operation undoable.
/// - **Nothing to undo**: a folder operation without a changed folder (view records or icon positions alone), a global
///   one without a recorded snapshot.
/// - An unfinished operation (no `finishedAt`) is judged the same way; the folders it recorded can be undone once it is
///   no longer in progress (`FinderPresetsOperation.isInProgress`). `OperationOverview.isFinished` / `inProgress` tell them apart.
public struct OperationHistory: Sendable {
	public enum UndoStatus: Equatable, Sendable {
		case undoable
		/// Undone by this undo operation (the newest one that took effect and is not undone itself).
		case undone(by: UUID)
		case nothingToUndo
	}

	/// Newest first.
	public let operations: [FinderPresetsOperation]
	/// When the history was read: `OperationOverview.inProgress` is judged at this moment.
	public let now: Date
	private let byID: [UUID: FinderPresetsOperation]
	private let undoneBy: [UUID: UUID]

	public init(_ operations: [FinderPresetsOperation], now: Date = Date()) {
		let sorted = operations.sorted(by: OperationStore.newestFirst)
		self.operations = sorted
		self.now = now
		var byID: [UUID: FinderPresetsOperation] = [:]
		for op in sorted where byID[op.id] == nil { byID[op.id] = op }
		self.byID = byID

		// Undo operations per target, newest first: only the target's family, and only the ones that took effect.
		var undos: [UUID: [FinderPresetsOperation]] = [:]
		for op in sorted where op.kind.isUndo {
			guard let target = op.undoOfOperationID.flatMap({ byID[$0] }),
			      target.kind.isGlobal == op.kind.isGlobal,
			      Self.tookEffect(op) else { continue }
			undos[target.id, default: []].append(op)
		}
		var memo: [UUID: UUID?] = [:]
		var visiting: Set<UUID> = []
		// The undo of `id` that is in effect, or nil: the newest one that put something back and is not undone itself
		// (redone); else the newest one that found everything already as before, if it is newer than the last time the
		// changes of `id` came back (`id` itself, or the redo of an earlier undo).
		func effectiveUndo(of id: UUID) -> UUID? {
			if let known = memo[id] { return known }
			guard visiting.insert(id).inserted else { return nil }   // a cycle can only come from edited manifests
			defer { visiting.remove(id) }
			let all = undos[id] ?? []
			let restoring = all.filter(Self.restoredSomething)
			var result = restoring.first { effectiveUndo(of: $0.id) == nil }?.id
			if result == nil {
				var back = byID[id]?.startedAt ?? .distantPast
				for undo in restoring {
					if let redo = effectiveUndo(of: undo.id).flatMap({ byID[$0] }), redo.startedAt > back { back = redo.startedAt }
				}
				result = all.first { Self.foundAlreadyRestored($0) && $0.startedAt > back }?.id
			}
			memo[id] = .some(result)
			return result
		}
		var undoneBy: [UUID: UUID] = [:]
		for op in sorted { undoneBy[op.id] = effectiveUndo(of: op.id) }
		self.undoneBy = undoneBy
	}

	/// Every readable operation of the store (see `OperationStore.list()`).
	public init(store: OperationStore, now: Date = Date()) throws {
		self.init(try store.list(), now: now)
	}

	public func operation(_ id: UUID) -> FinderPresetsOperation? { byID[id] }

	public func status(of op: FinderPresetsOperation) -> UndoStatus {
		if let by = undoneBy[op.id] { return .undone(by: by) }
		return Self.hasSomethingToRestore(op) ? .undoable : .nothingToUndo
	}

	/// True when the app (and `undo last` / `global-undo last`) may offer to undo `op`.
	public func isUndoable(_ op: FinderPresetsOperation) -> Bool {
		!op.kind.isUndo && status(of: op) == .undoable
	}

	/// What `finder-presets undo last` (global: false) and `finder-presets global-undo last` (global: true) pick.
	public func latestUndoable(global: Bool) -> FinderPresetsOperation? {
		operations.first { $0.kind.isGlobal == global && isUndoable($0) }
	}

	public func overview(of op: FinderPresetsOperation) -> OperationOverview {
		let counts = op.summary
		return OperationOverview(id: op.id, kind: op.kind, presetName: op.presetName, roots: op.roots,
		                         folderCount: counts.changed, positionsOnlyCount: counts.positionsOnly, skippedCount: counts.skipped, failedCount: counts.failed,
		                         startedAt: op.startedAt, finishedAt: op.finishedAt, pinned: op.pinned,
		                         undoOfOperationID: op.undoOfOperationID, status: status(of: op), canUndo: isUndoable(op),
		                         inProgress: op.isInProgress(now: now), foundAlreadyRestored: op.kind.isUndo && Self.foundAlreadyRestored(op))
	}

	/// An overview of every operation, newest first.
	public var overviews: [OperationOverview] { operations.map(overview(of:)) }

	// MARK: Rules

	/// Whether an undo operation counts for its target (see the type's documentation).
	static func tookEffect(_ undo: FinderPresetsOperation) -> Bool {
		restoredSomething(undo) || foundAlreadyRestored(undo)
	}

	/// An undo that put something back: a folder undo with a restored folder (view records, or icon positions alone:
	/// `positionsOnly`), a global undo that finished writing the recorded values (it saved a snapshot of what it replaced
	/// first).
	public static func restoredSomething(_ undo: FinderPresetsOperation) -> Bool {
		undo.kind.isGlobal ? undo.finishedAt != nil && undo.globalSnapshotFile != nil : undo.entries.contains(where: changedFolder)
	}

	/// An undo that found everything already as before and wrote nothing: a folder undo whose every folder was already
	/// back (`skippedMatching` only — no conflict, no failure), a global undo that finished without a snapshot (Finder's
	/// defaults already held the recorded values; `GlobalApplier.undo` left Finder alone).
	public static func foundAlreadyRestored(_ undo: FinderPresetsOperation) -> Bool {
		undo.kind.isGlobal ? undo.finishedAt != nil && undo.globalSnapshotFile == nil
			: !undo.entries.isEmpty && undo.entries.allSatisfy { $0.status == .skippedMatching }
	}

	/// Whether undoing `op` has anything to put back: changed folders (also those whose icon positions alone changed),
	/// or the global snapshot taken before the write.
	static func hasSomethingToRestore(_ op: FinderPresetsOperation) -> Bool {
		op.kind.isGlobal ? op.globalSnapshotFile != nil : op.entries.contains(where: changedFolder)
	}

	/// A folder the operation wrote something for: its view records, or its icon positions alone.
	private static func changedFolder(_ e: OperationEntry) -> Bool { e.status == .changed || e.status == .positionsOnly }
}

/// The folders one operation changed, as the history sheet lists them: grouped under the root they lie in, the roots in
/// the operation's own order and the folders in the order it wrote them, folders under none of the roots last. An undo
/// operation's changed folders are the ones it put back. A global operation changes Finder's defaults, not folders, and
/// has none. Folders whose icon positions alone changed (`positionsOnly`) are not listed: the texts count them apart
/// (`OperationOverview.positionsOnlyCount`). Holds no display text: the caller words it.
///
/// `limit` folders at most are listed, every root that has one first, so a listing never hides a root while it shows
/// several folders of another; the rest are counted in `hidden` ("외 N개").
public struct ChangedFolders: Equatable, Sendable {
	public struct Item: Equatable, Sendable, Identifiable {
		public var path: String
		/// The operation's root this folder lies in — the folder itself may be that root; "" for a folder under none of
		/// them (a record whose roots were not kept).
		public var root: String
		public var id: String { path }

		public init(path: String, root: String) {
			self.path = path
			self.root = root
		}
	}

	public let shown: [Item]
	/// Every folder the operation changed, the ones beyond `limit` included.
	public let total: Int

	public var hidden: Int { total - shown.count }
	public var isEmpty: Bool { total == 0 }

	public init(_ op: FinderPresetsOperation, limit: Int = 8) {
		let changed = op.entries.filter { $0.status == .changed }.map(\.folderPath)
		total = changed.count
		// The deepest root that holds the folder, so nested roots name the folder's own one.
		let roots = op.roots
		func root(of path: String) -> String {
			roots.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count } ?? ""
		}
		var folders: [String: [String]] = [:]
		for path in changed { folders[root(of: path), default: []].append(path) }
		var order = roots.filter { folders[$0] != nil }
		if folders[""] != nil { order.append("") }
		order = order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }   // a root named twice is one group
		// One folder per root first, then the rest in order, up to `limit`.
		var take = [Int](repeating: 0, count: order.count)
		var room = limit
		for i in take.indices where room > 0 {
			take[i] = 1
			room -= 1
		}
		for i in take.indices where room > 0 {
			let more = min(room, (folders[order[i]]?.count ?? 0) - take[i])
			take[i] += more
			room -= more
		}
		shown = order.indices.flatMap { i in
			(folders[order[i]] ?? []).prefix(take[i]).map { Item(path: $0, root: order[i]) }
		}
	}
}

/// A short description of one recorded operation — what the app lists and `finder-presets ops` prints. Holds no display text:
/// the caller words it (and localizes it).
public struct OperationOverview: Sendable, Equatable, Identifiable {
	public let id: UUID
	public let kind: OperationKind
	/// The preset, or every preset name of a mixed apply; nil when none was recorded.
	public let presetName: String?
	/// The folders the operation was started on; empty for a global operation.
	public let roots: [String]
	/// Folders the operation changed (`changed` entries). Always 0 for a global operation, which changes Finder's
	/// defaults instead (`isGlobal`).
	public let folderCount: Int
	/// Folders whose icon positions alone the operation changed (`EntryStatus.positionsOnly`), not in `folderCount`.
	public let positionsOnlyCount: Int
	public let skippedCount: Int
	public let failedCount: Int
	public let startedAt: Date
	public let finishedAt: Date?
	public let pinned: Bool
	/// For an undo operation: the operation it undid.
	public let undoOfOperationID: UUID?
	public let status: OperationHistory.UndoStatus
	/// True when the operation may be offered for undo (`OperationHistory.isUndoable`).
	public let canUndo: Bool
	/// Still being written when the history was read (`FinderPresetsOperation.isInProgress`): not undone or pinned until it finishes.
	public let inProgress: Bool
	/// An undo that found everything already as before and wrote nothing (`OperationHistory.foundAlreadyRestored`).
	public let foundAlreadyRestored: Bool

	public var isGlobal: Bool { kind.isGlobal }
	public var isUndo: Bool { kind.isUndo }
	public var isFinished: Bool { finishedAt != nil }
}

import Foundation

/// What retention removes and keeps, and why. Made by `OperationStore.retentionPlan(policy:now:)` without changing
/// anything; carried out by `OperationStore.applyRetention(_:)`.
public struct RetentionPlan: Sendable, Equatable {
	/// Why an operation is over the policy. It is removed unless it is protected.
	public enum Reason: String, Sendable, Equatable, CaseIterable {
		case tooOld       // started more than `maxAge` ago
		case overCount    // `maxCount` newer unprotected operations are already kept
		case overSize     // keeping it would take the kept unprotected operations over `maxBytes`
	}

	/// Why an operation is kept whatever the limits say.
	public enum Protection: String, Sendable, Equatable, CaseIterable {
		case pinned               // `FinderPresetsOperation.pinned` (`OperationStore.setPinned`)
		case inProgress           // `FinderPresetsOperation.isInProgress(now:)`
		case latestUndoable       // what the app, `undo last` or `global-undo last` would undo next
		case undoOfKeptOperation  // an undo whose target is kept: without it the target would look not undone
	}

	public struct Item: Sendable, Equatable, Identifiable {
		public var id: UUID { operation.id }
		/// The manifest as read for the plan. `applyRetention(_:)` removes the operation only while it is still exactly this.
		public let operation: FinderPresetsOperation
		public let overview: OperationOverview
		/// Size of the operation directory (manifest, backups, global snapshot).
		public let bytes: Int64
		/// Every limit the operation is over; empty when it is within the policy.
		public let reasons: [Reason]
		public let protection: Protection?

		public var isRemoved: Bool { protection == nil && !reasons.isEmpty }
	}

	public let policy: RetentionPolicy
	public let now: Date
	/// The `operations` folder the plan was made for.
	public let operationsDirectory: URL
	/// Every readable operation, newest first.
	public let items: [Item]
	/// Operation directories whose manifest could not be read ("<directory>: <reason>"). They are never removed.
	public let unreadable: [String]

	public var removed: [Item] { items.filter(\.isRemoved) }
	public var kept: [Item] { items.filter { !$0.isRemoved } }
	public var protected: [Item] { items.filter { $0.protection != nil } }
	public var removedBytes: Int64 { removed.reduce(0) { $0 + $1.bytes } }
	public var keptBytes: Int64 { kept.reduce(0) { $0 + $1.bytes } }
}

public struct RetentionResult: Sendable, Equatable {
	public struct Failure: Sendable, Equatable {
		public let id: UUID
		public let message: String
	}

	public let plan: RetentionPlan
	/// Operations whose directory (manifest and backups) was deleted.
	public let removed: [UUID]
	/// Planned for removal but left alone: changed on disk since the plan (pinned, finished, rewritten), gone, still in
	/// progress, or the plan was made for another data folder.
	public let skipped: [UUID]
	public let failed: [Failure]
}

extension OperationStore {
	/// Decides which operations the policy removes, without changing anything.
	///
	/// 1. Protected operations are always kept and do not use up the policy's count or size:
	///    - pinned ones (`setPinned`);
	///    - ones still in progress (`FinderPresetsOperation.isInProgress`: no `finishedAt` and the process writing it still at it;
	///      an unfinished one whose writer is gone is a leftover and follows the limits);
	///    - the newest folder operation and the newest global operation that can still be undone
	///      (`OperationHistory.latestUndoable`: what the app, `undo last` and `global-undo last` would undo next), however old;
	///    - an undo operation whose target is kept, however old: removing it would make the target look not undone, and
	///      it would be offered for undo a second time. So the undo status of every kept operation stays as it was.
	/// 2. The other operations are taken newest first. One is removed when it started more than `maxAge` ago, when
	///    `maxCount` newer ones are already kept, or when keeping it would take the kept ones over `maxBytes` (an older,
	///    smaller operation may still fit after a large one is removed).
	/// 3. Operation directories whose manifest cannot be read are never removed (`RetentionPlan.unreadable`).
	public func retentionPlan(policy: RetentionPolicy = .standard, now: Date = Date()) throws -> RetentionPlan {
		let listing = try listReadable()
		let history = OperationHistory(listing.operations, now: now)
		let latest = Set([history.latestUndoable(global: false), history.latestUndoable(global: true)].compactMap { $0?.id })

		var protection: [UUID: RetentionPlan.Protection] = [:]
		var reasons: [UUID: [RetentionPlan.Reason]] = [:]
		var bytes: [UUID: Int64] = [:]
		var keptCount = 0
		var keptBytes: Int64 = 0
		for op in history.operations {
			let size = directorySize(directory(for: op.id))
			bytes[op.id] = size
			var why: [RetentionPlan.Reason] = []
			if now.timeIntervalSince(op.startedAt) > policy.maxAge { why.append(.tooOld) }
			if keptCount >= policy.maxCount { why.append(.overCount) }
			if keptBytes + size > policy.maxBytes { why.append(.overSize) }
			reasons[op.id] = why
			if op.pinned {
				protection[op.id] = .pinned
			} else if op.isInProgress(now: now) {
				protection[op.id] = .inProgress
			} else if latest.contains(op.id) {
				protection[op.id] = .latestUndoable
			} else if why.isEmpty {
				keptCount += 1
				keptBytes += size
			}
		}
		// An undo stays while the operation it undid stays; repeated because keeping an undo can keep the undo of it (a redo).
		func isKept(_ id: UUID) -> Bool { protection[id] != nil || reasons[id]?.isEmpty == true }
		var changed = true
		while changed {
			changed = false
			for op in history.operations where op.kind.isUndo && !isKept(op.id) {
				guard let target = op.undoOfOperationID, isKept(target) else { continue }
				protection[op.id] = .undoOfKeptOperation
				changed = true
			}
		}
		let items = history.operations.map { op in
			RetentionPlan.Item(operation: op, overview: history.overview(of: op), bytes: bytes[op.id] ?? 0,
			                   reasons: reasons[op.id] ?? [], protection: protection[op.id])
		}
		return RetentionPlan(policy: policy, now: now, operationsDirectory: dirs.operations, items: items, unreadable: listing.unreadable)
	}

	/// Deletes the directories (manifest, backups, global snapshot) of the operations `plan` removes — and only those.
	/// An operation is left alone when its manifest is no longer exactly what the plan read (pinned, finished or
	/// rewritten since), when it is gone or still in progress, or when the plan was made for another data folder.
	/// Deleted backups cannot be restored: an operation removed here can no longer be undone.
	@discardableResult
	public func applyRetention(_ plan: RetentionPlan) -> RetentionResult {
		var removed: [UUID] = []
		var skipped: [UUID] = []
		var failed: [RetentionResult.Failure] = []
		let sameFolder = plan.operationsDirectory.standardizedFileURL.path == dirs.operations.standardizedFileURL.path
		for item in plan.removed {
			guard sameFolder, let current = try? load(id: item.id), current == item.operation, !current.isInProgress(now: Date()) else {
				skipped.append(item.id)
				continue
			}
			do {
				try delete(id: item.id)
				removed.append(item.id)
			} catch {
				failed.append(RetentionResult.Failure(id: item.id, message: error.localizedDescription))
			}
		}
		return RetentionResult(plan: plan, removed: removed, skipped: skipped, failed: failed)
	}

	/// Plans and applies the policy in one step (`retentionPlan(policy:now:)` has the rules). The app calls it once at
	/// launch and again after every operation it records (an apply, a whole-system apply, an undo), on a background task
	/// while it runs; nothing runs when the app is not running. `finder-presets prune` shows the plan and asks first.
	@discardableResult
	public func applyRetention(policy: RetentionPolicy = .standard, now: Date = Date()) throws -> RetentionResult {
		applyRetention(try retentionPlan(policy: policy, now: now))
	}
}

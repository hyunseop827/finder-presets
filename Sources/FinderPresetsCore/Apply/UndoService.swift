import Foundation
import DSStore

public struct UndoPreview: Sendable, Equatable {
	public struct Item: Sendable, Equatable, Identifiable {
		public var id: String { folderPath }
		public let folderPath: String
		public let conflict: Bool          // current records differ from what the operation wrote (and are not already the "before")
		public let alreadyRestored: Bool   // current records are already exactly the "before": undo leaves the folder alone
		/// The parent `.DS_Store` exists but cannot be read (the reason): its state is unknown, so the folder is neither a
		/// conflict nor already restored, and the undo records it as failed. Nil when it was read (or is absent).
		public let unreadable: String?

		public init(folderPath: String, conflict: Bool, alreadyRestored: Bool, unreadable: String? = nil) {
			self.folderPath = folderPath
			self.conflict = conflict
			self.alreadyRestored = alreadyRestored
			self.unreadable = unreadable
		}
	}
	public let items: [Item]
	public var conflicts: [Item] { items.filter(\.conflict) }
	public var alreadyRestored: [Item] { items.filter(\.alreadyRestored) }
	public var unreadable: [Item] { items.filter { $0.unreadable != nil } }
	/// The folders the undo will put back: neither conflicting, already restored nor unreadable.
	public var restorable: [Item] { items.filter { !$0.conflict && !$0.alreadyRestored && $0.unreadable == nil } }
}

/// Record-level undo: puts each folder's managed records back to the `before` snapshot, and with them the icon positions
/// the operation changed (`OperationEntry.iconPositions`) — also those it changed alone (`EntryStatus.positionsOnly`).
public struct UndoService: Sendable {
	public let operations: OperationStore
	public init(operations: OperationStore) { self.operations = operations }

	/// What undoing `op` would do to each folder it changed, read from the parent stores now (nothing is written). A parent
	/// store that is absent holds no records; one that cannot be read is reported as unreadable, never as "already as
	/// before" or as a conflict. A folder whose icon positions alone changed (`positionsOnly`) is always put back (see
	/// `undo`): it is restorable unless its own `.DS_Store` cannot be read. Each store is read once, however many of the
	/// folders it holds.
	public func preview(_ op: FinderPresetsOperation) -> UndoPreview {
		var stores = StoreReads()
		let positionsOnly = op.entries.filter { $0.status == .positionsOnly && $0.iconPositions != nil }.map { e in
			if case .failure(let error) = stores.read(URL(fileURLWithPath: e.iconPositions!.storePath)) {
				return UndoPreview.Item(folderPath: e.folderPath, conflict: false, alreadyRestored: false, unreadable: Self.reason(error))
			}
			return UndoPreview.Item(folderPath: e.folderPath, conflict: false, alreadyRestored: false)
		}
		let items = op.entries.filter { $0.status == .changed }.map { e in
			let current: ManagedRecordSet
			switch stores.read(URL(fileURLWithPath: e.storePath)) {
			case .failure(let error):
				return UndoPreview.Item(folderPath: e.folderPath, conflict: false, alreadyRestored: false, unreadable: Self.reason(error))
			case .success(let read):
				current = read.store.map { StoreEditor.managedRecords(in: $0, key: e.key, codes: op.managedCodes) } ?? ManagedRecordSet()
			}
			let restored = UndoService.isAlreadyRestored(current: current, before: e.before)
			return UndoPreview.Item(folderPath: e.folderPath, conflict: !restored && UndoService.isConflict(current: current, written: e.after),
			                        alreadyRestored: restored)
		}
		return UndoPreview(items: items + positionsOnly)
	}

	/// Why a store could not be read, without `StoreEditorError`'s own prefix.
	private static func reason(_ error: any Error) -> String {
		if case StoreEditorError.unreadable(let detail) = error { return detail }
		return error.localizedDescription
	}

	/// The folder's managed records are already exactly what they were before the operation (an earlier undo, or the
	/// user put them back): undo has nothing to write there. Compared record by record, not only the decoded properties,
	/// so a record the operation added (e.g. `vSrn`) is never left behind.
	static func isAlreadyRestored(current: ManagedRecordSet, before: ManagedRecordSet?) -> Bool {
		current == (before ?? ManagedRecordSet())
	}

	/// Records of the same items, in any order (a store lists them by its own order).
	static func sameIconPositions(_ a: [NamedRecord], _ b: [NamedRecord]) -> Bool {
		a.count == b.count && a.allSatisfy { r in b.contains(r) }
	}

	/// Finder adds keys such as scroll position to records it has displayed; only the properties this app
	/// manages count as a conflict.
	static func isConflict(current: ManagedRecordSet, written: ManagedRecordSet?) -> Bool {
		ViewRecordCodec.decode(current) != ViewRecordCodec.decode(written ?? ManagedRecordSet())
	}

	/// - Parameter force: also restore folders whose current state conflicts with what the operation wrote.
	///
	/// A folder already exactly as before is left alone and recorded as `skippedMatching`; when that is true of every
	/// folder, the undo writes nothing but still counts: `OperationHistory` then treats `op` as undone.
	///
	/// Only the record codes `op` recorded are read, compared and restored (`FinderPresetsOperation.managedCodes`): undoing an
	/// operation recorded before the grouping `GRP0` was managed leaves a folder's `GRP0` as it is. The undo records the
	/// same codes, so undoing it in turn covers the same records.
	public func undo(_ op: FinderPresetsOperation, force: Bool = false) throws -> FinderPresetsOperation {
		let codes = op.managedCodes
		var undoOp = FinderPresetsOperation(kind: .undo, presetName: op.presetName, roots: op.roots, undoOfOperationID: op.id, writer: .current, recordCodes: codes)
		OperationWriter.begin(undoOp.id)
		defer { OperationWriter.end(undoOp.id) }
		try operations.save(undoOp)
		let changed = op.entries.filter { $0.status == .changed }
		let byStore = Dictionary(grouping: changed, by: \.storePath)
		// Icon positions the operation changed, by the store that holds them (the folder's own `.DS_Store`): with a view
		// change, alone on a `skippedMatching` entry (an undo that put only the positions back — undoing it removes them
		// again), or alone on a `positionsOnly` entry (a folder that follows Finder's default view).
		let positionsByStore = Dictionary(grouping: op.entries.filter {
			$0.iconPositions != nil && [.changed, .skippedMatching, .positionsOnly].contains($0.status)
		}) { $0.iconPositions!.storePath }
		var restoredIndex: [String: Int] = [:]   // folder path → its `changed` entry in `undoOp.entries`
		var matchingIndex: [String: Int] = [:]   // folder path → its `skippedMatching` (or `positionsOnly`) entry in `undoOp.entries`
		for storePath in Applier.writeOrder(Set(byStore.keys).union(positionsByStore.keys)) {
			let entries = byStore[storePath] ?? []
			let positionEntries = positionsByStore[storePath] ?? []
			guard !entries.isEmpty || positionEntries.contains(where: {
				$0.status != .changed || restoredIndex[$0.folderPath] != nil || matchingIndex[$0.folderPath] != nil
			}) else { continue }
			let url = URL(fileURLWithPath: storePath)
			do {
				let backup = try operations.backup(store: url, for: undoOp)
				undoOp.backups.append(backup)
				var store = try StoreEditor.read(url).store ?? DSStore()
				var restored: [OperationEntry] = []
				for e in entries {
					let current = StoreEditor.managedRecords(in: store, key: e.key, codes: codes)
					if UndoService.isAlreadyRestored(current: current, before: e.before) {
						// Nothing to write (with or without `force`); recorded so the undo does not count as having changed it.
						matchingIndex[e.folderPath] = undoOp.entries.count
						undoOp.entries.append(OperationEntry(folderPath: e.folderPath, storePath: storePath, key: e.key, before: current, after: current, status: .skippedMatching))
						continue
					}
					if UndoService.isConflict(current: current, written: e.after) && !force {
						undoOp.entries.append(OperationEntry(folderPath: e.folderPath, storePath: storePath, key: e.key, before: current, after: current, status: .skippedConflict, error: "적용 이후 다른 변경이 있어 건너뜀"))
						continue
					}
					store = StoreEditor.restore(e.before ?? ManagedRecordSet(), for: e.key, in: store, codes: codes)
					restored.append(OperationEntry(folderPath: e.folderPath, storePath: storePath, key: e.key, before: current, after: e.before ?? ManagedRecordSet(), status: .changed))
				}
				// The positions go back with the view records only (a folder skipped above keeps what it has now): those of
				// folders restored in an earlier store (the write order puts a folder's location store first) or in this one.
				// Positions Finder stored since are derived from the layout and overwritten; they are recorded, so undoing
				// this undo puts them back. A folder whose view records were already back gets its positions back only while
				// they are still exactly as the operation left them: an earlier undo that restored the view records but
				// failed to write this store (`iconPositionsError`) is then completed by `undo --force`.
				// A positions-only change of an undo (see above) goes back while the positions are still as it left them, or
				// with `force`. A `positionsOnly` entry goes back unconditionally, as positions restored with view records do:
				// no view record of the folder changed, so nothing else can conflict, and the positions Finder stored since
				// are recorded in this undo's own `positionsOnly` entry.
				var positions: [String: IconPositionsChange] = [:]
				var positionsOnly: [OperationEntry] = []
				for e in positionEntries {
					let change = e.iconPositions!
					let current = StoreEditor.iconPositions(in: store, names: change.names)
					let untouched = Self.sameIconPositions(current, change.after)
					let restore = switch e.status {
						case .positionsOnly: true
						case .skippedMatching: force || untouched
						default: restoredIndex[e.folderPath] != nil || restored.contains(where: { $0.folderPath == e.folderPath })
							|| (matchingIndex[e.folderPath] != nil && untouched)
					}
					guard restore else { continue }
					store = StoreEditor.replaceIconPositions(of: change.names, with: change.before, in: store)
					positions[e.folderPath] = IconPositionsChange(storePath: storePath, before: current, after: change.before)
					if e.status == .skippedMatching {
						positionsOnly.append(OperationEntry(folderPath: e.folderPath, storePath: e.storePath, key: e.key, before: e.after, after: e.after,
						                                    status: .skippedMatching))
					} else if e.status == .positionsOnly {
						positionsOnly.append(OperationEntry(folderPath: e.folderPath, storePath: e.storePath, key: e.key, before: nil, after: nil,
						                                    status: .positionsOnly))
					}
				}
				if !restored.isEmpty || !positions.isEmpty {
					let createdByOriginalApply = op.backups.contains { $0.storePath == storePath && $0.backupFile == nil }
					if createdByOriginalApply && store.records.isEmpty {
						// The store did not exist before the apply and is empty again: leave no trace (it may already be gone).
						if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
					} else {
						try StoreEditor.write(store, to: url)
					}
				}
				for e in restored {
					restoredIndex[e.folderPath] = undoOp.entries.count
					undoOp.entries.append(e)
				}
				for e in positionsOnly {
					matchingIndex[e.folderPath] = undoOp.entries.count
					undoOp.entries.append(e)
				}
				for (folder, change) in positions {
					if let i = restoredIndex[folder] ?? matchingIndex[folder] { undoOp.entries[i].iconPositions = change }
				}
			} catch {
				for e in entries {
					undoOp.entries.append(OperationEntry(folderPath: e.folderPath, storePath: storePath, key: e.key, before: nil, after: nil, status: .failed, error: error.localizedDescription))
				}
				// A folder whose view records were restored in another store keeps that; only its positions stay as they are.
				for e in positionEntries {
					if e.status == .positionsOnly {
						undoOp.entries.append(OperationEntry(folderPath: e.folderPath, storePath: e.storePath, key: e.key, before: nil, after: nil,
						                                     status: .failed, error: error.localizedDescription))
					} else if let i = restoredIndex[e.folderPath] ?? matchingIndex[e.folderPath] {
						undoOp.entries[i].iconPositionsError = error.localizedDescription
					}
				}
			}
			try operations.save(undoOp)
		}
		undoOp.finishedAt = Date()
		try operations.save(undoOp)
		return undoOp
	}
}

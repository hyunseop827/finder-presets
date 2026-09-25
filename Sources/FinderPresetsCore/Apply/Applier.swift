import Foundation
import DSStore

public struct ApplyRequest: Sendable {
	public var plan: Plan
	public var presetName: String?
	public var presetSnapshot: ViewSettings?
	public init(plan: Plan, presetName: String? = nil, presetSnapshot: ViewSettings? = nil) {
		self.plan = plan
		self.presetName = presetName
		self.presetSnapshot = presetSnapshot
	}
}

/// Executes a plan: per parent .DS_Store → backup → merge managed records of each target child → atomic write.
/// Failures are recorded per parent group; other groups continue (partial success). A folder planned with
/// `resetsIconPositions` also loses the icon positions in its own `.DS_Store` (backed up and written the same way); a
/// failure there never fails its view change (`OperationEntry.iconPositionsError`). A folder planned
/// `iconPositionsOnly` loses only its positions, recorded as a `positionsOnly` entry (or `failed`).
public struct Applier: Sendable {
	public let operations: OperationStore
	public let globals: GlobalDefaults

	public init(operations: OperationStore, globals: GlobalDefaults) {
		self.operations = operations
		self.globals = globals
	}

	public func apply(_ request: ApplyRequest, progress: (@Sendable (String) -> Void)? = nil) throws -> FinderPresetsOperation {
		var op = FinderPresetsOperation(kind: .apply, presetName: request.presetName, presetSnapshot: request.presetSnapshot, roots: request.plan.roots.map(\.path),
		                      writer: .current, recordCodes: ManagedRecordSet.managedCodes)
		// In progress until this call returns or throws (`FinderPresetsOperation.isInProgress`): a manifest left without `finishedAt`
		// (a save that failed) is at once a leftover that can be undone, not an operation that is still running.
		OperationWriter.begin(op.id)
		defer { OperationWriter.end(op.id) }
		try operations.save(op)   // crash-safe: manifest exists before any write
		let groups = Dictionary(grouping: request.plan.changes) { $0.location!.storeURL.path }
		// Folders whose icon positions are reset, by their own store: one read-modify-write per file, also when the same
		// file holds view records the apply writes (the children of a folder changed with it, the home folder's ".").
		let resets = Dictionary(grouping: request.plan.changes.filter(\.resetsIconPositions)) { $0.ownStoreURL.path }
		// Folders whose positions alone are reset (`PlanCategory.iconPositionsOnly`): they follow Finder's default view,
		// which the same system-wide apply writes, so they wait for no view change of their own.
		let alone = Dictionary(grouping: request.plan.entries.filter { $0.category == .iconPositionsOnly }) { $0.ownStoreURL.path }
		var changedIndex: [String: Int] = [:]   // folder path → its `changed` entry in `op.entries`
		for storePath in Self.writeOrder(Set(groups.keys).union(resets.keys).union(alone.keys)) {
			let storeURL = URL(fileURLWithPath: storePath)
			let entries = groups[storePath] ?? []
			let positionsOnly = alone[storePath] ?? []
			// Positions are reset only with a view change that was written: in a store written earlier (the write order
			// puts a folder's location store before its own) or in this one.
			let resetting = (resets[storePath] ?? []).filter { r in changedIndex[r.folder.path] != nil || entries.contains { $0.folder == r.folder } }
			guard !entries.isEmpty || !resetting.isEmpty || !positionsOnly.isEmpty else { continue }
			progress?("\(storeURL.deletingLastPathComponent().path)")
			do {
				let read = try StoreEditor.read(storeURL)
				let absent = read.store == nil
				var store = read.store ?? DSStore()
				var pending: [(PlanEntry, ManagedRecordSet?)] = []
				for e in entries {
					guard let loc = e.location, let target = e.target else { continue }
					let before = absent ? nil : StoreEditor.managedRecords(in: store, key: loc.key)
					store = try StoreEditor.apply(target, to: loc.key, in: store, bases: globals.recordBases)
					pending.append((e, before))
				}
				// Whatever positions the store holds now (Finder may have added some since the plan), and exactly those recorded.
				var positions: [String: IconPositionsChange] = [:]
				for r in resetting + positionsOnly {
					let removed = StoreEditor.iconPositions(in: store)
					guard !removed.isEmpty else { continue }
					store = StoreEditor.replaceIconPositions(of: removed.map(\.name), with: [], in: store)
					positions[r.folder.path] = IconPositionsChange(storePath: storePath, before: removed, after: [])
				}
				// Nothing to write (the positions were gone by now): no backup either.
				guard !pending.isEmpty || !positions.isEmpty else { continue }
				op.backups.append(try operations.backup(store: storeURL, for: op))
				try StoreEditor.write(store, to: storeURL)
				let written = try DSStore.read(from: storeURL)
				for (e, before) in pending {
					let loc = e.location!
					changedIndex[e.folder.path] = op.entries.count
					op.entries.append(OperationEntry(folderPath: e.folder.path, storePath: storePath, key: loc.key,
					                                 before: before, after: StoreEditor.managedRecords(in: written, key: loc.key), status: .changed))
				}
				for (folder, change) in positions {
					if let i = changedIndex[folder] { op.entries[i].iconPositions = change }
				}
				for p in positionsOnly {
					guard let change = positions[p.folder.path], let loc = p.location else { continue }
					op.entries.append(OperationEntry(folderPath: p.folder.path, storePath: loc.storeURL.path, key: loc.key,
					                                 before: nil, after: nil, status: .positionsOnly, iconPositions: change))
				}
			} catch {
				for e in entries {
					op.entries.append(OperationEntry(folderPath: e.folder.path, storePath: storePath, key: e.location?.key ?? e.folder.lastPathComponent,
					                                 before: nil, after: nil, status: .failed, error: error.localizedDescription))
				}
				// A folder whose view records were written elsewhere keeps its change; only its positions stay as they were.
				for r in resetting {
					if let i = changedIndex[r.folder.path] { op.entries[i].iconPositionsError = error.localizedDescription }
				}
				for p in positionsOnly {
					op.entries.append(OperationEntry(folderPath: p.folder.path, storePath: p.location?.storeURL.path ?? storePath, key: p.location?.key ?? "",
					                                 before: nil, after: nil, status: .failed, error: error.localizedDescription))
				}
			}
			try operations.save(op)
		}
		for e in request.plan.entries where e.category == .alreadyMatching {
			op.entries.append(OperationEntry(folderPath: e.folder.path, storePath: e.location?.storeURL.path ?? "", key: e.location?.key ?? "", before: nil, after: nil, status: .skippedMatching))
		}
		op.finishedAt = Date()
		try operations.save(op)
		return op
	}

	/// The order an operation writes its stores in: shallower files first, so a folder's location store (its parent's)
	/// is written before its own `.DS_Store`, where its icon positions are changed only once its view records were.
	static func writeOrder(_ storePaths: Set<String>) -> [String] {
		storePaths.sorted { a, b in
			let (da, db) = (a.split(separator: "/").count, b.split(separator: "/").count)
			return da != db ? da < db : a < b
		}
	}

	/// Re-reads every changed folder and reports which ones no longer hold the written records
	/// (e.g. Finder overwrote the parent store from its cache). Only the view records count: Finder storing new icon
	/// positions after it laid a folder out again is expected. A parent store that is gone holds no records; one that
	/// cannot be read any more counts as not holding them either (the written values cannot be confirmed). Each parent
	/// store is read once, however many of the folders it holds ("지금 다시 시작" reads them while Finder is down).
	public func verify(_ op: FinderPresetsOperation) -> [OperationEntry] {
		var stores = StoreReads()
		return op.entries.filter { $0.status == .changed }.filter { e in
			guard let after = e.after else { return false }
			let now: ManagedRecordSet
			switch stores.read(URL(fileURLWithPath: e.storePath)) {
			case .failure: return true
			case .success(.absent): now = ManagedRecordSet()
			case .success(.present(let store)): now = StoreEditor.managedRecords(in: store, key: e.key, codes: op.managedCodes)
			}
			return ViewRecordCodec.decode(now) != ViewRecordCodec.decode(after)
		}
	}

	/// The `changed` folders of `op` whose parent store still holds what the operation wrote (`verify` reports none of
	/// them). Read just before Finder is quit: a folder that `verify` reports after the quit and that is in
	/// this set was overwritten by Finder's own write as it quit, while one whose file had changed before (Finder's write
	/// as a window closed, an undo, the user, another tool) is not in it and is left alone. Only the file is looked at: a
	/// view the user changed in a Finder window that Finder had not written to the file yet is still in this set, and
	/// Finder writing it as it quits looks the same as the quit overwriting the operation.
	public func holdingWritten(_ op: FinderPresetsOperation) -> Set<String> {
		let lost = Set(verify(op).map(\.folderPath))
		return Set(op.entries.filter { $0.status == .changed && $0.after != nil && !lost.contains($0.folderPath) }.map(\.folderPath))
	}

	/// Writes what `op` wrote back into the parent stores of `entries`: its `changed` entries whose records a quitting
	/// Finder overwrote from its cache (`verify` after the quit, among `holdingWritten` from before it). Per
	/// store, like `apply`: a backup of the store as Finder left it (a file of its own — the operation's first backup of
	/// that store stays), each entry's recorded `after` in place of the managed records there (`StoreEditor.restore` with
	/// the operation's codes; every other record stays as Finder wrote it), an atomic write, and `after` read back from
	/// the written file. A store left without any record is removed instead (an empty store means the same as none; an
	/// undo that removed a store the apply had created leaves it that way). `before` is never touched, so undoing `op`
	/// still puts back the state before the operation; the icon positions are not looked at.
	///
	/// The record is read again first, since the caller read it before Finder was quit and a quit can take seconds: a
	/// record that is gone (deleted from the history meanwhile) or cannot be read is not brought back — nothing is written
	/// and every folder fails with that error. The manifest is saved from a copy read again right before the save, with
	/// only the added backups and the new `after` values put in, so a pin or unpin made meanwhile stays. A record deleted
	/// while the stores were being written is not created again either: the backups this call made are removed and the
	/// manifest is not saved (the folders are written again all the same). Returns the updated operation and, by folder,
	/// why it was not written again (the folder keeps what Finder wrote; the caller words the error). Throws only when
	/// the manifest cannot be read again or saved after the stores were written (they may already be written). Only a
	/// pin or a delete in the instant between that last read and the save can still be lost or undone.
	public func writeAgain(_ entries: [OperationEntry], of recorded: FinderPresetsOperation) throws -> (operation: FinderPresetsOperation, failed: [String: any Error]) {
		var failed: [String: any Error] = [:]
		let targets = entries.filter { $0.status == .changed && $0.after != nil }
		var op: FinderPresetsOperation
		do { op = try operations.load(id: recorded.id) } catch {
			let reason: OperationStoreError = operations.hasManifest(id: recorded.id)
				? .unreadable(recorded.id, error.localizedDescription) : .notFound(recorded.id)
			for e in targets { failed[e.folderPath] = reason }
			return (recorded, failed)
		}
		let codes = op.managedCodes
		var added: [StoreBackup] = []
		var afters: [String: ManagedRecordSet] = [:]   // folder path → `after` read back from the store written again
		let byStore = Dictionary(grouping: targets, by: \.storePath)
		for storePath in Self.writeOrder(Set(byStore.keys)) {
			let url = URL(fileURLWithPath: storePath)
			let group = byStore[storePath] ?? []
			do {
				var store = try StoreEditor.read(url).store ?? DSStore()
				for e in group { store = StoreEditor.restore(e.after!, for: e.key, in: store, codes: codes) }
				let copies = (op.backups + added).filter { $0.storePath == storePath }.count
				added.append(try operations.backup(store: url, for: op, suffix: "-\(copies + 1)"))
				let written: DSStore
				if store.records.isEmpty {
					if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
					written = store
				} else {
					try StoreEditor.write(store, to: url)
					written = try DSStore.read(from: url)
				}
				for e in group { afters[e.folderPath] = StoreEditor.managedRecords(in: written, key: e.key, codes: codes) }
			} catch {
				for e in group { failed[e.folderPath] = error }
			}
		}
		guard !added.isEmpty || !afters.isEmpty else { return (op, failed) }
		guard operations.hasManifest(id: op.id) else {
			// Deleted meanwhile: the backups this call made go too, and the record stays deleted.
			operations.removeBackups(added, of: op.id)
			return (op, failed)
		}
		op = try operations.load(id: op.id)
		op.backups.append(contentsOf: added)
		for (folder, after) in afters {
			guard let i = op.entries.firstIndex(where: { $0.folderPath == folder && $0.status == .changed }) else { continue }
			op.entries[i].after = after
		}
		try operations.save(op)
		return (op, failed)
	}
}

import Foundation
import CryptoKit

/// App data directory: ~/Library/Application Support/FinderPresets (overridable for tests).
public struct AppDirectories: Sendable {
	public let root: URL
	public var presets: URL { root.appendingPathComponent("presets") }
	public var rules: URL { root.appendingPathComponent("rules.json") }
	public var operations: URL { root.appendingPathComponent("operations") }

	public init(root: URL) { self.root = root }

	public static var standard: AppDirectories {
		if let env = ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"], !env.isEmpty {
			return AppDirectories(root: URL(fileURLWithPath: env))
		}
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return AppDirectories(root: base.appendingPathComponent("FinderPresets"))
	}

	public func ensure() throws {
		for d in [root, presets, operations] {
			try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		}
	}
}

public enum PresetStoreError: Error, LocalizedError, Sendable {
	case unreadable(String)

	public var errorDescription: String? {
		switch self {
		case .unreadable(let detail): "프리셋 파일을 읽을 수 없습니다: \(detail)"
		}
	}
}

public struct PresetStore: Sendable {
	public let dirs: AppDirectories
	public init(dirs: AppDirectories) { self.dirs = dirs }

	private func url(for id: UUID) -> URL { dirs.presets.appendingPathComponent("\(id.uuidString).json") }

	/// Every preset; throws when any preset file cannot be read.
	public func list() throws -> [Preset] {
		let listing = try listReadable()
		if let first = listing.unreadable.first { throw PresetStoreError.unreadable(first) }
		return listing.presets
	}

	/// Every preset file that can be read, and "<file name>: <reason>" for each one that cannot (a hand-edited file,
	/// or one written by a newer version with values this version does not know). Unreadable files are left alone.
	public func listReadable() throws -> (presets: [Preset], unreadable: [String]) {
		try dirs.ensure()
		let files = (try? FileManager.default.contentsOfDirectory(at: dirs.presets, includingPropertiesForKeys: nil)) ?? []
		var presets: [Preset] = []
		var unreadable: [String] = []
		for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			do {
				presets.append(try JSONCoding.decoder().decode(Preset.self, from: Data(contentsOf: file)))
			} catch {
				unreadable.append("\(file.lastPathComponent): \(error.localizedDescription)")
			}
		}
		presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		return (presets, unreadable)
	}

	public func save(_ preset: Preset) throws {
		try dirs.ensure()
		var p = preset
		p.updatedAt = Date()
		try JSONCoding.encoder().encode(p).write(to: url(for: p.id), options: .atomic)
	}

	public func delete(id: UUID) throws {
		try FileManager.default.removeItem(at: url(for: id))
	}

	public func find(name: String) throws -> Preset? {
		try list().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
	}

	// Import / export as a portable JSON file.
	public func export(_ preset: Preset, to url: URL) throws {
		try JSONCoding.encoder().encode(preset).write(to: url, options: .atomic)
	}

	public func importPreset(from url: URL) throws -> Preset {
		var p = try JSONCoding.decoder().decode(Preset.self, from: Data(contentsOf: url))
		p.id = UUID()
		p.createdAt = Date()
		try save(p)
		return p
	}
}

/// rules.json (`finder-presets rule-set`). Keys this version does not know, such as `defaultPresetID` and a rule's `note` written by
/// earlier versions, are ignored when reading and dropped on the next save.
public struct RuleStore: Sendable {
	public struct Document: Codable, Equatable, Sendable {
		public var rules: [FolderRule]
		public init(rules: [FolderRule] = []) {
			self.rules = rules
		}
	}

	public let dirs: AppDirectories
	public init(dirs: AppDirectories) { self.dirs = dirs }

	public func load() throws -> Document {
		guard FileManager.default.fileExists(atPath: dirs.rules.path) else { return Document() }
		return try JSONCoding.decoder().decode(Document.self, from: Data(contentsOf: dirs.rules))
	}

	public func save(_ doc: Document) throws {
		try dirs.ensure()
		try JSONCoding.encoder().encode(doc).write(to: dirs.rules, options: .atomic)
	}
}

/// How many recorded operations (and their backups) to keep. `OperationStore.retentionPlan(policy:now:)` has the rules.
public struct RetentionPolicy: Sendable, Equatable {
	public var maxCount: Int
	public var maxAge: TimeInterval
	public var maxBytes: Int64
	public init(maxCount: Int = 50, maxAge: TimeInterval = 30 * 86400, maxBytes: Int64 = 200 * 1024 * 1024) {
		self.maxCount = maxCount
		self.maxAge = maxAge
		self.maxBytes = maxBytes
	}

	/// The app's policy: the newest 50 operations, 30 days, 200 MB.
	public static let standard = RetentionPolicy()
}

public enum OperationStoreError: Error, LocalizedError, Sendable, Equatable {
	case notFound(UUID)
	/// The operation is still being written (`FinderPresetsOperation.isInProgress`); its manifest is left alone.
	case inProgress(UUID)
	case unreadable(UUID, String)

	public var errorDescription: String? {
		switch self {
		case .notFound(let id): "작업 기록이 없습니다: \(id.uuidString)"
		case .inProgress(let id): "아직 진행 중인 작업이라 바꾸지 않았습니다: \(id.uuidString)"
		case .unreadable(let id, let detail): "작업 기록을 읽을 수 없습니다 (\(id.uuidString)): \(detail)"
		}
	}
}

/// operations/<id>/manifest.json + backups/*.DS_Store
public struct OperationStore: Sendable {
	public let dirs: AppDirectories
	public init(dirs: AppDirectories) { self.dirs = dirs }

	public static let manifestFileName = "manifest.json"

	public func directory(for id: UUID) -> URL { dirs.operations.appendingPathComponent(id.uuidString) }

	private func manifestURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent(Self.manifestFileName) }

	public func save(_ op: FinderPresetsOperation) throws {
		let dir = directory(for: op.id)
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("backups"), withIntermediateDirectories: true)
		try JSONCoding.encoder().encode(op).write(to: dir.appendingPathComponent(Self.manifestFileName), options: .atomic)
	}

	public func load(id: UUID) throws -> FinderPresetsOperation {
		try JSONCoding.decoder().decode(FinderPresetsOperation.self, from: Data(contentsOf: manifestURL(for: id)))
	}

	/// Whether the operation's manifest file exists (readable or not): false once the record was deleted.
	public func hasManifest(id: UUID) -> Bool { FileManager.default.fileExists(atPath: manifestURL(for: id).path) }

	/// Removes backup files `backup` made for operation `id` whose record was deleted meanwhile (`Applier.writeAgain`),
	/// then the `backups` folder and the operation's folder if that leaves them empty. Best effort: nothing else there
	/// is touched.
	public func removeBackups(_ backups: [StoreBackup], of id: UUID) {
		let dir = directory(for: id)
		for file in backups.compactMap(\.backupFile) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
		for folder in [dir.appendingPathComponent("backups"), dir] {
			guard let left = try? FileManager.default.contentsOfDirectory(atPath: folder.path), left.isEmpty else { return }
			try? FileManager.default.removeItem(at: folder)
		}
	}

	/// Every readable operation, newest first. Directories whose manifest cannot be read are left out (see `listReadable`).
	public func list() throws -> [FinderPresetsOperation] {
		try listReadable().operations
	}

	/// Every operation whose manifest can be read (newest first), and "<directory name>: <reason>" for each operation
	/// directory (named by a UUID) whose manifest cannot — written by a newer version, edited by hand, or cut short.
	/// Nothing is changed; retention never removes an unreadable one.
	public func listReadable() throws -> (operations: [FinderPresetsOperation], unreadable: [String]) {
		try dirs.ensure()
		let entries = (try? FileManager.default.contentsOfDirectory(at: dirs.operations, includingPropertiesForKeys: nil)) ?? []
		var operations: [FinderPresetsOperation] = []
		var unreadable: [String] = []
		for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
			do {
				operations.append(try load(id: id))
			} catch {
				unreadable.append("\(url.lastPathComponent): \(error.localizedDescription)")
			}
		}
		return (operations.sorted(by: Self.newestFirst), unreadable)
	}

	/// Newest first; operations that started at the same moment are ordered by ID so every listing agrees.
	static func newestFirst(_ a: FinderPresetsOperation, _ b: FinderPresetsOperation) -> Bool {
		a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id.uuidString > b.id.uuidString
	}

	/// Pins or unpins an operation: retention never removes a pinned one (`retentionPlan`). Only the manifest's
	/// `pinned` key is rewritten; every other key, including ones a newer version may have added, is kept as stored.
	/// Returns the operation as saved. Throws `notFound` when there is no such operation and `inProgress` when it is
	/// still being written (its writer saves the manifest again and would undo the change, or lose its own).
	@discardableResult
	public func setPinned(id: UUID, pinned: Bool, now: Date = Date()) throws -> FinderPresetsOperation {
		let url = manifestURL(for: id)
		guard FileManager.default.fileExists(atPath: url.path) else { throw OperationStoreError.notFound(id) }
		let data = try Data(contentsOf: url)
		let op: FinderPresetsOperation
		do { op = try JSONCoding.decoder().decode(FinderPresetsOperation.self, from: data) } catch {
			throw OperationStoreError.unreadable(id, error.localizedDescription)
		}
		guard op.pinned != pinned else { return op }
		guard !op.isInProgress(now: now) else { throw OperationStoreError.inProgress(id) }
		guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw OperationStoreError.unreadable(id, "manifest is not a JSON object")
		}
		object["pinned"] = pinned
		let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
		// Never write something this version cannot read back as the same operation with the new flag.
		var expected = op
		expected.pinned = pinned
		guard let check = try? JSONCoding.decoder().decode(FinderPresetsOperation.self, from: updated), check == expected else {
			throw OperationStoreError.unreadable(id, "manifest does not round-trip")
		}
		try updated.write(to: url, options: .atomic)
		return check
	}

	/// Copies a parent .DS_Store into the operation directory; returns the backup descriptor. `suffix` names a later copy
	/// of a store the operation already backed up (`Applier.writeAgain`), so the first copy is never replaced.
	public func backup(store url: URL, for op: FinderPresetsOperation, suffix: String = "") throws -> StoreBackup {
		let dir = directory(for: op.id).appendingPathComponent("backups")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		guard FileManager.default.fileExists(atPath: url.path) else {
			return StoreBackup(storePath: url.path, backupFile: nil, sha256: nil)
		}
		let name = "\(Self.shortHash(url.path))\(suffix).DS_Store"
		let dest = dir.appendingPathComponent(name)
		if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
		try FileManager.default.copyItem(at: url, to: dest)
		let original = try Data(contentsOf: url)
		let copy = try Data(contentsOf: dest)
		guard original == copy else { throw StoreEditorError.backupMismatch(url.path) }
		return StoreBackup(storePath: url.path, backupFile: "backups/\(name)", sha256: Self.sha256Hex(copy))
	}

	// MARK: Global-defaults operations (operations/<id>/global-before.json)

	public static let globalSnapshotFileName = "global-before.json"

	/// Writes the domain's pre-write values next to the manifest. Returns the file name to store in
	/// `FinderPresetsOperation.globalSnapshotFile`. Overwrites an earlier snapshot of the same operation.
	public func saveGlobalSnapshot(_ snapshot: GlobalSnapshot, for op: FinderPresetsOperation) throws -> String {
		let dir = directory(for: op.id)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try JSONCoding.encoder().encode(snapshot).write(to: dir.appendingPathComponent(Self.globalSnapshotFileName), options: .atomic)
		return Self.globalSnapshotFileName
	}

	public func loadGlobalSnapshot(_ file: String, for op: FinderPresetsOperation) throws -> GlobalSnapshot {
		try JSONCoding.decoder().decode(GlobalSnapshot.self, from: Data(contentsOf: directory(for: op.id).appendingPathComponent(file)))
	}

	public func delete(id: UUID) throws {
		try FileManager.default.removeItem(at: directory(for: id))
	}

	func directorySize(_ url: URL) -> Int64 {
		guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
		var total: Int64 = 0
		for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
		return total
	}

	static func shortHash(_ s: String) -> String { String(sha256Hex(Data(s.utf8)).prefix(16)) }

	static func sha256Hex(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

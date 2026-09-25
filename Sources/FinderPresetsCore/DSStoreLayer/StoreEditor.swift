import Foundation
import DSStore

/// The associated values are technical details (a path, a system or library error); the words are in `errorDescription`
/// (Korean, for `finder-presets`) and in the app's `ErrorText`.
public enum StoreEditorError: Error, LocalizedError, Sendable {
	case unreadable(String)
	case verificationFailed(String)
	case writeFailed(String)
	/// The backup copy of a parent `.DS_Store` (the path) is not byte for byte the original: nothing was written.
	case backupMismatch(String)

	public var errorDescription: String? {
		switch self {
		case .unreadable(let m): "설정 파일을 읽을 수 없습니다: \(m)"
		case .verificationFailed(let m): "쓴 파일 재검증 실패: \(m)"
		case .writeFailed(let m): "설정 파일 쓰기 실패: \(m)"
		case .backupMismatch(let path): "백업 검증 실패: \(path)"
		}
	}
}

/// Base plists used when a folder has no icon/list record yet (normally taken from Finder's global defaults).
public struct RecordBases: @unchecked Sendable {
	public var icon: [String: Any]
	public var listArray: [String: Any]   // for lsvC / lsvP
	public var listDict: [String: Any]    // for lsvp

	public init(icon: [String: Any] = ViewRecordCodec.factoryIconPlist,
	            listArray: [String: Any] = ViewRecordCodec.factoryListPlist,
	            listDict: [String: Any]? = nil) {
		self.icon = icon
		self.listArray = listArray
		self.listDict = listDict ?? ViewRecordCodec.dictForm(ofList: listArray)
	}
}

/// Reads and rewrites a parent `.DS_Store`, touching only the managed records of the requested child.
public enum StoreEditor {
	public enum ReadResult: Sendable {
		case absent
		case present(DSStore)
	}

	public static func read(_ url: URL) throws -> ReadResult {
		guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
		do {
			return .present(try DSStore.read(from: url))
		} catch {
			throw StoreEditorError.unreadable("\(error)")
		}
	}

	/// Managed records for `key`. Swift string equality is Unicode-canonical, so NFC and NFD spellings of the
	/// same name (Finder's vs. another tool's) are both found; when both exist, the on-disk spelling wins.
	/// `codes`: the record codes to read — every managed one, or what an older operation recorded (`FinderPresetsOperation.recordCodes`).
	public static func managedRecords(in store: DSStore, key: String, codes: [String] = ManagedRecordSet.managedCodes) -> ManagedRecordSet {
		ManagedRecordSet(records: managedStoreRecords(in: store, key: key, codes: codes).map(RawRecord.init(record:)))
	}

	/// The stored managed records of `key`, one per record type (the on-disk spelling first, as in `managedRecords`).
	static func managedStoreRecords(in store: DSStore, key: String, codes: [String] = ManagedRecordSet.managedCodes) -> [DSStore.Record] {
		let all = store.records(for: key).filter { codes.contains($0.type.fourCC.description) }
		let exact = all.filter { $0.filename.unicodeScalars.elementsEqual(key.unicodeScalars) }
		var chosen: [DSStore.Record] = exact
		for r in all where !chosen.contains(where: { $0.type == r.type }) { chosen.append(r) }
		return chosen
	}

	public static func managedRecords(at url: URL, key: String, codes: [String] = ManagedRecordSet.managedCodes) throws -> ManagedRecordSet? {
		try read(url).store.map { managedRecords(in: $0, key: key, codes: codes) }
	}

	/// Applies `settings` to child `key`, preserving every other record and every unknown plist key.
	/// A preset changes only the options it contains: a record group the settings do not mention is kept exactly as
	/// stored — `vstl` without a view style, `icvp` without icon options, `lsvC`/`lsvp`/`lsvP` without list options,
	/// `GRP0` without a grouping.
	public static func apply(_ settings: ViewSettings, to key: String, in store: DSStore, bases: RecordBases) throws -> DSStore {
		var s = store
		let stored = managedStoreRecords(in: store, key: key)
		let current = ManagedRecordSet(records: stored.map(RawRecord.init(record:)))
		// Removal matches canonically-equal filenames, so any other spelling of this key is unified under `key`
		// (records that are kept are written back under `key` too).
		for code in ManagedRecordSet.managedCodes {
			s.remove(filename: key, type: DSStore.RecordType(fourCC: DSStore.FourCC(code)!))
		}
		func set(_ code: String, _ value: DSStore.Value) {
			s.add(DSStore.Record(filename: key, type: DSStore.RecordType(fourCC: DSStore.FourCC(code)!), value: value))
		}
		func keep(_ code: String) {
			guard let r = stored.first(where: { $0.type.fourCC.description == code }) else { return }
			s.add(DSStore.Record(filename: key, type: r.type, value: r.value))
		}
		set("vSrn", .uint32(1))
		if let style = settings.viewStyle {
			set("vstl", .fourCC(DSStore.FourCC(style.rawValue)!))
		} else {
			keep("vstl")
		}
		// The grouping: a `ustr` with Finder's own string, the bytes Finder writes.
		if let group = settings.groupBy {
			set("GRP0", .string(group.rawValue))
		} else {
			keep("GRP0")
		}
		if !settings.icon.isEmpty {
			let existing = current["icvp"]?.dataValue.flatMap(ViewRecordCodec.plist(from:))
			let merged = ViewRecordCodec.mergeIcon(settings.icon, into: existing, base: bases.icon)
			set("icvp", .data(try ViewRecordCodec.data(from: merged)))
		} else {
			keep("icvp")
		}
		if settings.list.isEmpty {
			for code in ["lsvC", "lsvp", "lsvP"] { keep(code) }
		} else {
			// lsvC (array columns) is what Finder 26 reads first; keep lsvp (dict columns) in sync like Finder does.
			let existingC = current["lsvC"]?.dataValue.flatMap(ViewRecordCodec.plist(from:))
				?? current["lsvP"]?.dataValue.flatMap(ViewRecordCodec.plist(from:))
			let mergedC = ViewRecordCodec.mergeList(settings.list, into: existingC, base: bases.listArray)
			set("lsvC", .data(try ViewRecordCodec.data(from: mergedC)))
			let existingP = current["lsvp"]?.dataValue.flatMap(ViewRecordCodec.plist(from:))
			var mergedP = ViewRecordCodec.mergeList(settings.list, into: existingP, base: bases.listDict)
			if let cols = mergedC["columns"] as? [[String: Any]] { mergedP["columns"] = ViewRecordCodec.dictColumns(fromArray: cols) }
			set("lsvp", .data(try ViewRecordCodec.data(from: mergedP)))
			if current["lsvP"] != nil {
				set("lsvP", .data(try ViewRecordCodec.data(from: mergedC)))
			}
		}
		return s
	}

	/// Replaces the managed records of `key` with exactly `set` (used by Undo). Empty set removes them all. `codes`: the
	/// record codes the operation recorded (`FinderPresetsOperation.recordCodes`); a record of another code is left as it is.
	public static func restore(_ set: ManagedRecordSet, for key: String, in store: DSStore, codes: [String] = ManagedRecordSet.managedCodes) -> DSStore {
		var s = store
		for code in codes {
			s.remove(filename: key, type: DSStore.RecordType(fourCC: DSStore.FourCC(code)!))
		}
		for raw in set.records {
			if let r = raw.toRecord(filename: key) { s.add(r) }
		}
		return s
	}

	// MARK: Icon positions (`Iloc`)
	// A folder's own `.DS_Store` holds one `Iloc` per item Finder has placed, keyed by the item's name. Only records of
	// that type are read or changed here; every other record (view records of the folder or its children) stays.

	/// Every icon position stored in `store`, in stored order.
	public static func iconPositions(in store: DSStore) -> [NamedRecord] {
		store.records.filter { $0.type == .iconLocation }.map { NamedRecord(name: $0.filename, record: RawRecord(record: $0)) }
	}

	/// The icon positions stored for `names`.
	public static func iconPositions(in store: DSStore, names: [String]) -> [NamedRecord] {
		iconPositions(in: store).filter { names.contains($0.name) }
	}

	/// True when `store` holds at least one icon position.
	static func hasIconPositions(in store: DSStore) -> Bool {
		store.records.contains { $0.type == .iconLocation }
	}

	/// Removes every icon position of `names` and stores `positions` instead (an empty list removes them).
	public static func replaceIconPositions(of names: [String], with positions: [NamedRecord], in store: DSStore) -> DSStore {
		var s = store
		for name in names { s.remove(filename: name, type: .iconLocation) }
		for p in positions {
			if let r = p.record.toRecord(filename: p.name) { s.add(r) }
		}
		return s
	}

	/// Writes atomically: temp file in the same directory → re-parse → rename over the original.
	public static func write(_ store: DSStore, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		let tmp = dir.appendingPathComponent(".DS_Store.finder-presets-\(UUID().uuidString.prefix(8)).tmp")
		do {
			try store.write(to: tmp)
		} catch {
			throw StoreEditorError.writeFailed("\(error)")
		}
		defer { try? FileManager.default.removeItem(at: tmp) }
		// verify
		let back: DSStore
		do { back = try DSStore.read(from: tmp) } catch { throw StoreEditorError.verificationFailed("\(error)") }
		let expected = Set(store.records.map { "\($0.filename)/\($0.type.fourCC)" })
		let actual = Set(back.records.map { "\($0.filename)/\($0.type.fourCC)" })
		guard expected == actual else {
			throw StoreEditorError.verificationFailed("record set mismatch: \(expected.symmetricDifference(actual))")
		}
		if rename(tmp.path, url.path) != 0 {
			throw StoreEditorError.writeFailed(String(cString: strerror(errno)))
		}
	}
}

extension StoreEditor.ReadResult {
	/// The store that was read; nil when there is no file (a write creates it).
	var store: DSStore? {
		if case .present(let store) = self { store } else { nil }
	}
}

/// `.DS_Store` files read once each, for code that looks at many folders one file holds (`Planner.plan`,
/// `UndoService.preview`, `Applier.verify`): a file that cannot be read fails the same way for each of them.
struct StoreReads {
	private var results: [String: Result<StoreEditor.ReadResult, any Error>] = [:]
	private let reader: (URL) throws -> StoreEditor.ReadResult

	/// `reader`: how a file is read (`StoreEditor.read`; tests count the reads).
	init(reader: @escaping (URL) throws -> StoreEditor.ReadResult = StoreEditor.read) {
		self.reader = reader
	}

	mutating func read(_ url: URL) -> Result<StoreEditor.ReadResult, any Error> {
		if let known = results[url.path] { return known }
		let result = Result { try reader(url) }
		results[url.path] = result
		return result
	}

	/// Forgets the files that are not in `folder` or in a folder above it: a depth-first scan (`FolderScanner`) never
	/// asks for them again, so planning a whole home folder keeps one branch in memory, not every file it read.
	mutating func keepBranch(of folder: String) {
		results = results.filter { Self.isOnBranch(($0.key as NSString).deletingLastPathComponent, of: folder) }
	}

	/// `folder` itself or a folder above it.
	static func isOnBranch(_ path: String, of folder: String) -> Bool {
		path == folder || TargetBatch.isInside(folder, path)
	}
}

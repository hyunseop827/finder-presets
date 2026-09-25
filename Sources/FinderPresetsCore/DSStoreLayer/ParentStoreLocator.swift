import Foundation

/// Where Finder 26 keeps a folder's view settings: the parent directory's `.DS_Store`, keyed by the folder's own name —
/// except for the home folder, whose parent (`/Users`) no one but root can write: Finder keeps its settings in the home
/// folder's own `.DS_Store`, under the key `"."`.
public struct StoreLocation: Equatable, Sendable, Hashable {
	public let folder: URL
	public let storeURL: URL      // parent/.DS_Store (the folder's own for `selfKey`)
	public let key: String        // folder name exactly as stored on disk (Finder keys records by these bytes), or `selfKey`

	/// The key of a folder's own record in its own `.DS_Store`.
	public static let selfKey = "."
}

public enum LocatorError: Error, Equatable, Sendable, LocalizedError {
	case rootFolder
	case volumeRoot
	case parentNotWritable(String)

	public var errorDescription: String? {
		switch self {
		case .rootFolder: "루트 디렉터리에는 적용할 수 없습니다."
		case .volumeRoot: "볼륨 루트는 v1에서 지원하지 않습니다."
		case .parentNotWritable(let p): "상위 폴더에 쓸 수 없습니다: \(p)"
		}
	}
}

public enum ParentStoreLocator {
	/// What `locate` learns about a parent folder: whether it can be written and, when it can, the names in it by their
	/// canonical spelling (nil: they could not be listed).
	struct Parent {
		var writable: Bool
		var names: [String: String]?
	}

	public static func locate(_ folder: URL, fileManager: FileManager = .default) throws -> StoreLocation {
		var parents: [String: Parent] = [:]
		return try locate(folder, fileManager: fileManager, parents: &parents)
	}

	/// `locate` for many folders (`Planner.plan`): each parent folder is checked and listed once, in `parents`.
	///
	/// Finder keys a child's records by the name as the file system reports it (e.g. NFC for folders made with `mkdir`),
	/// while Foundation's URL machinery may hand back a decomposed (NFD) spelling. Swift's `String ==` (and its hashing)
	/// treats both as equal, so the key is the on-disk spelling, looked up in the parent's listing (the first one listed).
	static func locate(_ folder: URL, fileManager: FileManager = .default, parents: inout [String: Parent]) throws -> StoreLocation {
		let url = folder.standardizedFileURL
		let path = url.path
		if path == "/" { throw LocatorError.rootFolder }
		let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
		if path == home.path { return StoreLocation(folder: url, storeURL: home.appendingPathComponent(".DS_Store"), key: StoreLocation.selfKey) }
		if path.hasPrefix("/Volumes/") && url.pathComponents.count == 3 { throw LocatorError.volumeRoot }
		let parent = url.deletingLastPathComponent()
		let known = parents[parent.path] ?? {
			guard fileManager.isWritableFile(atPath: parent.path) else { return Parent(writable: false) }
			let listing = try? fileManager.contentsOfDirectory(atPath: parent.path)
			return Parent(writable: true, names: listing.map { Dictionary($0.map { ($0, $0) }, uniquingKeysWith: { first, _ in first }) })
		}()
		parents[parent.path] = known
		guard known.writable else {
			throw LocatorError.parentNotWritable(parent.path)
		}
		let wanted = url.lastPathComponent
		return StoreLocation(folder: url, storeURL: parent.appendingPathComponent(".DS_Store"), key: known.names?[wanted] ?? wanted)
	}
}

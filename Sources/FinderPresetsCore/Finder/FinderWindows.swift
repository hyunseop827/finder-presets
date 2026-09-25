import Foundation

/// Finder's windows around a restart this app makes. Finder does not open its windows again after it was
/// quit with an Apple Event, so every path that quits Finder — the system-wide apply, a Finder default undo, the quick
/// preset, "지금 다시 시작", `finder-presets apply --relaunch` and `relaunch-finder` — reads the folders its windows show
/// before the quit (`remember`) and, once Finder is back, opens them again (`reopen(in:before:)`) before the operation's
/// own folders, which are opened last so they end up in front. Nothing is opened when Finder did not quit or did not
/// come back.
public struct FinderWindows: Equatable, Sendable {
	/// At most this many windows are opened again, the frontmost first: a screen flooded with windows is worse than a few
	/// that stay closed.
	public static let limit = 12

	/// The folders of Finder's windows before the quit, front to back (windows that show no folder are not in it).
	public var folders: [URL]

	public init(folders: [URL] = []) { self.folders = folders }

	/// Reads them (`FinderLifecycle.openWindowFolders`): right before the quit.
	public static func remember(_ finder: any FinderLifecycle) -> FinderWindows {
		FinderWindows(folders: finder.openWindowFolders())
	}

	/// What to open again, in the order to open it: each folder once (spelled otherwise — a trailing slash, another case,
	/// a symbolic link — it is still the same folder), without those that are no longer folders and without
	/// `operationFolders` (the operation opens them itself, after these), at most `limit` of the frontmost; back to front,
	/// so the frontmost is opened last and ends up in front of the others.
	public func toReopen(excluding operationFolders: [URL] = [], limit: Int = limit,
	                     isFolder: (URL) -> Bool = FinderWindows.isFolder) -> [URL] {
		var seen = Set(operationFolders.map(Self.key))
		var kept: [URL] = []
		for folder in folders where kept.count < limit {
			guard seen.insert(Self.key(folder)).inserted, isFolder(folder) else { continue }
			kept.append(URL(fileURLWithPath: FolderRule.normalize(folder.path)))
		}
		return kept.reversed()
	}

	/// After the launch, only once Finder is back: opens `toReopen(excluding: operationFolders)` with
	/// `FinderLifecycle.reopen` (not called when there is nothing to open). Returns what it opened.
	@discardableResult
	public func reopen(in finder: any FinderLifecycle, before operationFolders: [URL] = [],
	                   isFolder: (URL) -> Bool = FinderWindows.isFolder) -> [URL] {
		let folders = toReopen(excluding: operationFolders, isFolder: isFolder)
		return folders.isEmpty ? [] : finder.reopen(folders)
	}

	/// A folder that still exists.
	public static func isFolder(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

	/// The same folder, however it was spelled.
	static func key(_ url: URL) -> String {
		FolderRule.normalize(URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path).lowercased()
	}
}

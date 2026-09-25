import Foundation

/// The user's standard home folders, used by the UI as the targets of "apply to the standard home folders".
/// Never includes `~/Library` or anything that lives in iCloud, and never the home folder itself.
public enum HomeFolders {
	public static let standardNames = ["Documents", "Downloads", "Pictures", "Music", "Movies"]
	public static let desktopName = "Desktop"

	/// The standard folders that exist as real directories directly under `home`, in the fixed order above
	/// (Desktop last when `includeDesktop`). Symbolic links are skipped: the scanner would skip them too.
	public static func standardFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser, includeDesktop: Bool) -> [URL] {
		var names = standardNames
		if includeDesktop { names.append(desktopName) }
		let homePath = home.standardizedFileURL.path
		return names.compactMap { name in
			let url = home.appendingPathComponent(name, isDirectory: true)
			let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
			guard !isForbidden(url.path, home: homePath), !isForbidden(url.resolvingSymlinksInPath().path, home: homePath) else { return nil }
			return url
		}
	}

	/// True for the home folder itself and every folder above it (`/`, `/Users`). As an apply root such a folder would
	/// reach every folder in the home folder, the Desktop included (only the root itself is unsupported), so the app
	/// and `finder-presets` never take one as a target. Compared case-insensitively, like the default APFS volume.
	public static func isHomeOrAncestor(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
		let p = FolderRule.normalize(path).lowercased()
		let h = FolderRule.normalize(home.path).lowercased()
		return p == h || TargetBatch.isInside(h, p)
	}

	/// True for the home folder itself, compared like `isHomeOrAncestor`.
	public static func isHome(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
		FolderRule.normalize(path).lowercased() == FolderRule.normalize(home.path).lowercased()
	}

	/// True for the user's Desktop folder (`home/Desktop`) itself. Its item positions are the user's desktop layout: the
	/// app never removes them (`Planner.resetsIconPositions`). Compared like `isHomeOrAncestor`.
	public static func isDesktop(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
		FolderRule.normalize(folder.path).lowercased() == FolderRule.normalize(home.appendingPathComponent(desktopName).path).lowercased()
	}

	/// Library and iCloud locations are never targets, whatever they are called.
	static func isForbidden(_ path: String, home: String) -> Bool {
		let library = home + "/Library"
		return path == library || path.hasPrefix(library + "/") || path.hasSuffix("/Library")
			|| path.contains("/Mobile Documents/") || path.contains("/CloudStorage/")
	}
}

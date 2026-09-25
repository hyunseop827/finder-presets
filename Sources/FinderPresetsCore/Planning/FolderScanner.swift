import Foundation

public struct ScanOptions: Sendable, Equatable {
	public var maxDepth: Int?               // nil = unlimited; 0 = root only
	public var excludedPaths: [String]

	public init(maxDepth: Int? = nil, excludedPaths: [String] = []) {
		self.maxDepth = maxDepth
		self.excludedPaths = excludedPaths.map(FolderRule.normalize)
	}

	/// Locations that are always skipped, with everything inside them, even when a target folder is one of them
	/// or lies inside them.
	public static func defaultExclusions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
		let h = home.standardizedFileURL.path
		return [
			"\(h)/Library",
			"\(h)/Library/Mobile Documents",
			"\(h)/Library/CloudStorage",
			"\(h)/.Trash",
			"/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications", "/Volumes"
		]
	}
}

public enum SkipReason: String, Codable, Sendable, Equatable {
	case excludedPath
	case hidden
	case package
	case symlink
	case timeMachine
	case permissionDenied
	case cycle
}

public struct ScannedFolder: Sendable, Equatable, Hashable {
	public let url: URL
	public let depth: Int
	public let skipReason: SkipReason?     // nil = candidate for planning

	public init(url: URL, depth: Int, skipReason: SkipReason? = nil) {
		self.url = url
		self.depth = depth
		self.skipReason = skipReason
	}
}

/// Recursive folder enumeration with the safety rules from the plan (no symlink following, no packages, cycle guard).
public struct FolderScanner: @unchecked Sendable {
	public let options: ScanOptions
	private let fileManager: FileManager

	public init(options: ScanOptions, fileManager: FileManager = .default) {
		self.options = options
		self.fileManager = fileManager
	}

	public func scan(roots: [URL]) -> [ScannedFolder] {
		var out: [ScannedFolder] = []
		var visited = Set<String>()   // "dev:inode"
		for root in roots {
			walk(root.standardizedFileURL, depth: 0, visited: &visited, into: &out)
		}
		return out
	}

	private func identity(_ url: URL) -> String? {
		guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
		      let dev = attrs[.systemNumber] as? NSNumber,
		      let ino = attrs[.systemFileNumber] as? NSNumber else { return nil }
		return "\(dev):\(ino)"
	}

	private func walk(_ url: URL, depth: Int, visited: inout Set<String>, into out: inout [ScannedFolder]) {
		let path = url.path
		// Compared in the same spelling as the exclusions (`FolderRule.normalize`: /private/var/… is /var/…).
		let normalized = FolderRule.normalize(path)
		if options.excludedPaths.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) {
			out.append(ScannedFolder(url: url, depth: depth, skipReason: .excludedPath)); return
		}
		let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .isDirectoryKey])
		if values?.isSymbolicLink == true {
			out.append(ScannedFolder(url: url, depth: depth, skipReason: .symlink)); return
		}
		if depth > 0 {
			if values?.isHidden == true {
				out.append(ScannedFolder(url: url, depth: depth, skipReason: .hidden)); return
			}
			if values?.isPackage == true {
				out.append(ScannedFolder(url: url, depth: depth, skipReason: .package)); return
			}
		}
		if fileManager.fileExists(atPath: url.appendingPathComponent(".com.apple.TimeMachine.supported").path) ||
		   path.contains("/Backups.backupdb/") {
			out.append(ScannedFolder(url: url, depth: depth, skipReason: .timeMachine)); return
		}
		if let id = identity(url) {
			if visited.contains(id) { out.append(ScannedFolder(url: url, depth: depth, skipReason: .cycle)); return }
			visited.insert(id)
		}
		let children: [URL]
		do {
			children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey], options: [])
		} catch {
			out.append(ScannedFolder(url: url, depth: depth, skipReason: .permissionDenied)); return
		}
		out.append(ScannedFolder(url: url, depth: depth, skipReason: nil))
		if let max = options.maxDepth, depth >= max { return }
		for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
			let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			if v?.isSymbolicLink == true {
				// only report symlinks that point at directories
				if let target = try? fileManager.destinationOfSymbolicLink(atPath: child.path) {
					let t = URL(fileURLWithPath: target, relativeTo: url).standardizedFileURL
					var isDir: ObjCBool = false
					if fileManager.fileExists(atPath: t.path, isDirectory: &isDir), isDir.boolValue {
						walk(child, depth: depth + 1, visited: &visited, into: &out)
					}
				}
				continue
			}
			guard v?.isDirectory == true else { continue }
			walk(child, depth: depth + 1, visited: &visited, into: &out)
		}
	}
}

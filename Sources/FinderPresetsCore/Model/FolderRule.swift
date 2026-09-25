import Foundation

/// A path-based rule: "this folder (and optionally its subfolders) uses preset X".
public struct FolderRule: Codable, Identifiable, Equatable, Sendable, Hashable {
	public var id: UUID
	public var path: String                 // standardized absolute path
	public var presetID: UUID
	public var appliesToSubfolders: Bool

	public init(id: UUID = UUID(), path: String, presetID: UUID, appliesToSubfolders: Bool = true) {
		self.id = id
		self.path = FolderRule.normalize(path)
		self.presetID = presetID
		self.appliesToSubfolders = appliesToSubfolders
	}

	public static func normalize(_ path: String) -> String {
		let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
		var p = url.path
		while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
		return p
	}
}

/// Resolves which preset applies to a folder.
/// Priority: exact rule for the folder > nearest ancestor rule with `appliesToSubfolders` > default preset.
public struct RuleResolver: Sendable {
	public enum Source: Equatable, Sendable, Hashable {
		case exactRule(UUID)
		case inheritedRule(UUID, fromPath: String)
		case defaultPreset
		case none
	}

	public struct Resolution: Equatable, Sendable, Hashable {
		public let presetID: UUID?
		public let source: Source
	}

	public let rules: [FolderRule]
	public let defaultPresetID: UUID?

	public init(rules: [FolderRule], defaultPresetID: UUID?) {
		self.rules = rules
		self.defaultPresetID = defaultPresetID
	}

	public func resolve(path: String) -> Resolution {
		let p = FolderRule.normalize(path)
		if let exact = rules.first(where: { $0.path == p }) {
			return Resolution(presetID: exact.presetID, source: .exactRule(exact.id))
		}
		// nearest ancestor: longest matching prefix
		let ancestor = rules
			.filter { $0.appliesToSubfolders && TargetBatch.isInside(p, $0.path) }
			.max { $0.path.count < $1.path.count }
		if let ancestor {
			return Resolution(presetID: ancestor.presetID, source: .inheritedRule(ancestor.id, fromPath: ancestor.path))
		}
		if let defaultPresetID {
			return Resolution(presetID: defaultPresetID, source: .defaultPreset)
		}
		return Resolution(presetID: nil, source: .none)
	}
}

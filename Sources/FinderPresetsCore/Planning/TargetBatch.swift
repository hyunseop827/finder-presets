import Foundation

/// One folder of the app's "적용할 폴더" list and the preset assigned to it (`nil` = the preset selected in the app).
/// Encodes as `{"path": …, "presetID": …}`; `presetID` is omitted when nil, and a missing field decodes as nil,
/// so a list written before assignments existed (`[{"path": …}]`) still loads.
public struct TargetAssignment: Codable, Sendable, Equatable, Hashable {
	public var path: String
	public var presetID: UUID?

	public init(path: String, presetID: UUID? = nil) {
		self.path = FolderRule.normalize(path)
		self.presetID = presetID
	}
}

/// "선택한 폴더에 적용" / "전체 폴더에 적용" for target folders that may each carry their own preset and may be nested.
///
/// - Every target with an assigned preset becomes a `FolderRule` (inherited by its subfolders when `includeSubfolders`),
///   and the preset selected in the app is the default: exact assignment > nearest assigned ancestor target > selected preset.
///   A nested target without an assignment therefore follows the nearest assigned target around it.
/// - A requested root that resolves to no preset (nothing selected, nothing assigned or inherited), or to a preset that
///   no longer exists, is skipped and reported — never scanned or written.
/// - With subfolders, a root inside another applied root is not scanned a second time (the outer scan reaches it and its
///   rule still applies), so no folder is counted twice or reported as a cycle. A nested root that the outer scan does not
///   reach as a candidate (e.g. a hidden folder, or one inside a package, that the user added on purpose) is scanned on its own.
public struct TargetBatch: Sendable {
	public enum SkipReason: Equatable, Sendable {
		case noPreset                 // no assignment, nothing inherited, no preset selected
		case missingPreset(UUID)      // assigned (or inherited) preset no longer exists
	}

	public struct SkippedRoot: Equatable, Sendable {
		public let path: String
		public let reason: SkipReason
	}

	public let presets: [Preset]
	public let targets: [TargetAssignment]
	public let selectedPresetID: UUID?
	public let includeSubfolders: Bool

	/// - Parameters:
	///   - presets: every preset the targets may refer to.
	///   - targets: the whole target list (assignments of targets that are not applied still act as rules for folders inside them).
	///   - selectedPresetID: the preset selected in the app; ignored when it is not in `presets`.
	public init(presets: [Preset], targets: [TargetAssignment], selectedPresetID: UUID?, includeSubfolders: Bool) {
		var seen = Set<UUID>()
		self.presets = presets.filter { seen.insert($0.id).inserted }
		self.targets = targets
		self.selectedPresetID = selectedPresetID.flatMap { id in seen.contains(id) ? id : nil }
		self.includeSubfolders = includeSubfolders
	}

	public var rules: [FolderRule] {
		var seen = Set<String>()
		return targets.compactMap { t in
			let path = FolderRule.normalize(t.path)   // a decoded TargetAssignment skips init's normalization
			guard let id = t.presetID, seen.insert(path).inserted else { return nil }
			return FolderRule(path: path, presetID: id, appliesToSubfolders: includeSubfolders)
		}
	}

	public var resolver: RuleResolver { RuleResolver(rules: rules, defaultPresetID: selectedPresetID) }

	public func preset(_ id: UUID?) -> Preset? { id.flatMap { id in presets.first { $0.id == id } } }

	/// Splits the requested roots into the ones that resolve to an existing preset and the ones that are skipped.
	/// Paths are normalized and de-duplicated; the order of the request is kept.
	public func partition(roots: [String]) -> (applied: [String], skipped: [SkippedRoot]) {
		let resolver = self.resolver
		var applied: [String] = []
		var skipped: [SkippedRoot] = []
		for root in Self.unique(roots) {
			switch resolver.resolve(path: root).presetID {
			case nil: skipped.append(SkippedRoot(path: root, reason: .noPreset))
			case let id? where preset(id) == nil: skipped.append(SkippedRoot(path: root, reason: .missingPreset(id)))
			default: applied.append(root)
			}
		}
		return (applied, skipped)
	}

	/// Roots that are not inside another root of the list (normalized, de-duplicated, order kept).
	public static func outermost(_ paths: [String]) -> [String] {
		let all = unique(paths)
		return all.filter { p in !all.contains { q in q != p && isInside(p, q) } }
	}

	public static func isInside(_ path: String, _ ancestor: String) -> Bool {
		path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
	}

	static func unique(_ paths: [String]) -> [String] {
		var seen = Set<String>()
		return paths.map(FolderRule.normalize).filter { seen.insert($0).inserted }
	}

	/// Scans the applied roots once each: with subfolders, outer roots first; nested roots only when the outer scan did
	/// not reach them as a candidate. Every folder appears at most once (a candidate entry wins over a skipped one).
	public func scan(roots: [String], options: ScanOptions) -> [ScannedFolder] {
		let scanner = FolderScanner(options: options)
		var out: [ScannedFolder] = []
		var index: [String: Int] = [:]
		var pending = Self.unique(roots)
		while !pending.isEmpty {
			let batch = includeSubfolders ? Self.outermost(pending) : pending
			for folder in scanner.scan(roots: batch.map { URL(fileURLWithPath: $0) }) {
				let key = FolderRule.normalize(folder.url.path)
				if let i = index[key] {
					if out[i].skipReason != nil && folder.skipReason == nil { out[i] = folder }
				} else {
					index[key] = out.count
					out.append(folder)
				}
			}
			let done = Set(batch)
			pending = pending.filter { p in !done.contains(p) && !(index[p].map { out[$0].skipReason == nil } ?? false) }
		}
		return out
	}

	/// Dry run for the requested roots. Nothing is written.
	public func plan(roots: [URL], globals: GlobalDefaults, excludedPaths: [String] = ScanOptions.defaultExclusions(), options: PlanOptions = .init()) -> BatchPlan {
		let (applied, skipped) = partition(roots: roots.map(\.path))
		let scanOptions = ScanOptions(maxDepth: includeSubfolders ? nil : 0, excludedPaths: excludedPaths)
		let scanned = applied.isEmpty ? [] : scan(roots: applied, options: scanOptions)
		let planner = Planner(presets: presets, resolver: resolver, globals: globals, options: options)
		let appliedURLs = applied.map { URL(fileURLWithPath: $0) }
		return BatchPlan(plan: planner.plan(scanned: scanned, roots: appliedURLs), skipped: skipped)
	}
}

public struct BatchPlan: Sendable, Equatable {
	public struct PresetCount: Sendable, Equatable {
		public let presetID: UUID
		public let count: Int
	}

	public let plan: Plan
	/// Requested roots that were not scanned because no (existing) preset applies to them.
	public let skipped: [TargetBatch.SkippedRoot]

	/// The requested roots that resolved to a preset (the operation's roots).
	public var roots: [URL] { plan.roots }

	/// Folders that will change, per target preset: most folders first, ties in order of appearance.
	public var changesByPreset: [PresetCount] {
		var order: [UUID] = []
		var counts: [UUID: Int] = [:]
		for e in plan.changes {
			guard let id = e.presetID else { continue }
			if counts[id] == nil { order.append(id) }
			counts[id, default: 0] += 1
		}
		return order.enumerated()
			.sorted { a, b in counts[a.element]! != counts[b.element]! ? counts[a.element]! > counts[b.element]! : a.offset < b.offset }
			.map { PresetCount(presetID: $0.element, count: counts[$0.element]!) }
	}
}

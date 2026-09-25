import Foundation

public enum PlanCategory: String, Codable, Sendable, Equatable {
	case alreadyMatching
	case willChange
	case unreadable          // parent store exists but cannot be parsed — never treated as "different"
	case excluded
	case permissionDenied
	case unsupported         // e.g. home folder, volume root, parent not writable
	case noPreset            // no rule / default preset resolved
	/// No view change: a folder without view settings of their own whose icon positions alone are removed, because the
	/// system-wide apply changes the Finder default it follows (`PlanOptions.defaultsAfterApply`).
	case iconPositionsOnly
}

public struct FolderState: Sendable, Equatable {
	public let explicit: ViewSettings          // from parent .DS_Store (empty if none)
	public let effective: ViewSettings         // explicit filled with global defaults
	public let hasExplicitRecords: Bool
	public let records: ManagedRecordSet?
}

public struct PlanEntry: Sendable, Equatable, Identifiable {
	public var id: String { folder.path }
	public let folder: URL
	public let depth: Int
	public let location: StoreLocation?
	public let category: PlanCategory
	public let reason: String?
	public let target: ViewSettings?
	public let presetID: UUID?
	public let ruleSource: RuleResolver.Source
	public let diffs: [FieldDiff]
	/// The apply also removes the icon positions in the folder's own `.DS_Store`, so Finder lays its icons out anew
	/// instead of drawing the new size at the old places (`Planner.resetsIconPositions`).
	public var resetsIconPositions = false

	public init(folder: URL, depth: Int, location: StoreLocation?, category: PlanCategory, reason: String?, target: ViewSettings?,
	            presetID: UUID?, ruleSource: RuleResolver.Source, diffs: [FieldDiff], resetsIconPositions: Bool = false) {
		(self.folder, self.depth, self.location, self.category, self.reason) = (folder, depth, location, category, reason)
		(self.target, self.presetID, self.ruleSource, self.diffs, self.resetsIconPositions) = (target, presetID, ruleSource, diffs, resetsIconPositions)
	}

	/// The folder's own `.DS_Store`, where Finder keeps the positions of the items in it (for the home folder the same
	/// file as its location store).
	public var ownStoreURL: URL { (location?.folder ?? folder).appendingPathComponent(".DS_Store") }
}

public struct Plan: Sendable, Equatable {
	public let roots: [URL]
	public let entries: [PlanEntry]

	public init(roots: [URL], entries: [PlanEntry]) {
		self.roots = roots
		self.entries = entries
	}

	public var counts: [PlanCategory: Int] {
		Dictionary(grouping: entries, by: \.category).mapValues(\.count)
	}

	public var changes: [PlanEntry] { entries.filter { $0.category == .willChange } }

	/// How many folders get their icon positions reset (`PlanEntry.resetsIconPositions`): with a view change, or alone
	/// (`PlanCategory.iconPositionsOnly`, not among `changes`).
	public var iconPositionResets: Int { entries.filter { $0.resetsIconPositions && ($0.category == .willChange || $0.category == .iconPositionsOnly) }.count }

	/// Entries grouped by the parent .DS_Store they will modify.
	public var changesByStore: [URL: [PlanEntry]] {
		Dictionary(grouping: changes) { $0.location!.storeURL }
	}
}

public struct PlanOptions: Sendable, Equatable {
	/// When true, folders that only match through inherited global defaults are still written explicitly.
	public var pinInheritedDefaults: Bool
	/// When true, only folders that have view settings of their own are planned: a folder without any follows Finder's
	/// default view, which the same "시스템 전체에 적용" sets, so it is left out of the plan (nothing is written for it,
	/// no `.DS_Store` is created), and so are the folders the scan skipped (hidden, packages, excluded, links) — only a
	/// folder that could not be read for lack of permission is still listed. Compared on the folder's own values
	/// (like `pinInheritedDefaults`), because its inherited ones are about to become the preset's.
	public var ownSettingsOnly: Bool
	/// With `ownSettingsOnly`: Finder's default view once the same apply has written it (the preset's
	/// `globalDefaultsPart` filled from the current defaults), or nil when the apply leaves Finder's defaults alone. A
	/// folder without view settings of its own follows that default, so its icons change too: where they would be drawn
	/// at the positions Finder stored for the old layout (`Planner.resetsIconPositions`), the folder is planned
	/// `iconPositionsOnly` instead of being left out.
	public var defaultsAfterApply: ViewSettings?
	public init(pinInheritedDefaults: Bool = false, ownSettingsOnly: Bool = false, defaultsAfterApply: ViewSettings? = nil) {
		self.pinInheritedDefaults = pinInheritedDefaults || ownSettingsOnly
		self.ownSettingsOnly = ownSettingsOnly
		self.defaultsAfterApply = defaultsAfterApply
	}
}

/// Dry run: reads every folder's current state and decides what Apply would do. Never writes.
public struct Planner: Sendable {
	public let presets: [UUID: Preset]
	public let resolver: RuleResolver
	public let globals: GlobalDefaults
	public let options: PlanOptions
	/// The home folder whose Desktop keeps its icon positions (tests pass a folder of their own).
	public let home: URL

	public init(presets: [Preset], resolver: RuleResolver, globals: GlobalDefaults, options: PlanOptions = .init(),
	            home: URL = FileManager.default.homeDirectoryForCurrentUser) {
		self.presets = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
		self.resolver = resolver
		self.globals = globals
		self.options = options
		self.home = home
	}

	public static func readState(at location: StoreLocation, globals: GlobalDefaults) throws -> FolderState {
		state(of: try StoreEditor.read(location.storeURL), key: location.key, globals: globals)
	}

	/// `readState` from the location's store once it is read (`plan` reads each `.DS_Store` once).
	static func state(of read: StoreEditor.ReadResult, key: String, globals: GlobalDefaults) -> FolderState {
		let records = read.store.map { StoreEditor.managedRecords(in: $0, key: key) }
		let explicit = records.map(ViewRecordCodec.decode) ?? ViewSettings()
		return FolderState(explicit: explicit,
		                   effective: explicit.filling(from: globals.effectiveSettings),
		                   hasExplicitRecords: !(records?.isEmpty ?? true),
		                   records: records)
	}

	public func plan(scanned: [ScannedFolder], roots: [URL]) -> Plan {
		plan(scanned: scanned, roots: roots, stores: StoreReads())
	}

	/// `plan`, reading the `.DS_Store` files through `stores` and the parent folders through `fileManager` (tests count
	/// both). A parent store holds the records of all the folders in it, and a folder's own store is the parent store of
	/// its subfolders: each is read once, and each parent folder is checked and listed once (`ParentStoreLocator`). What
	/// the scan will not ask for again — off the branch of the folder being planned, the scan being depth-first — is
	/// dropped as it goes.
	func plan(scanned: [ScannedFolder], roots: [URL], stores: StoreReads, fileManager: FileManager = .default) -> Plan {
		var stores = stores
		var parents: [String: ParentStoreLocator.Parent] = [:]
		func hasIconPositions(_ url: URL) -> Bool {
			(try? stores.read(url).get())?.store.map(StoreEditor.hasIconPositions(in:)) ?? false
		}
		var entries: [PlanEntry] = []
		for f in scanned {
			let branch = f.url.standardizedFileURL.path
			stores.keepBranch(of: branch)
			parents = parents.filter { StoreReads.isOnBranch($0.key, of: branch) }
			let res = resolver.resolve(path: f.url.path)
			if let skip = f.skipReason {
				if options.ownSettingsOnly && skip != .permissionDenied { continue }
				let cat: PlanCategory = skip == .permissionDenied ? .permissionDenied : .excluded
				entries.append(PlanEntry(folder: f.url, depth: f.depth, location: nil, category: cat, reason: skip.rawValue, target: nil, presetID: res.presetID, ruleSource: res.source, diffs: []))
				continue
			}
			let location: StoreLocation
			do { location = try ParentStoreLocator.locate(f.url, fileManager: fileManager, parents: &parents) } catch {
				entries.append(PlanEntry(folder: f.url, depth: f.depth, location: nil, category: .unsupported, reason: error.localizedDescription, target: nil, presetID: res.presetID, ruleSource: res.source, diffs: []))
				continue
			}
			guard let pid = res.presetID, let preset = presets[pid] else {
				entries.append(PlanEntry(folder: f.url, depth: f.depth, location: location, category: .noPreset, reason: nil, target: nil, presetID: nil, ruleSource: res.source, diffs: []))
				continue
			}
			let state: FolderState
			do { state = Planner.state(of: try stores.read(location.storeURL).get(), key: location.key, globals: globals) } catch {
				entries.append(PlanEntry(folder: f.url, depth: f.depth, location: location, category: .unreadable, reason: error.localizedDescription, target: preset.settings, presetID: pid, ruleSource: res.source, diffs: []))
				continue
			}
			if options.ownSettingsOnly && !state.hasExplicitRecords {
				// Nothing is written for its view; only positions stored for the old default layout go (read only here).
				if let after = options.defaultsAfterApply,
				   Planner.resetsIconPositions(folder: location.folder, before: state.effective, target: after, home: home) {
					let entry = PlanEntry(folder: f.url, depth: f.depth, location: location, category: .iconPositionsOnly, reason: nil, target: nil,
					                      presetID: pid, ruleSource: res.source, diffs: [], resetsIconPositions: true)
					if hasIconPositions(entry.ownStoreURL) { entries.append(entry) }
				}
				continue
			}
			let target = preset.settings
			let explicitDiffs = state.explicit.differences(to: target)
			let effectiveDiffs = state.effective.differences(to: target)
			let needsChange = options.pinInheritedDefaults ? !explicitDiffs.isEmpty : !effectiveDiffs.isEmpty
			let cat: PlanCategory = needsChange ? .willChange : .alreadyMatching
			let shownDiffs = options.pinInheritedDefaults ? explicitDiffs : effectiveDiffs
			var entry = PlanEntry(folder: f.url, depth: f.depth, location: location, category: cat, reason: nil, target: target, presetID: pid, ruleSource: res.source, diffs: shownDiffs)
			if needsChange {
				entry.resetsIconPositions = Planner.resetsIconPositions(folder: location.folder, before: state.effective, target: target, home: home)
					&& hasIconPositions(entry.ownStoreURL)
			}
			entries.append(entry)
		}
		return Plan(roots: roots, entries: entries)
	}

	/// Whether applying `target` to a folder whose effective settings are `before` makes its stored icon positions wrong.
	/// In "없음" (no arrangement) and "자동 격자 정렬" Finder keeps the positions it stored; a new icon size, grid
	/// spacing, text size, label position or item info written on disk (not changed in a window, where Finder lays the
	/// icons out again) would be shown at the old positions, overlapping. A sorted arrangement lines the icons up by
	/// itself. The Desktop keeps its positions: they are the user's own layout. Whether the folder's own `.DS_Store`
	/// holds any positions is checked by the caller.
	static func resetsIconPositions(folder: URL, before: ViewSettings, target: ViewSettings,
	                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
		let old = before.icon
		let new = target.filling(from: before).icon
		guard [SortKey.none, .grid].contains(new.arrangeBy ?? SortKey.none) else { return false }
		let layoutChanges = old.iconSize != new.iconSize || old.gridSpacing != new.gridSpacing || old.textSize != new.textSize
			|| old.labelOnBottom != new.labelOnBottom || old.showItemInfo != new.showItemInfo
		return layoutChanges && !HomeFolders.isDesktop(folder, home: home)
	}
}

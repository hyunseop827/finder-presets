import Foundation
import Testing
@testable import FinderPresetsCore

/// Per-folder preset assignments and batch apply ("선택한/전체 폴더에 적용" with nested target folders).
@Suite struct TargetBatchTests {
	struct Env {
		let base: URL
		let root: URL
		let dirs: AppDirectories
		let globals = GlobalDefaults.factory
		func path(_ rel: String) -> String { FolderRule.normalize(rel.isEmpty ? root.path : root.appendingPathComponent(rel).path) }
		func url(_ rel: String) -> URL { URL(fileURLWithPath: path(rel)) }
		func cleanUp() { try? FileManager.default.removeItem(at: base) }
	}

	/// Root/{A/A1, B/B1/B1a, C, D/D1, .hidden/H1, Pkg.app/Inner}
	static func makeEnv() throws -> Env {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-batch-\(UUID().uuidString)")
		let root = base.appendingPathComponent("Root")
		for name in ["A/A1", "B/B1/B1a", "C", "D/D1", ".hidden/H1", "Pkg.app/Inner"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		return Env(base: base, root: root, dirs: AppDirectories(root: base.appendingPathComponent("AppData")))
	}

	static let p = Preset(name: "Icon88", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88, textSize: 12, arrangeBy: .name)))
	static let q = Preset(name: "List11", settings: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11, sortColumn: .dateModified, sortAscending: false)))
	static let r = Preset(name: "Column", settings: ViewSettings(viewStyle: .column))

	static func rel(_ entry: PlanEntry, in env: Env) -> String {
		let p = FolderRule.normalize(entry.folder.path), root = FolderRule.normalize(env.root.path)
		return p == root ? "" : String(p.dropFirst(root.count + 1))
	}

	static func byRel(_ plan: Plan, in env: Env) -> [String: PlanEntry] {
		Dictionary(plan.entries.map { (rel($0, in: env), $0) }, uniquingKeysWith: { first, _ in first })
	}

	@Test func nestedTargetsWithAssignedPresets() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		// Root (선택한 프리셋) ⊃ B (List11) ⊃ B1 (지정 없음 → B를 따름), D (Column)
		let targets = [
			TargetAssignment(path: env.path("B/B1")),
			TargetAssignment(path: env.path("B"), presetID: Self.q.id),
			TargetAssignment(path: env.path("")),
			TargetAssignment(path: env.path("D"), presetID: Self.r.id)
		]
		let batch = TargetBatch(presets: [Self.p, Self.q, Self.r], targets: targets, selectedPresetID: Self.p.id, includeSubfolders: true)
		#expect(TargetBatch.outermost(targets.map(\.path)) == [env.path("")])

		// Requested nested-first, like a selection that happens to list the inner folders first.
		let result = batch.plan(roots: targets.map { URL(fileURLWithPath: $0.path) }, globals: env.globals, excludedPaths: [])
		let plan = result.plan
		#expect(result.skipped.isEmpty)
		#expect(result.roots.count == 4)

		// Every folder exactly once, nothing reported as a cycle; .hidden and Pkg.app are excluded as usual.
		let paths = plan.entries.map { FolderRule.normalize($0.folder.path) }
		#expect(Set(paths).count == paths.count)
		#expect(!plan.entries.contains { $0.reason == SkipReason.cycle.rawValue })
		#expect(plan.counts[.excluded] == 2)
		#expect(plan.counts[.willChange] == 9)

		let byRel = Self.byRel(plan, in: env)
		func check(_ rel: String, _ preset: Preset, _ source: String) {
			guard let e = byRel[rel] else { Issue.record("no entry for '\(rel)'"); return }
			#expect(e.presetID == preset.id, "\(rel)")
			#expect(e.target == preset.settings, "\(rel)")
			switch (e.ruleSource, source) {
			case (.exactRule, "exact"), (.defaultPreset, "default"): break
			case (.inheritedRule(_, let from), _) where source.hasPrefix("inherited:"):
				#expect(FolderRule.normalize(from) == env.path(String(source.dropFirst("inherited:".count))), "\(rel)")
			default: Issue.record("\(rel): source \(e.ruleSource), expected \(source)")
			}
		}
		check("", Self.p, "default")
		check("A", Self.p, "default")
		check("A/A1", Self.p, "default")
		check("C", Self.p, "default")
		check("B", Self.q, "exact")
		check("B/B1", Self.q, "inherited:B")          // a target without its own preset follows the nearest assigned target
		check("B/B1/B1a", Self.q, "inherited:B")
		check("D", Self.r, "exact")
		check("D/D1", Self.r, "inherited:D")

		#expect(result.changesByPreset == [
			BatchPlan.PresetCount(presetID: Self.p.id, count: 4),
			BatchPlan.PresetCount(presetID: Self.q.id, count: 3),
			BatchPlan.PresetCount(presetID: Self.r.id, count: 2)
		])

		// Apply with the unchanged Applier, check the stored records, then plan again: nothing left to change.
		let applier = Applier(operations: OperationStore(dirs: env.dirs), globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: plan, presetName: "batch"))
		#expect(op.summary.changed == 9 && op.summary.failed == 0)
		#expect(Set(op.entries.map(\.folderPath)).count == op.entries.count)
		for (rel, preset) in [("", Self.p), ("A/A1", Self.p), ("C", Self.p), ("B", Self.q), ("B/B1/B1a", Self.q), ("D/D1", Self.r)] {
			let state = try Planner.readState(at: ParentStoreLocator.locate(env.url(rel)), globals: env.globals)
			#expect(state.hasExplicitRecords && state.explicit.differences(to: preset.settings).isEmpty, "\(rel)")
		}
		let again = batch.plan(roots: [env.url("")], globals: env.globals, excludedPaths: [])
		#expect(again.plan.changes.isEmpty)
		#expect(again.plan.counts[.alreadyMatching] == 9)
		#expect(again.changesByPreset.isEmpty)
	}

	@Test func withoutSubfoldersOnlyTheTargetsThemselves() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let targets = [
			TargetAssignment(path: env.path("")),
			TargetAssignment(path: env.path("B"), presetID: Self.q.id),
			TargetAssignment(path: env.path("B/B1"))
		]
		let batch = TargetBatch(presets: [Self.p, Self.q], targets: targets, selectedPresetID: Self.p.id, includeSubfolders: false)
		#expect(batch.rules.allSatisfy { !$0.appliesToSubfolders })
		let plan = batch.plan(roots: targets.map { URL(fileURLWithPath: $0.path) }, globals: env.globals, excludedPaths: []).plan
		#expect(plan.entries.map { Self.rel($0, in: env) } == ["", "B", "B/B1"])
		let byRel = Self.byRel(plan, in: env)
		#expect(byRel[""]?.presetID == Self.p.id)
		#expect(byRel["B"]?.presetID == Self.q.id)
		#expect(byRel["B/B1"]?.presetID == Self.p.id && byRel["B/B1"]?.ruleSource == .defaultPreset)   // no inheritance without subfolders
	}

	@Test func rootsWithoutAnyPresetAreSkippedAndReported() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let targets = [
			TargetAssignment(path: env.path("")),
			TargetAssignment(path: env.path("B"), presetID: Self.q.id),
			TargetAssignment(path: env.path("C"))
		]
		// Nothing selected in the app: only the assigned target (and what follows it) is applied.
		let batch = TargetBatch(presets: [Self.p, Self.q], targets: targets, selectedPresetID: nil, includeSubfolders: true)
		let all = batch.partition(roots: targets.map(\.path))
		#expect(all.applied == [env.path("B")])
		#expect(all.skipped == [TargetBatch.SkippedRoot(path: env.path(""), reason: .noPreset), TargetBatch.SkippedRoot(path: env.path("C"), reason: .noPreset)])
		let result = batch.plan(roots: targets.map { URL(fileURLWithPath: $0.path) }, globals: env.globals, excludedPaths: [])
		#expect(result.plan.entries.map { Self.rel($0, in: env) } == ["B", "B/B1", "B/B1/B1a"])   // the skipped Root is not scanned
		#expect(result.changesByPreset == [BatchPlan.PresetCount(presetID: Self.q.id, count: 3)])
		#expect(result.skipped.count == 2)

		// A selected folder without its own preset inside an assigned one still resolves through it.
		#expect(batch.partition(roots: [env.path("B/B1")]).applied == [env.path("B/B1")])
		// Nothing applicable at all.
		let none = batch.plan(roots: [env.url("C")], globals: env.globals, excludedPaths: [])
		#expect(none.plan.entries.isEmpty && none.roots.isEmpty && none.skipped.map(\.reason) == [.noPreset])
	}

	@Test func deletedPresetReferencesAreReportedNotWritten() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		let ghost = UUID()
		let targets = [
			TargetAssignment(path: env.path("")),
			TargetAssignment(path: env.path("B"), presetID: ghost)
		]
		// A selected preset that no longer exists is ignored as well.
		#expect(TargetBatch(presets: [Self.p], targets: targets, selectedPresetID: ghost, includeSubfolders: true).selectedPresetID == nil)

		let batch = TargetBatch(presets: [Self.p], targets: targets, selectedPresetID: Self.p.id, includeSubfolders: true)
		let result = batch.plan(roots: targets.map { URL(fileURLWithPath: $0.path) }, globals: env.globals, excludedPaths: [])
		#expect(result.skipped == [TargetBatch.SkippedRoot(path: env.path("B"), reason: .missingPreset(ghost))])
		let byRel = Self.byRel(result.plan, in: env)
		// Root's scan still reaches B: B and everything under it is "프리셋 없음", never silently given the selected preset.
		for rel in ["B", "B/B1", "B/B1/B1a"] {
			#expect(byRel[rel]?.category == .noPreset && byRel[rel]?.presetID == nil, "\(rel)")
		}
		#expect(result.plan.counts[.noPreset] == 3)
		#expect(result.changesByPreset == [BatchPlan.PresetCount(presetID: Self.p.id, count: 6)])   // Root, A, A1, C, D, D1

		let applier = Applier(operations: OperationStore(dirs: env.dirs), globals: env.globals)
		let op = try applier.apply(ApplyRequest(plan: result.plan))
		#expect(op.summary.changed == 6)
		#expect(try StoreEditor.managedRecords(at: env.root.appendingPathComponent(".DS_Store"), key: "B")?.isEmpty ?? true)
		#expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent("B/.DS_Store").path))
	}

	@Test func nestedTargetsTheOuterScanSkipsAreScannedOnTheirOwn() throws {
		let env = try Self.makeEnv()
		defer { env.cleanUp() }
		// Added on purpose: a hidden folder and a folder inside a package, both inside the Root target.
		let targets = [
			TargetAssignment(path: env.path("")),
			TargetAssignment(path: env.path(".hidden"), presetID: Self.q.id),
			TargetAssignment(path: env.path("Pkg.app/Inner"))
		]
		let batch = TargetBatch(presets: [Self.p, Self.q], targets: targets, selectedPresetID: Self.p.id, includeSubfolders: true)
		let plan = batch.plan(roots: targets.map { URL(fileURLWithPath: $0.path) }, globals: env.globals, excludedPaths: []).plan
		let paths = plan.entries.map { FolderRule.normalize($0.folder.path) }
		#expect(Set(paths).count == paths.count)
		let byRel = Self.byRel(plan, in: env)
		#expect(byRel[".hidden"]?.category == .willChange && byRel[".hidden"]?.presetID == Self.q.id)
		#expect(byRel[".hidden/H1"]?.presetID == Self.q.id)
		#expect(byRel["Pkg.app"]?.category == .excluded)                  // the package itself stays excluded
		#expect(byRel["Pkg.app/Inner"]?.category == .willChange && byRel["Pkg.app/Inner"]?.presetID == Self.p.id)
		#expect(plan.counts[.excluded] == 1)
	}

	@Test func outermostRoots() {
		#expect(TargetBatch.outermost(["/a/b", "/a", "/ab", "/a/", "/a/b/c"]) == ["/a", "/ab"])
		#expect(TargetBatch.outermost(["/x/y", "/"]) == ["/"])
		#expect(TargetBatch.outermost(["/x/y", "/x/z"]) == ["/x/y", "/x/z"])
		#expect(TargetBatch.isInside("/a/b", "/a") && !TargetBatch.isInside("/ab", "/a") && !TargetBatch.isInside("/a", "/a"))
	}

	@Test func targetAssignmentKeepsTheOldListFormat() throws {
		let legacy = Data(#"[{"path":"/tmp/finder-presets-old"},{"path":"/tmp/finder-presets-new","presetID":"6A1B2C3D-0000-4000-8000-000000000009"}]"#.utf8)
		let decoded = try JSONCoding.decoder().decode([TargetAssignment].self, from: legacy)
		#expect(decoded == [TargetAssignment(path: "/tmp/finder-presets-old"), TargetAssignment(path: "/tmp/finder-presets-new", presetID: UUID(uuidString: "6A1B2C3D-0000-4000-8000-000000000009"))])
		let encoded = String(decoding: try JSONCoding.encoder().encode([TargetAssignment(path: "/tmp/finder-presets-old")]), as: UTF8.self)
		#expect(!encoded.contains("presetID"))
	}
}

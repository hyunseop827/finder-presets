#if DEBUG
import Foundation
import AppKit
import FinderPresetsCore

/// Debug builds only (`./scripts/build-app.sh` without `release`); a release build has no `--selftest`.
///
/// `FinderPresets --selftest <sourceFolder> <targetRoot> [<secondSource>]`: drives AppModel exactly like the
/// UI does (import preset from a folder → add target → apply to all → confirm → per-folder presets on nested targets
/// and a batch apply → selected apply → preset file round trip → history, undo with a conflict, pin and retention →
/// the preset editor: its preview window opening, following the draft and closing with it, clamped numbers, refused values, cancel, save,
/// apply of the edited values, a new preset → the Finder services up to
/// the apply confirmation → the quick preset on one folder, recorded, without restarting Finder) and exits with 0/1. Never
/// touches Finder or its global defaults (a global undo is only prepared, never confirmed; the quick preset's Apple Event
/// is never sent and its Finder restart is off while the self-test runs).
///
/// Needs: `<targetRoot>` with subfolders `B` and `C/C1`, and two source folders with different view settings of their own
/// (stored in their parent's `.DS_Store`).
///
/// Safety: it refuses to run without `FINDER_PRESETS_DATA_DIR` and refuses a data folder that already holds preset files or
/// target folders on disk (or files the model could not read), because "전체 폴더에 적용" would otherwise include
/// whatever the user had stored there, real target folders included. Every
/// apply is limited to `<targetRoot>` (the extra target folders it adds are subfolders of it), and the cleanup removes
/// only the presets and targets this run created.
@MainActor
enum SelfTest {
	/// How to start the self-test; printed when the folder arguments are missing.
	static let usage = "FinderPresets --selftest <sourceFolder> <targetRoot> [<secondSource>]"

	static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

	/// Returns true when a self-test was requested by the command line (and started). Exits with 2 when the folders are missing.
	@discardableResult
	static func runIfRequested(model: AppModel) -> Bool {
		let args = CommandLine.arguments
		guard let i = args.firstIndex(of: "--selftest") else { return false }
		@MainActor func log(_ s: String) { print("[selftest] \(s)"); fflush(stdout) }
		guard args.count >= i + 3 else {
			log("FAIL: 폴더 인자가 모자랍니다. 사용법: \(usage)")
			exit(2)
		}

		// Guards first, before anything is written.
		let env = ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"] ?? ""
		guard !env.isEmpty else {
			log("FAIL: FINDER_PRESETS_DATA_DIR 가 없습니다. 셀프테스트는 격리된 빈 데이터 폴더로만 실행합니다 (예: FINDER_PRESETS_DATA_DIR=~/FinderPresets-Test/.finder-presets-selftest).")
			exit(1)
		}
		// The disk decides, not the model: a preset file or targets.json the model could not read leaves the model empty.
		let found = dataFolderContents(model)
		guard found.isEmpty, model.presets.isEmpty, model.targets.isEmpty, model.errorMessage == nil else {
			log("FAIL: 데이터 폴더 \(model.dirs.root.path) 가 비어 있지 않거나 읽지 못했습니다 (\((found + (model.errorMessage.map { ["오류: \($0)"] } ?? [])).joined(separator: "; "))). 빈 폴더를 FINDER_PRESETS_DATA_DIR 로 지정하세요.")
			exit(1)
		}
		log("data dir: \(model.dirs.root.path) (empty)")

		// The home folder and the folders above it are never added (they are only checked to exist; nothing is listed or saved).
		let home = FileManager.default.homeDirectoryForCurrentUser
		let tooWide = [home, home.deletingLastPathComponent(), URL(fileURLWithPath: "/")]
		model.addFolders(tooWide)
		// The texts are compared in the app's language (the same localized strings the model writes).
		guard model.targets.isEmpty, model.errorMessage == AppModel.homeRefusal(AppModel.folderAddition(tooWide, listed: []).refused) else {
			log("FAIL: home folder or a folder above it was accepted as a target: \(model.targets.map(\.path))")
			exit(1)
		}
		model.errorMessage = nil
		log("home folder and its parents refused")

		let source = URL(fileURLWithPath: args[i + 1])
		let target = URL(fileURLWithPath: args[i + 2])
		let secondSource = URL(fileURLWithPath: args.count >= i + 4 ? args[i + 3] : args[i + 1])
		let targetPath = FolderRule.normalize(target.path)
		Task { @MainActor in
			@MainActor func waitIdle() async { while model.isWorking { try? await Task.sleep(for: .milliseconds(100)) } }
			/// Only the folder this run added — never anything else the model might list.
			@MainActor func targetRoots() -> [URL] { model.targets.filter { $0.path == targetPath }.map(\.url) }
			/// "전체 폴더에 적용" restricted to <targetRoot> and the subfolders of it this run added as targets.
			@MainActor func treeRoots() -> [URL] { model.targets.filter { $0.path == targetPath || TargetBatch.isInside($0.path, targetPath) }.map(\.url) }
			var createdPresets = Set<UUID>()
			var createdTargets = Set<String>()
			@MainActor func fail(_ s: String) -> Never { log("FAIL: \(s)"); exit(1) }

			// 1. preset from folder (same code path as drag & drop onto the preset list)
			model.importPreset(from: source)
			guard let preset = model.selectedPreset else { fail("preset not created") }
			createdPresets.insert(preset.id)
			log("preset: \(preset.name) view=\(preset.settings.viewStyle?.rawValue ?? "-") icon=\(preset.settings.icon.iconSize ?? -1) text=\(preset.settings.icon.textSize ?? -1) sort=\(preset.settings.icon.arrangeBy?.rawValue ?? "-")")

			// 2. add target folder (same as drop onto the folder list)
			model.addFolders([target])
			guard targetRoots().count == 1 else { fail("target not added") }
			createdTargets.insert(targetPath)
			log("targets: \(model.targets.map(\.name))")

			// 3. "전체 폴더에 적용…" → confirmation (the list holds only <targetRoot>, and the roots are filtered to it anyway)
			model.includeSubfolders = true
			model.prepareApply(to: targetRoots())
			await waitIdle()
			log("status: \(model.status)")
			guard let pending = model.pendingApply else { fail("nothing to apply") }
			guard pending.roots.map(\.path) == [targetPath] else { fail("unexpected roots \(pending.roots.map(\.path))") }
			log("pending changes: \(pending.plan.changes.count) folders, stores: \(pending.plan.changesByStore.count), roots: \(pending.roots.map(\.lastPathComponent))")

			// 4. confirm — the automatic cleanup runs after every recorded operation, in the background.
			let cleanupsBefore = model.retentionRuns
			model.confirmApply()
			await waitIdle()
			log("status: \(model.status)")
			log("askRelaunch: \(model.askRelaunch)")
			for _ in 0..<50 where model.retentionRuns == cleanupsBefore { try? await Task.sleep(for: .milliseconds(100)) }
			var ok = model.retentionRuns > cleanupsBefore
			if !ok { log("FAIL: the automatic cleanup did not run after the apply") } else { log("cleanup ran after the apply") }
			// The restart question carries the apply it follows: "지금 다시 시작" writes again what Finder's quit overwrites
			// of it (never answered here).
			let asksForApply = model.askRelaunch && model.relaunchAfter == .apply && model.relaunchOperationID != nil
				&& model.relaunchOperationID == model.recentOperation?.id
			if !asksForApply {
				log("FAIL: the restart question does not carry the apply: \(String(describing: model.relaunchOperationID)) vs \(String(describing: model.recentOperation?.id))")
			}
			ok = ok && asksForApply

			// 5. re-run apply → must report nothing to change
			model.askRelaunch = false
			model.prepareApply(to: targetRoots())
			await waitIdle()
			log("status2: \(model.status)")
			ok = ok && model.pendingApply == nil && reportsNoChange(model.status)

			// 6. per-folder presets: <targetRoot> keeps the selected preset, its subfolder C gets the second preset,
			//    C/C1 is a nested target without its own preset (follows C). Then one batch apply over all three.
			let batchOK = await perFolderBatch(model: model, first: preset, secondSource: secondSource, targetPath: targetPath,
			                                   createdPresets: &createdPresets, createdTargets: &createdTargets, treeRoots: treeRoots, log: log)
			ok = ok && batchOK
			guard let second = model.presets.first(where: { createdPresets.contains($0.id) && $0.id != preset.id }) else { fail("second preset missing") }

			// 7. "선택한 폴더에 적용…" with the second preset selected, on <targetRoot> only: <targetRoot> and B change,
			//    C (assigned the same preset) and C1 already match.
			model.selectedPresetID = second.id
			model.selectedTargets = [targetPath]
			model.prepareApply(to: model.targets.filter { model.selectedTargets.contains($0.path) }.map(\.url))
			await waitIdle()
			log("status3: \(model.status)")
			let selectedChanges = model.pendingApply?.changeCount ?? 0
			if model.pendingApply != nil { model.confirmApply(); await waitIdle(); log("status4: \(model.status)") }
			let bNow = storedMatches(target.appendingPathComponent("B"), second, model: model)
			if selectedChanges != 2 || !bNow { log("FAIL: selected apply changed \(selectedChanges) folders (expected 2), B holds second preset: \(bNow)"); ok = false }
			// The status line that reports the apply offers "되돌리기…" for its operation.
			let selectedApply = model.undoShortcutID
			if selectedApply == nil { log("FAIL: no \"되돌리기…\" in the status line after the apply"); ok = false }
			if selectedApply == nil || model.relaunchOperationID != selectedApply {
				log("FAIL: the restart question does not carry the selected apply: \(String(describing: model.relaunchOperationID))"); ok = false
			}

			// 8. preset file round trip: "파일로 내보내기…" → "파일에서 불러오기…" through a temporary JSON under the target tree
			let exportURL = target.appendingPathComponent("finder-presets-selftest-\(UUID().uuidString.prefix(8)).json")
			var roundTrip = false
			if let original = model.presets.first(where: { $0.id == preset.id }) {
				model.exportPreset(original, to: exportURL)
				let countBefore = model.presets.count
				let exported = FileManager.default.fileExists(atPath: exportURL.path)
				model.importPresetFiles([exportURL])
				if exported, let imported = model.presets.first(where: { $0.id == model.selectedPresetID }) {
					createdPresets.insert(imported.id)
					roundTrip = model.errorMessage == nil
						&& model.presets.count == countBefore + 1
						&& imported.id != original.id
						&& imported.settings == original.settings
						&& imported.name.hasPrefix(original.name) && imported.name != original.name
					log("roundtrip: exported \(exportURL.lastPathComponent) → imported \"\(imported.name)\" settings=\(imported.settings == original.settings ? "same" : "DIFFERENT")")
				}
			}
			if !roundTrip { log("FAIL: preset file round trip" + (model.errorMessage.map { " — \($0)" } ?? "")) }
			try? FileManager.default.removeItem(at: exportURL)
			ok = ok && roundTrip

			// 9. "기록": the selected apply of step 7 is listed and offered for undo; a folder changed again after it is a
			//    conflict; the undo puts B back at file level and keeps the later change; then pin and the retention policy.
			if let selectedApply {
				let historyOK = await historyAndUndo(model: model, applyID: selectedApply, first: preset, second: second, targetPath: targetPath, log: log)
				ok = ok && historyOK
			}

			// 10. "편집…" / "새 프리셋…" (the preset editor's model path; the sheet only holds the draft): typed numbers
			//     outside Finder's range are clamped, values that cannot be saved are refused and write nothing, "취소" changes nothing, "저장" rewrites the preset file (same ID) and
			//     the list and the folder capsule follow, a plan made before the edit is thrown away, the next apply writes
			//     the new values, a file changed elsewhere is never overwritten, a new preset exists only after "만들기"; the
			//     view control ("유지" and the four views, ⌘0–⌘4) sets only the view style ("유지": none), the values of the
			//     views not shown are saved unchanged, a typed text that cannot be saved and is no longer shown goes back
			//     to the preset's value, and values set with the sliders are saved.
			let editOK = await presetEditing(model: model, first: preset, second: second, targetPath: targetPath,
			                                 createdPresets: &createdPresets, treeRoots: treeRoots, log: log)
			ok = ok && editOK

			// 11. The Finder services (the model path FinderServiceProvider calls, with the items read from a pasteboard
			//     like Finder's): add, make presets, apply up to the confirmation — never confirmed, nothing written.
			let servicesOK = await finderServices(model: model, source: source, first: preset, targetPath: targetPath,
			                                      createdPresets: &createdPresets, createdTargets: &createdTargets, log: log)
			ok = ok && servicesOK

			// 12. "빠른 적용": the quick preset on a new folder of <targetRoot>, the way the service goes on once Finder has
			//     answered (the Apple Event is never sent): refused without a star; with one, that folder alone is written at
			//     once and recorded (undo on the status line), its subfolder untouched, Finder not restarted; a second press
			//     finds it already the same and writes nothing.
			let quickOK = await quickPreset(model: model, first: preset, targetPath: targetPath, log: log)
			ok = ok && quickOK

			// cleanup: only what this run created (presets by ID, the target folders it added); the operations step 9's
			// retention kept stay as records (delete the isolated data folder afterwards).
			// Deleting the second preset must also clear C's assignment (in the model and in targets.json).
			for id in createdPresets { model.deletePreset(id) }
			let cPath = FolderRule.normalize(target.appendingPathComponent("C").path)
			let cleared = model.targets.first { $0.path == cPath }.map { $0.presetID == nil } ?? false
			let clearedOnDisk = savedTargets(model).first { $0.path == cPath }.map { $0.presetID == nil } ?? false
			log("assignment cleared after preset delete: \(cleared) (targets.json: \(clearedOnDisk))")
			ok = ok && cleared && clearedOnDisk
			// Deleting the starred preset (step 12) also removes the star.
			log("quick preset cleared after preset delete: \(model.quickPresetID == nil && model.quickPresetSetting.id == nil)")
			ok = ok && model.quickPresetID == nil && model.quickPresetSetting.id == nil
			model.removeTargets(createdTargets)
			log("cleanup: presets left \(model.presets.count), targets left \(model.targets.count)")
			log(ok ? "PASS" : "FAIL")
			exit(ok ? 0 : 1)
		}
		return true
	}

	/// Step 6. Returns false (after logging why) when any check fails.
	private static func perFolderBatch(model: AppModel, first: Preset, secondSource: URL, targetPath: String,
	                                   createdPresets: inout Set<UUID>, createdTargets: inout Set<String>,
	                                   treeRoots: @MainActor () -> [URL], log: @MainActor (String) -> Void) async -> Bool {
		@MainActor func waitIdle() async { while model.isWorking { try? await Task.sleep(for: .milliseconds(100)) } }
		let tree = URL(fileURLWithPath: targetPath)
		let b = tree.appendingPathComponent("B"), c = tree.appendingPathComponent("C"), c1 = c.appendingPathComponent("C1")
		let cPath = FolderRule.normalize(c.path), c1Path = FolderRule.normalize(c1.path)
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }

		// targets.json written before assignments existed still loads (every folder on "선택한 프리셋 사용").
		let legacy = try? JSONCoding.decoder().decode([TargetFolder].self, from: Data(#"[{"path":"/finder-presets-selftest-legacy"}]"#.utf8))
		check(legacy?.count == 1 && legacy?.first?.presetID == nil, "legacy targets.json format")

		// Second preset (import selects it); the batch keeps the first one selected.
		model.importPreset(from: secondSource)
		guard let second = model.selectedPreset, second.id != first.id else { log("FAIL: second preset not created"); return false }
		createdPresets.insert(second.id)
		model.selectedPresetID = first.id

		// Give B, C and C1 a third look (column view) so both presets have something to write in one batch.
		// Same Planner/Applier path as the app, limited to B and C (inside <targetRoot>).
		let column = Preset(name: "selftest-column", settings: ViewSettings(viewStyle: .column))
		let scramble = Planner(presets: [column], resolver: RuleResolver(rules: [], defaultPresetID: column.id), globals: model.globals)
		let scanned = FolderScanner(options: ScanOptions()).scan(roots: [b, c])
		_ = try? Applier(operations: model.operationStore, globals: model.globals).apply(ApplyRequest(plan: scramble.plan(scanned: scanned, roots: [b, c]), presetName: column.name))

		// Nested targets: C with the second preset (row menu), C1 without one.
		model.addFolders([c, c1])
		createdTargets.formUnion([cPath, c1Path])
		model.assignPreset(second.id, to: [cPath])
		check(model.targets.count == 3 && model.targets.allSatisfy { $0.path == targetPath || TargetBatch.isInside($0.path, targetPath) }, "targets are \(model.targets.map(\.path))")
		let saved = savedTargets(model)
		check(saved.first { $0.path == cPath }?.presetID == second.id && saved.first { $0.path == targetPath }?.presetID == nil, "assignment saved in targets.json: \(saved)")
		let inherited = model.targets.first { $0.path == c1Path }.flatMap { model.inheritedAssignment(for: $0) }
		check(inherited?.from.path == cPath && inherited?.preset.id == second.id, "C1 follows C's preset (row caption)")
		log("assigned: \(model.targets.map { "\($0.name)=\(model.preset($0.presetID)?.name ?? "선택한 프리셋")" })")

		// A change made while the folders are being checked throws the result away (nothing shown, nothing written) …
		model.prepareApply(to: treeRoots())
		model.includeSubfolders.toggle(); model.includeSubfolders.toggle()   // same value again, but it was edited
		await waitIdle()
		check(model.pendingApply == nil && model.status == AppModel.staleNote, "edit during the check discards the plan: \(model.status)")
		// … and so does one made after the plan was shown, before "적용".
		model.prepareApply(to: treeRoots())
		await waitIdle()
		check(model.pendingApply != nil, "plan shown before the edit: \(model.status)")
		model.assignPreset(first.id, to: [c1Path]); model.assignPreset(nil, to: [c1Path])
		model.confirmApply()
		await waitIdle()
		check(model.pendingApply == nil && model.errorMessage?.hasPrefix(String(localized: "아무것도 바꾸지 않았습니다.")) == true && !storedMatches(b, first, model: model),
		      "edit before confirming writes nothing: \(model.errorMessage ?? "-")")
		model.errorMessage = nil
		// "취소" in the confirmation writes nothing and the status line says so (it no longer announces the change).
		model.prepareApply(to: treeRoots())
		await waitIdle()
		check(model.pendingApply != nil, "plan shown before cancelling: \(model.status)")
		model.cancelPendingApply()
		check(model.pendingApply == nil && model.status == AppModel.cancelNote && !storedMatches(b, first, model: model),
		      "cancel writes nothing and says so: \(model.status)")

		// Only local folders are added: a plain file and a web link are reported, never listed.
		let targetsBefore = model.targets
		model.addFolders([b.appendingPathComponent("f1.txt"), URL(string: "https://example.com/Applications")!])
		check(model.targets == targetsBefore && model.errorMessage == String(localized: "폴더만 추가할 수 있습니다. 추가하지 않은 항목: \("f1.txt, https://example.com/Applications")"),
		      "a file or a web link is not added: \(model.targets.map(\.path)) \(model.errorMessage ?? "-")")
		model.errorMessage = nil

		// "전체 폴더에 적용…"
		model.prepareApply(to: treeRoots())
		await waitIdle()
		log("batch status: \(model.status)")
		guard let pending = model.pendingApply else { log("FAIL: batch has nothing to apply"); return false }
		let entries = pending.plan.entries
		let rel = { (e: PlanEntry) in FolderRule.normalize(e.folder.path) }
		check(pending.roots.map { FolderRule.normalize($0.path) } == [targetPath, cPath, c1Path], "batch roots \(pending.roots.map(\.path))")
		check(pending.skipped.isEmpty, "batch skipped \(pending.skipped)")
		check(Set(entries.map(rel)).count == entries.count && entries.count == 4, "batch entries once each: \(entries.map { $0.folder.lastPathComponent })")
		check(entries.allSatisfy { $0.category == .willChange || $0.category == .alreadyMatching }, "batch categories \(pending.plan.counts)")
		let byPath = Dictionary(entries.map { (rel($0), $0) }, uniquingKeysWith: { a, _ in a })
		check(byPath[targetPath]?.ruleSource == .defaultPreset && byPath[targetPath]?.category == .alreadyMatching, "root: selected preset, unchanged")
		check(byPath[FolderRule.normalize(b.path)]?.presetID == first.id && byPath[FolderRule.normalize(b.path)]?.category == .willChange, "B: first preset")
		if case .exactRule? = byPath[cPath]?.ruleSource {} else { check(false, "C: exact rule") }
		if case .inheritedRule(_, let from)? = byPath[c1Path]?.ruleSource { check(from == cPath, "C1 inherits from C") } else { check(false, "C1: inherited rule") }
		check(byPath[cPath]?.presetID == second.id && byPath[c1Path]?.presetID == second.id, "C, C1: second preset")
		check(pending.presetChanges == [.init(name: second.name, count: 2), .init(name: first.name, count: 1)], "per-preset counts \(pending.presetChanges)")
		let message = MainView.confirmMessage(pending)
		let perPreset = [String(localized: "\(Fmt.name(second.name)) \(2)개 폴더"), String(localized: "\(Fmt.name(first.name)) \(1)개 폴더")].joined(separator: ", ")
		check(message.contains(String(localized: "총 \(3)개 폴더를 바꿉니다: \(perPreset).")), "confirmation text: \(message)")
		log("confirm: \(message.replacingOccurrences(of: "\n", with: " / "))")

		model.confirmApply()
		await waitIdle()
		log("batch done: \(model.status)")
		model.askRelaunch = false
		for (folder, preset) in [(tree, first), (b, first), (c, second), (c1, second)] {
			check(storedMatches(folder, preset, model: model), "\(folder.lastPathComponent) holds \(preset.name) in its parent .DS_Store")
		}

		// Same batch again → nothing to change.
		model.prepareApply(to: treeRoots())
		await waitIdle()
		log("batch status2: \(model.status)")
		check(model.pendingApply == nil && reportsNoChange(model.status), "second batch changes nothing")
		model.pendingApply = nil

		// "지정 해제" says what the folder uses now: the assigned folder around it, the selected preset, or nothing.
		model.assignPreset(first.id, to: [c1Path]); model.assignPreset(nil, to: [c1Path])
		check(model.status.contains(String(localized: "상위 폴더 \(Fmt.name("C"))의 지정(\(Fmt.name(second.name)))을 따릅니다.")), "clearing C1 names C's preset: \(model.status)")
		model.assignPreset(second.id, to: [targetPath]); model.assignPreset(nil, to: [targetPath])
		check(model.status.contains(String(localized: "왼쪽에서 선택한 프리셋(\(Fmt.name(first.name)))을 씁니다.")), "clearing the root names the selected preset: \(model.status)")
		// With no preset selected, a reload (rename, and back) keeps it that way, and clearing says the folder is skipped.
		model.selectedPresetID = nil
		model.rename(second, to: second.name + " (selftest)")
		// The status line names the new name (a line about the old one would be stale).
		check(model.status == String(localized: "프리셋 \"\(Fmt.name(second.name))\"의 이름을 \"\(Fmt.name(second.name + " (selftest)"))\"(으)로 바꿨습니다."),
		      "rename reports the new name: \(model.status)")
		if let renamed = model.preset(second.id) { model.rename(renamed, to: " \(second.name) ") }   // trimmed back
		check(model.selectedPresetID == nil, "a reload does not select a preset again")
		check(model.preset(second.id)?.name == second.name, "rename trims and restores the name: \(model.preset(second.id)?.name ?? "-")")
		// A blank name is never stored.
		model.rename(model.preset(second.id) ?? second, to: "  ")
		check(model.preset(second.id)?.name == second.name && model.status == String(localized: "이름이 비어 있어 프리셋 \"\(Fmt.name(second.name))\"의 이름을 바꾸지 않았습니다."),
		      "blank rename refused: \(model.status)")
		model.assignPreset(second.id, to: [targetPath]); model.assignPreset(nil, to: [targetPath])
		check(model.status.contains(String(localized: "선택한 프리셋이 없어 적용할 때 건너뜁니다.")), "clearing without a selected preset says skipped: \(model.status)")
		model.selectedPresetID = first.id
		check(model.errorMessage == nil, "no error in the assignment checks: \(model.errorMessage ?? "-")")
		log("assignment notes and kept deselection checked")
		return ok
	}

	/// Step 9, through the calls the history sheet makes (openHistory, loadHistory, prepareUndo, confirmUndo, setPinned) and
	/// the retention the app runs after every recorded operation. Returns false (after logging why) when any check fails.
	private static func historyAndUndo(model: AppModel, applyID: UUID, first: Preset, second: Preset, targetPath: String,
	                                   log: @MainActor (String) -> Void) async -> Bool {
		@MainActor func waitUndo() async {
			for _ in 0..<1200 {
				switch model.undoPhase {
				case .preparing, .running: try? await Task.sleep(for: .milliseconds(50))
				default: return
				}
			}
		}
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }
		let store = model.operationStore
		let tree = URL(fileURLWithPath: targetPath)
		let b = tree.appendingPathComponent("B")
		let bPath = FolderRule.normalize(b.path)
		func normalized(_ paths: [String]) -> [String] { paths.map(FolderRule.normalize) }
		func stored() -> Set<UUID> { Set(((try? store.list()) ?? []).map(\.id)) }

		// The history lists every record on disk, newest first, and offers the apply.
		await model.loadHistory()
		let onDisk = stored()
		check(Set(model.historyItems.map(\.id)) == onDisk && !onDisk.isEmpty, "history lists every record: \(model.historyItems.count) of \(onDisk.count)")
		check(model.historyItems.map(\.startedAt) == model.historyItems.map(\.startedAt).sorted(by: >), "history is newest first")
		guard let item = model.historyItems.first(where: { $0.id == applyID }), let applied = try? store.load(id: applyID),
		      let bEntry = applied.entries.first(where: { FolderRule.normalize($0.folderPath) == bPath && $0.status == .changed }) else {
			log("FAIL: the apply (and its change of B) is not in the history")
			return false
		}
		check(item.kind == .apply && item.canUndo && item.status == .undoable && item.folderCount == 2 && normalized(item.roots) == [targetPath],
		      "history row of the apply: \(item.kind) canUndo=\(item.canUndo) folders=\(item.folderCount) roots=\(item.roots)")
		log("history: \(model.historyItems.count) records, apply row \"\(HistoryText.title(item))\" — \(HistoryText.subtitle(item))")

		// Selecting a record: the pane reads that one manifest and gets the preset it applied (drawn as the preview) and
		// the folders it changed, under the root the apply ran on.
		model.historySelection = applyID
		await model.loadHistoryDetails(applyID)
		guard let details = model.historyDetails, details.id == applyID else {
			log("FAIL: no details for the selected record: \(String(describing: model.historyDetails))")
			return false
		}
		check(details.preset != nil && details.preset == applied.presetSnapshot,
		      "the selected record's preset is the one its manifest recorded: \(String(describing: details.preset))")
		check(PresetPreview.make(settings: details.preset ?? ViewSettings(), globals: model.globals, locale: AppLanguage.locale,
		                         now: Date()).summary.isEmpty == false, "the preset draws a preview")
		check(details.folders.total == item.folderCount && details.folders.shown.contains { FolderRule.normalize($0.path) == bPath },
		      "the folder list holds the changed folders: \(details.folders.shown.map(\.path))")
		check(details.folders.shown.allSatisfy { normalized([$0.root]) == [targetPath] }, "every folder sits under the apply's root")
		// A row shows where it sits inside its root, never the root's own long path again.
		check(details.folders.shown.allSatisfy { !HistoryText.folderRow($0.path, under: $0.root).place.hasPrefix("/") },
		      "a folder row's place is relative to its root: \(details.folders.shown.map { HistoryText.folderRow($0.path, under: $0.root).place })")
		check(HistoryText.foldersTitle(item, count: details.folders.total) == String(localized: "바뀐 폴더 \(item.folderCount)개"),
		      "the folder heading counts them")
		log("details: \(HistoryText.foldersTitle(item, count: details.folders.total)) · " +
			details.folders.shown.map { HistoryText.folderRow($0.path, under: $0.root).name }.joined(separator: ", "))

		// The root is changed again after the apply (a third look, as a user in Finder would): a conflict for the undo.
		let column = Preset(name: "selftest-column", settings: ViewSettings(viewStyle: .column))
		let planner = Planner(presets: [column], resolver: RuleResolver(rules: [], defaultPresetID: column.id), globals: model.globals)
		let scanned = FolderScanner(options: ScanOptions(maxDepth: 0)).scan(roots: [tree])
		let later = try? Applier(operations: store, globals: model.globals).apply(ApplyRequest(plan: planner.plan(scanned: scanned, roots: [tree]), presetName: column.name))
		check(later?.summary.changed == 1, "the root changed again after the apply")

		// "기록" again after that new record: the newest is chosen, never the apply chosen before, which "되돌리기" would
		// then undo. Chosen again and reopened with nothing new: the choice stays.
		@MainActor func reopenHistory() async {
			model.openHistory()
			for _ in 0..<200 where model.historyShownBefore != nil { try? await Task.sleep(for: .milliseconds(50)) }
		}
		await reopenHistory()
		check(later != nil && model.historyItems.first?.id == later?.id && model.historySelection == later?.id,
		      "reopened after a new record, the newest is chosen: \(String(describing: model.historySelection))")
		model.historySelection = applyID
		model.closeHistory()
		await reopenHistory()
		check(model.historySelection == applyID, "reopened with nothing new, the choice stays: \(String(describing: model.historySelection))")
		model.closeHistory()

		// "되돌리기…": the confirmation, nothing written yet.
		model.prepareUndo(applyID)
		await waitUndo()
		guard case .confirm(let pending) = model.undoPhase else {
			log("FAIL: no undo confirmation: \(model.undoPhase) \(model.historyNotice ?? "")")
			return false
		}
		check(!pending.isGlobal && pending.canConfirm, "a folder undo that can be confirmed")
		check(normalized(pending.restorable) == [bPath] && normalized(pending.conflicts) == [targetPath] && pending.alreadyRestored.isEmpty,
		      "confirmation: restorable \(pending.restorable), conflicts \(pending.conflicts)")
		check(storedMatches(b, second, model: model), "the confirmation wrote nothing (B still holds \(second.name))")
		log("undo confirmation: \(pending.restorable.count) to undo, conflicts: \(pending.conflicts.map { URL(fileURLWithPath: $0).lastPathComponent })")

		// "되돌리기"
		model.askRelaunch = false
		model.confirmUndo()
		await waitUndo()
		guard case .result(let outcome) = model.undoPhase, let undoID = outcome.undoOperationID else {
			log("FAIL: no undo result: \(model.undoPhase)")
			return false
		}
		log("undo: \(model.status)")
		check(outcome.error == nil && normalized(outcome.restored) == [bPath] && normalized(outcome.conflicts) == [targetPath] && outcome.failed.isEmpty,
		      "undo result: restored \(outcome.restored), conflicts \(outcome.conflicts), failed \(outcome.failed), error \(outcome.error ?? "-")")
		check(model.status == outcome.message && StatusBar.tone(status: model.status, working: false) == .warning,
		      "status line after an undo with a conflict: \(model.status)")
		let bRecords = (try? StoreEditor.managedRecords(at: URL(fileURLWithPath: bEntry.storePath), key: bEntry.key)) ?? nil
		check(bRecords == (bEntry.before ?? ManagedRecordSet()), "B's records in its parent .DS_Store are exactly the ones from before the apply")
		check(storedMatches(b, first, model: model), "B holds \(first.name) again")
		check(storedMatches(tree, column, model: model), "the conflicting root keeps its later change")
		check(model.askRelaunch, "a folder undo asks to restart Finder (never answered here)")
		check(model.relaunchAfter == .undo && model.relaunchOperationID == undoID,
		      "the restart question carries the undo: \(String(describing: model.relaunchOperationID)) vs \(undoID)")
		model.askRelaunch = false
		model.closeUndoResult()

		// The history: undone by the new undo record, no longer offered, and the status line shortcut is gone.
		await model.loadHistory()
		let undone = model.historyItems.first { $0.id == applyID }
		check(undone.map { $0.status == .undone(by: undoID) && !$0.canUndo && HistoryText.badge($0)?.text == String(localized: "이미 되돌림") } == true,
		      "history: undone by the undo record (\(String(describing: undone?.status)))")
		check(model.historyItems.first { $0.id == undoID }.map { $0.isUndo && !$0.canUndo } == true, "the undo is recorded and never offered")
		check(model.recentOperation == nil, "no shortcut after the undo")
		model.prepareUndo(applyID)
		await waitUndo()
		check(model.undoPhase == .idle && model.historyNotice == UndoRefusal.alreadyUndone.message, "a second undo is refused: \(model.historyNotice ?? "-")")

		// Pin: only the manifest's `pinned` key changes.
		check(await model.setPinned(applyID, pinned: true), "pin: \(model.historyNotice ?? "-")")
		var pinnedOnDisk = try? store.load(id: applyID)
		check(pinnedOnDisk?.pinned == true && model.historyItems.first { $0.id == applyID }?.pinned == true, "pinned on disk and in the list")
		pinnedOnDisk?.pinned = false
		check(pinnedOnDisk == applied, "pinning changed nothing else in the manifest")

		// A global record whose snapshot is Finder's current defaults (read only): the confirmation offers to record it as
		// undone without touching Finder. It is only cancelled — the self-test never confirms a global undo (and
		// confirmUndo refuses it).
		var fakeGlobal = FinderPresetsOperation(kind: .applyGlobal, presetName: "selftest-global", roots: [])
		fakeGlobal.globalSnapshotFile = try? store.saveGlobalSnapshot(GlobalDefaultsWriter.snapshot(domain: GlobalDefaultsWriter.finderDomain), for: fakeGlobal)
		fakeGlobal.finishedAt = Date()
		try? store.save(fakeGlobal)
		model.prepareUndo(fakeGlobal.id)
		await waitUndo()
		if case .confirm(let global) = model.undoPhase {
			check(global.isGlobal && global.global?.alreadyRestored == true && global.recordsOnly && global.canConfirm,
			      "global confirmation: already as before, recorded only")
		} else {
			check(false, "global confirmation: \(model.undoPhase) \(model.historyNotice ?? "")")
		}
		model.cancelUndo()
		check(model.undoPhase == .idle, "cancelled")

		// Retention with a policy that keeps only what it must: the pinned apply, the undo of it (a kept operation), the
		// newest undoable folder operation (the later change of the root) and global one stay; the rest goes with its backups.
		guard let laterID = later?.id else { return false }
		let strict = RetentionPolicy(maxCount: 0, maxAge: 0, maxBytes: 0)
		let beforeCleanup = stored()
		let kept: Set<UUID> = [applyID, undoID, laterID, fakeGlobal.id]
		guard let cleanup = await model.runRetention(policy: strict) else { log("FAIL: retention failed: \(model.status)"); return false }
		check(stored() == kept, "kept after the cleanup: \(stored().count) records (expected the pinned one, its undo, the newest folder and global ones)")
		check(Set(cleanup.removed) == beforeCleanup.subtracting(kept) && !cleanup.removed.isEmpty && cleanup.failed.isEmpty,
		      "removed \(cleanup.removed.count) of \(beforeCleanup.count)")
		check(cleanup.removed.allSatisfy { !FileManager.default.fileExists(atPath: store.directory(for: $0).path) }, "removed records leave no folder")
		// Unpinned, the undone apply and its undo go too; the newest undoable ones stay.
		check(await model.setPinned(applyID, pinned: false), "unpin")
		_ = await model.runRetention(policy: strict)
		check(stored() == [laterID, fakeGlobal.id], "kept after unpinning: \(stored().count) records")
		await model.loadHistory()
		check(Set(model.historyItems.map(\.id)) == stored(), "the history shows what is left")
		log("retention: removed \(cleanup.removed.count) then \(beforeCleanup.count - cleanup.removed.count - 2), kept the newest undoable folder and global records")

		// "지우기…" with both records chosen (⇧/⌘-click), then "지우기": the records and their folders go, and no folder
		// changes — the root keeps the column view the later apply wrote.
		let left = stored()
		model.historySelected = Set(model.historyItems.map(\.id))
		model.askDeleteHistory(model.historySelected)
		check(model.pendingHistoryDelete?.scope == .chosen && Set(model.pendingHistoryDelete?.ids ?? []) == left,
		      "the delete confirmation covers the chosen records: \(String(describing: model.pendingHistoryDelete))")
		model.confirmDeleteHistory()
		for _ in 0..<100 where !(stored().isEmpty && model.historyItems.isEmpty) { try? await Task.sleep(for: .milliseconds(50)) }
		check(stored().isEmpty && left.allSatisfy { !FileManager.default.fileExists(atPath: store.directory(for: $0).path) },
		      "deleted records leave no folder: \(stored().count) left")
		check(model.historyItems.isEmpty && model.historySelected.isEmpty && model.historyNotice == nil,
		      "the history is empty after the delete: \(model.historyItems.count) rows, notice \(model.historyNotice ?? "-")")
		check(storedMatches(tree, column, model: model), "deleting the records changed no folder (the root keeps \(column.name))")
		log("delete: \(left.count) chosen records deleted with their backups, the root keeps its view")
		return ok
	}

	/// Step 10, through the calls the preset editor makes (beginEditPreset, savePresetEdit, cancelPresetEdit,
	/// beginNewPreset). Returns false (after logging why) when any check fails.
	private static func presetEditing(model: AppModel, first: Preset, second: Preset, targetPath: String,
	                                  createdPresets: inout Set<UUID>, treeRoots: @MainActor () -> [URL],
	                                  log: @MainActor (String) -> Void) async -> Bool {
		@MainActor func waitIdle() async { while model.isWorking { try? await Task.sleep(for: .milliseconds(100)) } }
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }
		let store = model.presetStore
		func onDisk(_ id: UUID) -> Preset? { (try? store.listReadable())?.presets.first { $0.id == id } }
		func fileData(_ id: UUID) -> Data? { try? Data(contentsOf: model.dirs.presets.appendingPathComponent("\(id.uuidString).json")) }
		func fileCount() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: model.dirs.presets.path)) ?? []).filter { $0.hasSuffix(".json") }.count }
		let c = URL(fileURLWithPath: targetPath).appendingPathComponent("C"), c1 = c.appendingPathComponent("C1")
		let cPath = FolderRule.normalize(c.path)
		guard let current = model.preset(second.id), let fileBefore = fileData(second.id) else {
			log("FAIL: the second preset is missing before editing")
			return false
		}
		model.selectedPresetID = first.id

		// "편집…" opens with the preset's values; unchanged, they are exactly the preset's settings.
		model.beginEditPreset(second.id)
		guard let opened = model.presetEditor else { log("FAIL: the editor did not open"); return false }
		check(opened.original == current && opened.name == current.name && !opened.isNew, "the editor opened with \(opened.name)")
		check(opened.check(others: model.presetsOtherThan(opened)).settings == current.settings, "the editor's values are the preset's")

		// The preview window opens with the editor and follows its draft (what the sheet sends on every change): a number
		// being typed is drawn clamped, a text that is not a number keeps the last valid value, a view, a grouping, a sort column and "유지" are drawn as chosen; closing
		// the editor closes it. (The sheet itself is not presented during the self-test; the draft is sent as it does.)
		let previewOK = await previewFollowsEditor(model: model, opened: opened, log: log)
		ok = ok && previewOK
		model.beginEditPreset(second.id)

		// A typed number outside Finder's range is saved as the nearest value it offers (text sizes whole first), and the
		// committed field shows it. Checked on the draft only (nothing is written here).
		let clamps: [(String, PresetDraft.Number, String, Double)] = [
			("icon size 600", .iconSize, "600", 512), ("icon size 8", .iconSize, "8", 16), ("icon text size 12.5", .iconTextSize, "12.5", 13),
			("list text size 17", .listTextSize, "17", 16), ("grid spacing 0", .gridSpacing, "0", 1)
		]
		for (what, number, typed, expected) in clamps {
			var clamped = opened
			clamped[number] = typed
			let settings = clamped.check(others: model.presetsOtherThan(clamped)).settings
			let saved: Double? = switch number {
			case .iconSize: settings?.icon.iconSize
			case .iconTextSize: settings?.icon.textSize
			case .gridSpacing: settings?.icon.gridSpacing
			case .listTextSize: settings?.list.textSize
			}
			check(saved == expected && clamped.committed[number] == PresetDraft.text(expected), "\(what): clamped to \(saved.map(PresetDraft.text) ?? "-")")
		}
		log("editor clamped: \(clamps.map { "\($0.0) → \(PresetDraft.text($0.3))" }.joined(separator: ", "))")

		// Values that cannot be saved are refused: nothing is written, the editor stays open with the reason.
		let refusals: [(String, (inout PresetDraft) -> Void)] = [
			("icon size abc", { $0.iconSize = "abc" }), ("icon size nan", { $0.iconSize = "nan" }), ("icon text size 12,5", { $0.iconTextSize = "12,5" }),
			("blank name", { $0.name = "   " }), ("direction without a column", { $0.sortColumn = nil; $0.sortAscending = true }),
			("list icon size 20", { $0.listIconSize = 20 })
		]
		for (what, change) in refusals {
			var bad = opened
			change(&bad)
			let saved = model.savePresetEdit(bad)
			check(!saved && model.presetEditor == bad && model.presetEditorProblem != nil && fileData(second.id) == fileBefore && model.preset(second.id) == current,
			      "\(what): refused, nothing written (\(model.presetEditorProblem ?? "-"))")
		}
		log("editor refused: \(refusals.map(\.0).joined(separator: ", "))")

		// "취소" writes nothing and changes nothing (not even the status line).
		let statusBefore = model.status
		var discarded = opened
		(discarded.name, discarded.viewStyle, discarded.iconSize) = ("discarded", .gallery, "200")
		model.presetEditor = discarded
		model.cancelPresetEdit()
		check(model.presetEditor == nil && model.presetEditorProblem == nil && fileData(second.id) == fileBefore
		      && model.preset(second.id) == current && model.status == statusBefore, "cancel changes nothing")

		// A name another preset has (ignoring case and spaces) is a warning only.
		var duplicate = opened
		duplicate.name = " \(first.name.uppercased()) "
		let duplicateCheck = duplicate.check(others: model.presetsOtherThan(duplicate))
		check(duplicateCheck.canSave && duplicateCheck.warnings.count == 1, "same name: a warning, not a refusal (\(duplicateCheck.warnings))")

		// The view control is the preset's view style: choosing a view (what the sheet's segments and ⌘0–⌘4 call) changes
		// only `viewStyle`; the values of the views not selected are kept and saved unchanged; "유지" saves no view style;
		// a slider sets its option, and a typed text that cannot be saved goes back when another view is chosen.
		model.beginEditPreset(second.id)
		guard var viewed = model.presetEditor else { log("FAIL: the editor did not open for the view control"); return false }
		(viewed.iconSize, viewed.arrangeBy, viewed.sortColumn, viewed.listTextSize, viewed.groupBy) = ("80", .kind, .name, "12", .dateAdded)
		for view in ViewSwitcher.choices {
			var before = viewed
			let reset = viewed.selectView(view)
			before.viewStyle = view
			check(viewed.viewStyle == view && viewed == before && reset.isEmpty, "choosing \(view?.rawValue ?? "keep") changes only the view style")
		}
		check(viewed.viewsWithValues == [.icon, .list] && viewed.hiddenViewsWithValues == [.icon, .list], "views with values: \(viewed.viewsWithValues.map(\.rawValue))")
		// The list view's text size set with its slider (from "유지"), then saved from list view: the icon values stay.
		viewed.selectView(.list)
		viewed.listTextSize = ""
		viewed.setFromSlider(.listTextSize, viewed.sliderPosition(.listTextSize))     // the slider only reports where it stands
		check(viewed.isKept(.listTextSize), "a slider that did not move leaves the option \"유지\"")
		viewed.setFromSlider(.listTextSize, 15.4)
		check(viewed.listTextSize == "15" && viewed.hiddenViewsWithValues == [.icon], "the list text size slider sets 15: \(viewed.listTextSize)")
		// An icon size typed in icon view that cannot be saved goes back to the preset's value when list view is chosen.
		viewed.selectView(.icon)
		viewed.iconSize = "600px"
		check(!viewed.check(others: model.presetsOtherThan(viewed)).canSave, "icon size 600px cannot be saved")
		check(viewed.selectView(.list) == [.iconSize] && viewed.iconSize == PresetDraft.text(current.settings.icon.iconSize),
		      "choosing list view puts the icon size back: \(viewed.iconSize)")
		viewed.iconSize = "80"
		var viewedExpected = current.settings
		viewedExpected.viewStyle = .list
		(viewedExpected.icon.iconSize, viewedExpected.icon.arrangeBy, viewedExpected.list.sortColumn, viewedExpected.list.textSize, viewedExpected.groupBy)
			= (80, .kind, .name, 15, .dateAdded)
		check(model.savePresetEdit(viewed), "save from list view: \(model.presetEditorProblem ?? "-")")
		check(onDisk(second.id)?.settings == viewedExpected.normalized(),
		      "saved from list view, the icon values are written unchanged: \(onDisk(second.id)?.settings as Any)")
		// "유지": saved without a view style, every other value kept.
		model.beginEditPreset(second.id)
		guard var kept = model.presetEditor else { log("FAIL: the editor did not open for \"유지\""); return false }
		check(kept.viewStyle == .list, "reopened on list view")
		kept.selectView(nil)
		viewedExpected.viewStyle = nil
		check(model.savePresetEdit(kept) && onDisk(second.id)?.settings == viewedExpected.normalized() && onDisk(second.id)?.settings.viewStyle == nil,
		      "\"유지\" saves no view style: \(onDisk(second.id)?.settings as Any)")
		// A slider-set icon size (from the preset's value, one step up) and column view.
		model.beginEditPreset(second.id)
		guard var slid = model.presetEditor else { log("FAIL: the editor did not open for the slider"); return false }
		slid.selectView(.icon)
		slid.setFromSlider(.iconSize, slid.sliderPosition(.iconSize) + 4)
		slid.setFromSlider(.gridSpacing, 33.3)
		slid.selectView(.column)
		(viewedExpected.viewStyle, viewedExpected.icon.iconSize, viewedExpected.icon.gridSpacing) = (.column, 84, 33)
		check(model.savePresetEdit(slid) && onDisk(second.id)?.settings == viewedExpected.normalized(),
		      "slider values saved from column view: \(onDisk(second.id)?.settings as Any)")
		log("view control: list keeps icon values, keep saves no view style, sliders set 15 / 84 / 33, an invalid hidden number is put back")

		// "저장" while the folders are being checked: saved, and the plan made from the old values is thrown away.
		model.beginEditPreset(second.id)
		guard var edited = model.presetEditor else { log("FAIL: the editor did not open again"); return false }
		edited.name = second.name + " 편집"
		edited.viewStyle = .list
		(edited.iconSize, edited.iconTextSize, edited.gridSpacing) = (" 96 ", "14", "40")
		(edited.arrangeBy, edited.labelOnBottom, edited.showItemInfo, edited.iconShowPreview) = (.dateAdded, false, true, false)
		(edited.sortColumn, edited.sortAscending, edited.listTextSize, edited.listIconSize) = (.name, true, "14", 16)
		(edited.listShowPreview, edited.useRelativeDates, edited.calculateAllSizes) = (false, false, true)
		edited.groupBy = .kind
		let expected = ViewSettings(
			viewStyle: .list,
			icon: IconViewSettings(iconSize: 96, textSize: 14, labelOnBottom: false, showItemInfo: true, showIconPreview: false, arrangeBy: .dateAdded, gridSpacing: 40),
			list: ListViewSettings(textSize: 14, iconSize: 16, sortColumn: .name, sortAscending: true, showIconPreview: false, useRelativeDates: false, calculateAllSizes: true),
			groupBy: .kind)
		model.prepareApply(to: treeRoots())
		let savedDuringCheck = model.savePresetEdit(edited)
		await waitIdle()
		check(savedDuringCheck && model.pendingApply == nil && model.status == AppModel.staleNote, "an edit saved while the folders are checked discards that plan: \(model.status)")

		// On disk: same ID and creation date, the new name and values. The list, the folder capsule and the row summary follow.
		guard let saved = onDisk(second.id) else { log("FAIL: the edited preset is not on disk"); return false }
		check(saved.createdAt == current.createdAt && saved.name == edited.name && saved.settings == expected && saved.updatedAt > current.updatedAt,
		      "preset file after the edit: \(saved.name) \(saved.settings)")
		check(model.preset(second.id) == saved && model.presetEditor == nil && model.presetEditorProblem == nil, "the list holds the saved preset")
		check(model.targets.first { $0.path == cPath }.flatMap { model.preset($0.presetID) }?.name == edited.name, "C's capsule shows the new name")
		check(PresetRow.summary(saved.settings).hasPrefix(Fmt.style(.list)), "the row summary follows: \(PresetRow.summary(saved.settings))")
		check(model.selectedPresetID == first.id, "editing keeps the selection")
		log("edited: \(saved.name) — \(PresetRow.summary(saved.settings))")
		// Saving without a change writes nothing.
		let savedData = fileData(second.id)
		model.beginEditPreset(second.id)
		check(model.presetEditor.map { model.savePresetEdit($0) } == true && fileData(second.id) == savedData && model.presetEditor == nil, "an unchanged save writes nothing")

		// The next apply writes the new values: C (assigned) and C1 (follows C).
		model.prepareApply(to: treeRoots())
		await waitIdle()
		guard let pending = model.pendingApply else { log("FAIL: nothing to apply after the edit: \(model.status)"); return false }
		check(pending.presetChanges.contains(.init(name: saved.name, count: 2)), "per-preset counts after the edit: \(pending.presetChanges)")
		model.confirmApply()
		await waitIdle()
		model.askRelaunch = false
		check(storedMatches(c, saved, model: model) && storedMatches(c1, saved, model: model), "C and C1 hold the edited values in their parent .DS_Store")
		// The grouping is a `GRP0` record with Finder's own string, next to the view records.
		let groupings = [c, c1].map { folder -> String? in
			guard let loc = try? ParentStoreLocator.locate(folder) else { return nil }
			return (try? StoreEditor.managedRecords(at: loc.storeURL, key: loc.key))??["GRP0"]?.stringValue
		}
		check(groupings == ["Kind", "Kind"], "C and C1 are grouped by kind (GRP0 \(groupings))")
		log("apply after the edit: \(model.status) · GRP0 \(groupings.map { $0 ?? "-" })")

		// A preset file changed elsewhere while the editor is open is never overwritten.
		model.beginEditPreset(second.id)
		var outside = saved
		outside.settings.icon.iconSize = 128
		try? store.save(outside)
		if var late = model.presetEditor {
			late.iconSize = "200"
			check(!model.savePresetEdit(late) && model.presetEditorProblem == PresetDraft.CommitError.changedOnDisk.message
			      && onDisk(second.id)?.settings.icon.iconSize == 128, "a file changed elsewhere is not overwritten: \(model.presetEditorProblem ?? "-")")
		}
		model.cancelPresetEdit()
		// Reopened, the editor starts from the file as it is now (the list was read again).
		model.beginEditPreset(second.id)
		check(model.presetEditor?.iconSize == "128" && model.preset(second.id)?.settings.icon.iconSize == 128,
		      "reopened after an outside change, the editor shows it: \(model.presetEditor?.iconSize ?? "-")")
		model.cancelPresetEdit()

		// "새 프리셋…": nothing on disk before "만들기"; "취소" leaves nothing; "만들기" writes it and selects it.
		let countBefore = fileCount()
		model.beginNewPreset()
		check(model.presetEditor.map { $0.isNew && $0.previewSettings == ViewSettings() && !$0.name.isEmpty } == true && fileCount() == countBefore,
		      "a new preset is not on disk before it is created")
		model.cancelPresetEdit()
		check(fileCount() == countBefore && model.presets.count == countBefore, "cancelling a new preset leaves nothing")
		model.beginNewPreset()
		guard var fresh = model.presetEditor else { log("FAIL: the new preset editor did not open"); return false }
		(fresh.name, fresh.viewStyle, fresh.iconSize) = ("selftest-new", .gallery, "72")
		check(model.savePresetEdit(fresh), "create: \(model.presetEditorProblem ?? "-")")
		let created = model.presets.first { $0.name == "selftest-new" }
		if let created { createdPresets.insert(created.id) }
		check(created?.settings == ViewSettings(viewStyle: .gallery, icon: IconViewSettings(iconSize: 72)) && model.selectedPresetID == created?.id
		      && created.map { onDisk($0.id) == $0 } == true && fileCount() == countBefore + 1, "created, selected and on disk: \(model.status)")
		log("new preset: \(created?.name ?? "-") — \(model.status)")
		return ok
	}

	/// Step 10's preview part: the preview window opens with the editor (unless the user hid it with the eye button),
	/// follows the draft through a few edits, and closes with the editor. Returns false (after logging why) on a failure.
	private static func previewFollowsEditor(model: AppModel, opened: PresetDraft, log: @MainActor (String) -> Void) async -> Bool {
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }
		let preview = PresetPreviewController.shared
		// MainView opens it when the model's draft changes (next turn of the main actor).
		for _ in 0..<20 where !preview.isEditing { try? await Task.sleep(for: .milliseconds(50)) }
		check(preview.isEditing && preview.token == opened.token, "the preview follows the editor that opened")
		check(preview.isVisible == preview.shown, "the preview window is \(preview.isVisible ? "shown" : "hidden") (eye button: \(preview.shown))")
		// The rest positions of the sliders are Finder's current defaults, the values the preview draws for "유지".
		let defaults = model.globals.effectiveSettings
		check(opened.restPositions[.iconSize] == defaults.icon.iconSize && opened.restPositions[.listTextSize] == defaults.list.textSize,
		      "the sliders rest on Finder's defaults: \(opened.restPositions)")
		var draft = opened
		draft.selectView(.icon)
		draft.iconSize = "64"
		preview.follow(draft)
		func current() -> PresetPreview? { preview.preview() }
		func iconSize() -> Double? { if case .icon(let g)? = current()?.content { g.iconSize } else { nil } }
		check(current()?.view == .icon && iconSize() == 64, "icon view, icon size 64")
		for typed in ["1", "12"] {
			draft.iconSize = typed
			preview.follow(draft)
			check(iconSize() == 16, "typing \(typed) draws the clamped icon size 16: \(iconSize() ?? -1)")
		}
		draft.iconSize = "128"
		(draft.groupBy, draft.arrangeBy) = (.kind, .name)
		preview.follow(draft)
		if case .icon(let g)? = current()?.content {
			check(g.iconSize == 128 && g.scale < 1 && g.iconSide > 64 && !g.headers.isEmpty && current()?.scaleBadge != nil,
			      "icon size 128 drawn smaller (\(Int(g.iconSide))pt), grouped by kind: \(g.headers.map(\.title))")
			// What is drawn is the top of the order: the first group first.
			check(g.headers.first?.title == PresetPreview.groupKey(PreviewSample.folder(now: preview.now, calendar: .current)[0], .kind,
			      format: PreviewFormat(locale: AppLanguage.locale, calendar: .current, now: preview.now)).title, "the first kind group is drawn first")
		} else {
			check(false, "not an icon view")
		}
		draft.iconSize = "128x"
		preview.follow(draft)
		check(iconSize() == 128, "typing 128x (not a number) keeps the last valid icon size: \(iconSize() ?? -1)")
		draft.selectView(.list)
		draft.sortColumn = .size
		draft.sortAscending = nil
		preview.follow(draft)
		if case .list(let t)? = current()?.content {
			let expected = PreviewDefaults(model.globals).ascending(for: .size)
			check(t.columns.first { $0.id == .size }?.ascending == expected, "the size column's own direction (\(expected)) is drawn")
		} else {
			check(false, "not a list view")
		}
		draft.selectView(nil)
		draft.name = "preview name"
		preview.follow(draft)
		check(current()?.viewKept == true && current()?.view == (model.globals.preferredViewStyle ?? .icon), "\"유지\" draws Finder's default view")
		check(preview.window.map { $0.title.contains("preview name") } ?? !preview.shown, "the window's title follows the name")
		// A draft of another opening (a sheet still closing) is ignored.
		var stale = draft
		stale.token = UUID()
		stale.name = "stale"
		preview.follow(stale)
		check(preview.tracker?.name == "preview name", "a stale sheet does not change the preview")
		model.cancelPresetEdit()
		for _ in 0..<20 where preview.isEditing { try? await Task.sleep(for: .milliseconds(50)) }
		check(!preview.isEditing && !preview.isVisible, "the preview closes with the editor")
		log("preview window: opened with the editor, followed 8 edits (clamped number, last valid number, view, grouping, sort column, \"유지\"), closed with it")
		return ok
	}

	/// Step 11, through `AppModel.perform` (what FinderServiceProvider calls) with `ServiceItems.read` on a private
	/// pasteboard: "…에 폴더 추가" adds a folder once and reports files, web links, text and the home folder; a request with
	/// no folder does nothing; "…로 프리셋 만들기" makes one preset per folder (a folder sent twice counts once) with the
	/// folder's settings; "…로 적용…" adds and selects exactly its folders and opens the confirmation for them without
	/// writing; while that confirmation (or a task) is up, another apply request only selects. Returns false (after logging
	/// why) when any check fails.
	private static func finderServices(model: AppModel, source: URL, first: Preset, targetPath: String,
	                                   createdPresets: inout Set<UUID>, createdTargets: inout Set<String>,
	                                   log: @MainActor (String) -> Void) async -> Bool {
		@MainActor func waitIdle() async { while model.isWorking { try? await Task.sleep(for: .milliseconds(100)) } }
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }
		let fm = FileManager.default
		let tree = URL(fileURLWithPath: targetPath)
		let b = tree.appendingPathComponent("B"), bPath = FolderRule.normalize(b.path)
		// A folder no apply has touched: the apply service's confirmation must include it.
		let fresh = tree.appendingPathComponent("S service")
		try? fm.createDirectory(at: fresh, withIntermediateDirectories: false)
		let freshPath = FolderRule.normalize(fresh.path)
		defer { try? fm.removeItem(at: fresh) }
		let pb = NSPasteboard(name: NSPasteboard.Name("com.hyunseop.FinderPresets.selftest-\(UUID().uuidString)"))
		defer { pb.releaseGlobally() }
		func send(_ service: FinderService, _ objects: [NSPasteboardWriting]) -> String? {
			pb.clearContents()
			pb.writeObjects(objects)
			return model.perform(service, ServiceItems.read(pb))
		}
		let file = b.appendingPathComponent("f1.txt") as NSURL
		let link = URL(string: "https://example.com/finder-presets-selftest")! as NSURL
		model.errorMessage = nil

		// "…에 폴더 추가": B once (sent twice), the rest reported, nothing else listed.
		let countBefore = model.targets.count
		let added = send(.addFolders, [b as NSURL, b as NSURL, file, link, fm.homeDirectoryForCurrentUser as NSURL, "text" as NSString])
		createdTargets.insert(bPath)
		check(added == nil && model.targets.count == countBefore + 1 && model.targets.last?.path == bPath, "add service: B added once (\(model.status))")
		check(savedTargets(model).contains { $0.path == bPath }, "add service: B saved in targets.json")
		let alert = model.errorMessage ?? ""
		check(alert.contains("f1.txt") && alert.contains("https://example.com/finder-presets-selftest") && alert.contains(AppModel.homeRefusal(["~"]).prefix(12)),
		      "add service: ignored items and the home folder reported: \(alert)")
		model.errorMessage = nil
		let again = send(.addFolders, [b as NSURL])
		check(again == nil && model.targets.count == countBefore + 1 && model.status == AppModel.additionNote(FolderAddition(alreadyListed: [bPath], inList: [bPath])),
		      "add service: a listed folder is not added again (\(model.status))")
		let nothing = send(.addFolders, [file, link])
		check(nothing != nil && model.targets.count == countBefore + 1, "a request without a folder does nothing: \(nothing ?? "-")")
		model.errorMessage = nil
		log("add service: \(model.targets.map(\.name))")

		// "…로 프리셋 만들기": two presets (the source was sent twice), each with its folder's settings; the last is selected.
		let presetsBefore = Set(model.presets.map(\.id))
		let made = send(.makePresets, [source as NSURL, b as NSURL, source as NSURL])
		let new = model.presets.filter { !presetsBefore.contains($0.id) }
		createdPresets.formUnion(new.map(\.id))
		let fromSource = new.first { $0.name.hasPrefix(source.lastPathComponent + " ") }
		let fromB = new.first { $0.name == "B" || $0.name.hasPrefix("B ") }
		check(made == nil && new.count == 2 && fromSource != nil && fromB != nil, "preset service: two presets (\(new.map(\.name)))")
		check(fromSource?.settings == first.settings, "preset service: the source's preset holds its settings")
		if let fromB, let loc = try? ParentStoreLocator.locate(b), let state = try? Planner.readState(at: loc, globals: model.globals) {
			check(fromB.settings == (state.hasExplicitRecords ? state.explicit : state.effective), "preset service: B's preset holds B's settings")
		}
		check(model.selectedPresetID == fromB?.id && model.errorMessage == nil, "preset service: the last one is selected")
		log("preset service: \(model.status)")

		// "…로 적용…": the fresh folder joins the list, exactly it and B are selected, the confirmation holds both — nothing written.
		model.selectedPresetID = first.id
		let storeURL = tree.appendingPathComponent(".DS_Store")
		let storeBefore = try? Data(contentsOf: storeURL)
		let applied = send(.apply, [fresh as NSURL, b as NSURL])
		createdTargets.insert(freshPath)
		await waitIdle()
		check(applied == nil && model.selectedTargets == [freshPath, bPath] && model.targets.filter { $0.path == freshPath }.count == 1,
		      "apply service: added and selected (\(model.selectedTargets))")
		guard let pending = model.pendingApply else {
			log("FAIL: apply service: no confirmation (\(model.status))")
			return false
		}
		check(Set(pending.roots.map { FolderRule.normalize($0.path) }) == [freshPath, bPath]
		      && pending.plan.changes.contains { FolderRule.normalize($0.folder.path) == freshPath },
		      "apply service: the confirmation holds both folders and changes the fresh one (\(pending.roots.map(\.lastPathComponent)))")
		// While the confirmation is up another apply request only selects; it neither replaces nor invalidates the confirmation.
		let changes = pending.changeCount
		let blocked = send(.apply, [b as NSURL])
		check(blocked == nil && model.pendingApply?.changeCount == changes && model.selectedTargets == [bPath]
		      && model.planStamp.sameForFolders(as: pending.stamp) && model.status.contains(AppModel.applyServiceBlocker(isWorking: false, dialogOpen: true) ?? "?"),
		      "apply service while a confirmation is up: \(model.status)")
		model.cancelPendingApply()
		check(model.status == AppModel.cancelNote && (try? Data(contentsOf: storeURL)) == storeBefore, "apply service: nothing written before \"적용\"")
		// While a task runs, the same.
		model.isWorking = true
		let busy = send(.apply, [fresh as NSURL])
		model.isWorking = false
		check(busy == nil && model.pendingApply == nil && model.selectedTargets == [freshPath]
		      && model.status.contains(AppModel.applyServiceBlocker(isWorking: true, dialogOpen: false) ?? "?"), "apply service while busy: \(model.status)")
		log("apply service: confirmation for \(pending.roots.map(\.lastPathComponent)), \(changes) folder(s), cancelled")
		return ok
	}

	/// Step 12. The model path the quick preset service takes after Finder answered (`quickApply(to:)`, also with the
	/// service's `checksDialogs`: a refusal left in the alert does not stop the next press). The star lives in memory while
	/// the self-test runs (`QuickPresetSetting.forThisLaunch`), and Finder is never restarted.
	private static func quickPreset(model: AppModel, first: Preset, targetPath: String, log: @MainActor (String) -> Void) async -> Bool {
		@MainActor func waitIdle() async { while model.isWorking { try? await Task.sleep(for: .milliseconds(100)) } }
		var ok = true
		func check(_ condition: Bool, _ what: String) { if !condition { log("FAIL: \(what)"); ok = false } }
		let fm = FileManager.default
		let folder = URL(fileURLWithPath: targetPath).appendingPathComponent("Q quick")
		let sub = folder.appendingPathComponent("Q1")
		try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: folder) }
		let folderPath = FolderRule.normalize(folder.path)
		guard let quick = model.preset(first.id) else { log("FAIL: quick preset: the first preset is gone"); return false }
		model.errorMessage = nil

		// No star: refused before anything is planned; nothing written. The alert holds the refusal as one the next press
		// closes; pressed again, the new refusal replaces it.
		if let starred = model.quickPresetID { model.toggleQuickPreset(starred) }
		model.quickApply(to: folderPath)
		await waitIdle()
		model.quickApply(to: folderPath)
		await waitIdle()
		check(model.status == QuickApplyRefusal.noQuickPreset.message && model.errorMessage == model.status
		      && model.errorAlert.content == .quickRefusals && !storedMatches(folder, quick, model: model),
		      "quick preset without a star: \(model.status) — alert \(model.errorAlert.content): \(model.errorMessage ?? "-")")

		// The star, then the same folder the way the service goes on once Finder has answered (`checksDialogs`), with that
		// refusal still in the alert: the press closes the alert and goes on. Written at once, one record, "되돌리기…" for
		// it, no confirmation, no restart.
		model.toggleQuickPreset(quick.id)
		check(model.quickPresetID == quick.id && model.quickPresetSetting.id == quick.id, "quick preset: the star is kept")
		model.quickApply(to: folderPath, checksDialogs: true)
		await waitIdle()
		log("quick preset: \(model.status)")
		let name = Fmt.name(folder.lastPathComponent)
		check(model.status == String(localized: "완료: \(name)에 \"\(Fmt.name(quick.name))\"을(를) 적용했습니다."), "quick preset: applied without restarting Finder: \(model.status)")
		check(storedMatches(folder, quick, model: model), "quick preset: the folder holds the preset")
		check(!fm.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path), "quick preset: the subfolder is untouched")
		check(model.pendingApply == nil && !model.askRelaunch && model.errorMessage == nil,
		      "quick preset: no confirmation, no restart question, the refusal alert closed: \(model.errorMessage ?? "-")")
		guard let opID = model.undoShortcutID, let op = try? model.operationStore.load(id: opID) else {
			log("FAIL: quick preset: no \"되돌리기…\" or no record")
			return false
		}
		check(op.kind == .apply && op.roots.map(FolderRule.normalize) == [folderPath] && op.presetName == quick.name
		      && op.entries.count == 1 && op.entries.first?.status == .changed, "quick preset: the record (\(op.roots), \(op.entries.map(\.status)))")

		// Pressed again: already the same, nothing recorded, Finder left alone.
		model.quickApply(to: folderPath)
		await waitIdle()
		check(model.status == String(localized: "\(name)은(는) 이미 \"\(Fmt.name(quick.name))\"과 같아 바꿀 것이 없습니다. Finder는 다시 시작하지 않았습니다.")
		      && model.undoShortcutID == nil, "quick preset pressed again: \(model.status)")
		log("quick preset: \(op.id.uuidString.prefix(8)) recorded (the refusal alert closed by that press), second press unchanged")
		return ok
	}

	/// The status line of an apply that finds nothing to change ("변경할 폴더가 없습니다. 이미 동일 N개 …"), in the app's
	/// language: it starts with the model's note for one of the numbers it names.
	private static func reportsNoChange(_ status: String) -> Bool {
		let numbers = status.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
		return numbers.contains { status.hasPrefix(AppModel.noChangeNote($0)) }
	}

	/// File level: the folder's parent .DS_Store holds explicit records equal to the preset.
	private static func storedMatches(_ folder: URL, _ preset: Preset, model: AppModel) -> Bool {
		guard let loc = try? ParentStoreLocator.locate(folder), let state = try? Planner.readState(at: loc, globals: model.globals) else { return false }
		return state.hasExplicitRecords && state.explicit.differences(to: preset.settings).isEmpty
	}

	/// What the data folder already holds that a self-test must not touch: any preset file, and a targets.json that is
	/// unreadable or lists folders. Empty = safe to start.
	private static func dataFolderContents(_ model: AppModel) -> [String] {
		let fm = FileManager.default
		var found: [String] = []
		let presetFiles = ((try? fm.contentsOfDirectory(atPath: model.dirs.presets.path)) ?? []).filter { !$0.hasPrefix(".") }
		if !presetFiles.isEmpty { found.append("presets/ 파일 \(presetFiles.count)개") }
		let targetsFile = model.dirs.root.appendingPathComponent("targets.json")
		if fm.fileExists(atPath: targetsFile.path) {
			if let list = try? JSONCoding.decoder().decode([TargetFolder].self, from: Data(contentsOf: targetsFile)) {
				if !list.isEmpty { found.append("대상 폴더 \(list.count)개: \(list.map(\.name))") }
			} else {
				found.append("읽지 못한 targets.json")
			}
		}
		return found
	}

	private static func savedTargets(_ model: AppModel) -> [TargetFolder] {
		let url = model.dirs.root.appendingPathComponent("targets.json")
		return (try? JSONCoding.decoder().decode([TargetFolder].self, from: Data(contentsOf: url))) ?? []
	}
}
#endif

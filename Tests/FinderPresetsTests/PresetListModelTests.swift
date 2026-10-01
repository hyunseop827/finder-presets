import Foundation
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// The preset list's calls on the model, on an `AppModel` with a temporary data folder and the star kept in memory (never
/// the app's own data folder or defaults): deleting a preset clears its folders' assignments also while another preset
/// file cannot be read, a rename starts from the file as it is now, several folders become presets in one go (one alert
/// for those that fail, one status line, names unique ignoring case like an imported file's), and the words of a
/// "시스템 전체에 적용" that stopped, and a folder row's tooltip for a preset that is not loaded. Nothing here touches Finder.
@MainActor @Suite struct PresetListModelTests {
	/// A temporary folder: the data folder (AppData) and folders to make presets from (Tree); removed by `cleanUp`.
	struct Env {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-preset-list-\(UUID().uuidString)")
		var dirs: AppDirectories { AppDirectories(root: base.appendingPathComponent("AppData")) }
		var store: PresetStore { PresetStore(dirs: dirs) }
		var targetsURL: URL { dirs.root.appendingPathComponent("targets.json") }

		@MainActor func model() -> AppModel { AppModel(dirs: dirs, quickPresetSetting: .inMemory()) }

		func folder(_ path: String) throws -> URL {
			let url = base.appendingPathComponent("Tree").appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			return url
		}

		func savedTargets() throws -> [TargetFolder] {
			try JSONCoding.decoder().decode([TargetFolder].self, from: Data(contentsOf: targetsURL))
		}

		func cleanUp() { try? FileManager.default.removeItem(at: base) }
	}

	/// The confirmation promises that the deleted preset's folders become "선택한 프리셋 사용": also while another preset
	/// file cannot be read, when the reload leaves the assignments to presets it does not list alone. While targets.json
	/// itself cannot be read, a delete never touches it.
	@Test func deletingAPresetClearsItsFoldersAlsoWhileAnotherFileIsUnreadable() throws {
		let env = Env()
		defer { env.cleanUp() }
		let gone = Preset(name: "Gone", settings: ViewSettings(viewStyle: .list))
		let kept = Preset(name: "Kept", settings: ViewSettings(viewStyle: .icon))
		try env.store.save(gone)
		try env.store.save(kept)
		try Data("not a preset".utf8).write(to: env.dirs.presets.appendingPathComponent("broken.json"))
		// A folder assigned to the preset in the unreadable file, say: it stays assigned.
		let unlisted = UUID()
		let targets = [TargetFolder(path: "/tmp/a", presetID: gone.id), TargetFolder(path: "/tmp/b", presetID: kept.id),
		               TargetFolder(path: "/tmp/c", presetID: unlisted)]
		try JSONCoding.encoder().encode(targets).write(to: env.targetsURL)
		let model = env.model()
		#expect(model.presets.map(\.name) == ["Gone", "Kept"] && model.hasUnreadableData)
		model.deletePreset(gone.id)
		let expected: [UUID?] = [nil, kept.id, unlisted]
		#expect(model.targets.map(\.presetID) == expected)
		#expect(try env.savedTargets().map(\.presetID) == expected)
		#expect(model.presets.map(\.name) == ["Kept"] && model.selectedPresetID == kept.id)

		let unreadable = Data("not a list".utf8)
		try unreadable.write(to: env.targetsURL)
		let again = env.model()
		again.deletePreset(kept.id)
		#expect(again.presets.isEmpty)
		#expect(try Data(contentsOf: env.targetsURL) == unreadable)
		#expect(try FileManager.default.contentsOfDirectory(atPath: env.dirs.root.path).filter { $0.hasPrefix("targets.json") } == ["targets.json"])
	}

	/// The rename alert holds the row's copy of the preset: a change made to its file meanwhile (`finder-presets
	/// preset-set`, by hand) is kept, and a file removed meanwhile is not written again.
	@Test func aRenameStartsFromTheFileAsItIsNow() throws {
		let env = Env()
		defer { env.cleanUp() }
		let preset = Preset(name: "Photos", settings: ViewSettings(viewStyle: .icon))
		try env.store.save(preset)
		let model = env.model()
		let row = try #require(model.preset(preset.id))
		var changed = row
		changed.settings = ViewSettings(viewStyle: .list)
		try env.store.save(changed)
		model.rename(row, to: " Pictures ")
		let saved = try #require(try env.store.list().first { $0.id == preset.id })
		#expect(saved.name == "Pictures" && saved.settings == changed.settings && model.preset(preset.id)?.name == "Pictures")
		#expect(model.status == String(localized: "프리셋 \"\(Fmt.name("Photos"))\"의 이름을 \"\(Fmt.name("Pictures"))\"(으)로 바꿨습니다."))

		try env.store.delete(id: preset.id)
		model.rename(row, to: "Again")
		#expect(try env.store.list().isEmpty && model.preset(preset.id) == nil)
		#expect(model.errorMessage == PresetDraft.CommitError.missing.message)
	}

	/// A drop of several folders on the preset list and the Finder service: one preset per folder, named after it and
	/// unique ignoring case (like the editor and `finder-presets`), the last one selected; one alert names each folder
	/// that failed, one status line every preset made. One folder reads like the open panel's "이 폴더처럼". An imported
	/// file whose name is taken in another case gets a number too.
	@Test func severalFoldersBecomePresetsAtOnceWithNamesUniqueIgnoringCase() throws {
		let env = Env()
		defer { env.cleanUp() }
		try env.store.save(Preset(name: "Photos", settings: ViewSettings(viewStyle: .icon)))
		let model = env.model()
		let lower = try env.folder("one/photos"), upper = try env.folder("two/PHOTOS"), docs = try env.folder("Docs")
		#expect(model.makePresets(from: [lower, URL(fileURLWithPath: "/"), upper, docs]) == nil)
		let names = ["photos 2", "PHOTOS 3", "Docs"]
		let made = names.compactMap { name in model.presets.first { $0.name == name } }
		#expect(made.count == 3 && model.presets.count == 4 && model.selectedPresetID == made.last?.id)
		#expect(model.errorMessage == String(localized: "프리셋을 만들지 못한 폴더:") + "\n/: " + ErrorText.describe(LocatorError.rootFolder))
		#expect(model.status.hasPrefix(String(localized: "폴더로 프리셋 \(names.count)개를 만들었습니다: \(Fmt.name(names.joined(separator: ", ")))")))

		model.errorMessage = nil
		let other = try env.folder("Other")
		#expect(model.makePresets(from: [other]) == nil && model.selectedPreset?.name == "Other")
		#expect(model.status == String(localized: "\(Fmt.name("Other"))에는 고유 설정이 없어 현재 표시되는 값(Finder 기본값)을 저장했습니다."))
		let reply = model.makePresets(from: [URL(fileURLWithPath: "/")])
		#expect(reply == String(localized: "폴더로 프리셋을 만들지 못했습니다.") && model.status == reply && model.presets.count == 5)

		let file = env.base.appendingPathComponent("photos.json")
		try env.store.export(Preset(name: "photos", settings: ViewSettings(viewStyle: .column)), to: file)
		model.importPresetFiles([file])
		#expect(model.selectedPreset?.name == "photos 4")
	}

	/// A folder row's preset tag: a folder assigned to a preset that is not loaded (its file cannot be read, say) is
	/// skipped on apply, so its tooltip says so, not "no preset of its own" and the preset selected on the left.
	@Test func aFolderWhosePresetIsMissingSaysItIsSkipped() throws {
		let env = Env()
		defer { env.cleanUp() }
		let kept = Preset(name: "Kept", settings: ViewSettings(viewStyle: .icon))
		try env.store.save(kept)
		let missing = TargetFolder(path: "/tmp/a", presetID: UUID()), own = TargetFolder(path: "/tmp/b", presetID: kept.id)
		let none = TargetFolder(path: "/tmp/c")
		try JSONCoding.encoder().encode([missing, own, none]).write(to: env.targetsURL)
		let model = env.model()
		model.selectedPresetID = kept.id
		func help(_ target: TargetFolder) -> String { PresetTag.help(target, assigned: model.preset(target.presetID), model: model) }
		#expect(help(missing) == String(localized: "지정한 프리셋을 찾을 수 없어 적용할 때 건너뜁니다"))
		#expect(help(own) == String(localized: "이 폴더에는 프리셋 \"\(kept.name)\"을(를) 적용합니다."))
		#expect(help(none) == String(localized: "지정한 프리셋이 없습니다: \(model.fallbackNote(for: none)) 다른 프리셋을 고르면 이 폴더에는 그 프리셋이 적용됩니다."))
		#expect(model.fallbackNote(for: none) == String(localized: "왼쪽에서 선택한 프리셋(\(Fmt.name(kept.name)))을 씁니다."))
	}

	/// "시스템 전체에 적용" stopped at Finder's defaults after the home folders' write: only folders it wrote are named
	/// with where to undo them, and failed folders are counted. A write that wrote none never says "0개는 이미 변경됨".
	@Test func aStoppedSystemApplyNamesOnlyWhatItWrote() {
		func home(_ statuses: [EntryStatus]) -> OperationSummary {
			FinderPresetsOperation(kind: .apply, roots: ["/h"], entries: statuses.enumerated().map { i, status in
				OperationEntry(folderPath: "/h/\(i)", storePath: "/h/.DS_Store", key: "\(i)", before: nil, after: nil, status: status)
			}).summary
		}
		let reason = "x", stopped = String(localized: "중단: \(reason)")
		let undoHint = String(localized: "\"기록\"(⌘Y)")

		let none = AppModel.systemApplyStopNote(reason, home: home([.failed, .failed, .skippedMatching]), homeRequested: true)
		#expect(none.status == stopped + " · " + String(localized: "홈 폴더는 바꾸지 않음") + " · " + String(localized: "홈 폴더 \(2)개 실패"))
		#expect(none.alert == String(localized: "Finder 기본 보기는 바꾸지 못했습니다: \(reason)\n\n홈 폴더도 바꾸지 않았습니다."))
		#expect(!none.status.contains(undoHint) && !none.alert.contains(undoHint))

		let some = AppModel.systemApplyStopNote(reason, home: home([.changed, .failed, .positionsOnly]), homeRequested: true)
		#expect(some.status == stopped + " · " + String(localized: "홈 폴더 \(1)개는 이미 변경됨 (되돌리기: \"기록\"(⌘Y))") + " · "
			+ HistoryText.positionsOnlyFolders(1, undo: false) + " · " + String(localized: "홈 폴더 \(1)개 실패"))
		#expect(some.alert.contains(undoHint))

		let positions = AppModel.systemApplyStopNote(reason, home: home([.positionsOnly]), homeRequested: true)
		let written = HistoryText.positionsOnlyFolders(1, undo: false)
		#expect(positions.status == stopped + " · " + String(localized: "이미 씀: \(written) (되돌리기: \"기록\"(⌘Y))") && positions.alert.contains(undoHint))

		let notRun = AppModel.systemApplyStopNote(reason, home: nil, homeRequested: true)
		#expect(notRun.status == stopped + " · " + String(localized: "홈 폴더는 바꾸지 않음") && notRun.alert == reason)
		let noHome = AppModel.systemApplyStopNote(reason, home: nil, homeRequested: false)
		#expect(noHome.status == stopped && noHome.alert == reason)
	}
}

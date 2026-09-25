import Foundation
import Testing
@testable import FinderPresetsCore

@Suite struct GlobalDefaultsTests {
	/// A throwaway CFPreferences domain `com.hyunseop.finder-presets.test-<uuid>`, addressed by absolute path so cfprefsd keeps
	/// its plist inside a temporary directory and nothing lands in ~/Library/Preferences (a bundle-id domain leaves an
	/// empty plist behind because cfprefsd flushes asynchronously). Never Finder's: the preconditions are the last line of defence.
	struct TestDomain {
		let directory: URL
		let name: String

		init() {
			directory = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-prefs-\(UUID().uuidString)")
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			name = directory.appendingPathComponent("com.hyunseop.finder-presets.test-\(UUID().uuidString)").path
			precondition(name != "com.apple.finder")
			precondition(name != GlobalDefaultsWriter.finderDomain)
			precondition(!name.contains("com.apple.finder"))
		}

		var plistURL: URL { URL(fileURLWithPath: name + ".plist") }
		func style() -> String? { GlobalDefaultsWriter.readViewStyle(domain: name) }
		func svs() -> [String: Any]? { GlobalDefaultsWriter.readStandardViewSettings(domain: name) }

		/// Removes both keys this app writes, then the directory holding the domain's plist.
		func cleanup() {
			precondition(name != "com.apple.finder")
			precondition(URL(fileURLWithPath: name).lastPathComponent.hasPrefix("com.hyunseop.finder-presets.test-"))
			for key in [GlobalDefaultsWriter.viewStyleKey, GlobalDefaultsWriter.standardViewSettingsKey] {
				CFPreferencesSetAppValue(key as CFString, nil, name as CFString)
			}
			CFPreferencesAppSynchronize(name as CFString)
			try? FileManager.default.removeItem(at: directory)
		}
	}

	/// Records the domain's view style at each lifecycle call, so the test can prove that nothing was
	/// written before the quit and everything was written before the launch.
	final class FakeFinder: FinderLifecycle, @unchecked Sendable {
		let domain: String
		var quitSucceeds = true
		var launchSucceeds = true
		/// Runs at each launch, after it is recorded (e.g. Finder writing other values back).
		var onLaunch: (() -> Void)?
		private var log: [String] = []
		private var running = true
		private let lock = NSLock()

		init(domain: String) { self.domain = domain }

		var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
		func reset() { lock.lock(); log = []; lock.unlock() }
		var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

		private func record(_ phase: String) {
			let style = GlobalDefaultsWriter.readViewStyle(domain: domain) ?? "nil"
			lock.lock(); log.append("\(phase):\(style)"); lock.unlock()
		}

		func quit() -> Bool {
			record("quit")
			lock.lock(); if quitSucceeds { running = false }; lock.unlock()
			return quitSucceeds
		}
		func launch() -> Bool {
			record("launch")
			onLaunch?()
			lock.lock(); running = launchSucceeds; lock.unlock()
			return launchSucceeds
		}

		/// Finder's windows (`FinderWindows`): with `windows` set, the read is recorded as "windows" and `reopen` as
		/// "reopen:A,B" (the names in the order asked); without it the fake has none and records nothing about them.
		var windows: [URL]?
		func openWindowFolders() -> [URL] {
			guard let windows else { return [] }
			lock.lock(); log.append("windows"); lock.unlock()
			return windows
		}
		func reopen(_ folders: [URL]) -> [URL] {
			lock.lock(); log.append("reopen:" + folders.map(\.lastPathComponent).joined(separator: ",")); lock.unlock()
			return folders
		}
	}

	static func same(_ a: [String: Any]?, _ b: [String: Any]) -> Bool {
		guard let a else { return false }
		return (a as NSDictionary).isEqual(b as NSDictionary)
	}

	static func tempDir(_ prefix: String) -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
	}

	// MARK: (a) plannedValues

	@Test func plannedValuesMergeTypedValuesAndPreserveOtherKeys() throws {
		// Everything string-typed, the way CFPreferences handed Finder's values back.
		let current: [String: Any] = [
			"IconViewSettings": ["iconSize": "64", "textSize": "12", "labelOnBottom": "1", "viewOptionsVersion": "1", "gridOffsetX": "0", "customKey": "keep"],
			"ExtendedListViewSettingsV2": ["textSize": "13", "sortColumn": "name", "useRelativeDates": "1", "columns": [
				["identifier": "name", "ascending": "1", "width": "300", "visible": "1"],
				["identifier": "dateModified", "ascending": "1", "width": "181", "visible": "1"]]],
			"ListViewSettings": ["textSize": "13", "sortColumn": "name", "columns": ["name": ["index": "0", "ascending": "1", "width": "300", "visible": "1"]]],
			"GalleryViewSettings": ["arrangeBy": "name", "iconSize": "48"]
		]
		let settings = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 88), list: ListViewSettings(sortColumn: .dateModified, sortAscending: false))
		let planned = GlobalDefaultsWriter.plannedValues(for: settings, current: current)
		#expect(planned.viewStyle == "Nlsv")
		let svs = planned.standardViewSettings
		#expect(Set(svs.keys) == Set(current.keys))

		let icon = try #require(svs["IconViewSettings"] as? [String: Any])
		#expect(icon["iconSize"] as? Double == 88)
		#expect(icon["textSize"] as? Double == 12)            // "12" → Double
		#expect(icon["labelOnBottom"] as? Bool == true)        // "1" → Bool
		#expect(icon["viewOptionsVersion"] as? Int == 1)       // "1" → Int
		#expect(icon["gridOffsetX"] as? Double == 0)
		#expect(icon["customKey"] as? String == "keep")

		let list = try #require(svs["ExtendedListViewSettingsV2"] as? [String: Any])
		#expect(list["sortColumn"] as? String == "dateModified")
		#expect(list["textSize"] as? Double == 13)
		#expect(list["useRelativeDates"] as? Bool == true)
		let cols = try #require(list["columns"] as? [[String: Any]])
		#expect(cols.count == 2)
		#expect(cols.first { $0["identifier"] as? String == "dateModified" }?["ascending"] as? Bool == false)
		#expect(cols.first { $0["identifier"] as? String == "name" }?["width"] as? Int == 300)
		#expect(cols.first { $0["identifier"] as? String == "name" }?["ascending"] as? Bool == true)

		let dict = try #require(svs["ListViewSettings"] as? [String: Any])
		#expect(dict["sortColumn"] as? String == "dateModified")
		let dcols = try #require(dict["columns"] as? [String: [String: Any]])
		#expect(dcols["dateModified"]?["ascending"] as? Bool == false)
		#expect(dcols["name"]?["index"] as? Int == 0)
		#expect(dcols["name"]?["ascending"] as? Bool == true)

		// A section the settings do not touch is returned verbatim (still string-typed).
		let gallery = try #require(svs["GalleryViewSettings"] as? [String: Any])
		#expect(gallery["arrangeBy"] as? String == "name")
		#expect(gallery["iconSize"] as? String == "48")

		// Only the view style: the dictionary is returned untouched.
		let styleOnly = GlobalDefaultsWriter.plannedValues(for: ViewSettings(viewStyle: .column), current: current)
		#expect(styleOnly.viewStyle == "clmv")
		#expect(Self.same(styleOnly.standardViewSettings, current))

		// No current dictionary: only the touched section is created, from Finder's factory values.
		let fresh = GlobalDefaultsWriter.plannedValues(for: ViewSettings(icon: IconViewSettings(iconSize: 32)), current: nil)
		#expect(fresh.viewStyle == nil)
		#expect(Set(fresh.standardViewSettings.keys) == ["IconViewSettings"])
		let freshIcon = try #require(fresh.standardViewSettings["IconViewSettings"] as? [String: Any])
		#expect(freshIcon["iconSize"] as? Double == 32)
		#expect(freshIcon["gridSpacing"] as? Double == 54)

		// decode accepts the same string-typed input.
		let decoded = GlobalDefaultsWriter.decode(viewStyle: "glyv", standardViewSettings: current)
		#expect(decoded.viewStyle == .gallery && decoded.icon.iconSize == 64 && decoded.icon.labelOnBottom == true)
		#expect(decoded.list.sortColumn == .name && decoded.list.sortAscending == true && decoded.list.textSize == 13)
	}

	/// The two list sections must describe the same list view: a missing one is derived from the other, not from
	/// the factory values (otherwise widths / text size the user set in one section would come back as factory
	/// defaults in the other).
	@Test func plannedValuesDeriveAMissingListSectionFromTheOtherOne() throws {
		let settings = ViewSettings(list: ListViewSettings(sortColumn: .dateModified, sortAscending: false))
		let userColumns: [[String: Any]] = [
			["identifier": "name", "width": "400", "ascending": "1", "visible": "1"],
			["identifier": "dateModified", "width": "181", "ascending": "1", "visible": "1"],
			["identifier": "kind", "width": "115", "ascending": "1", "visible": "0"]]

		// Only ExtendedListViewSettingsV2 exists (name column 400 wide, text 14).
		let onlyArray: [String: Any] = ["ExtendedListViewSettingsV2": ["textSize": "14", "calculateAllSizes": "1", "sortColumn": "name", "columns": userColumns]]
		let a = GlobalDefaultsWriter.plannedValues(for: settings, current: onlyArray).standardViewSettings
		let aArray = try #require(a["ExtendedListViewSettingsV2"] as? [String: Any])
		let aDict = try #require(a["ListViewSettings"] as? [String: Any])
		#expect(aDict["textSize"] as? Double == 14 && aArray["textSize"] as? Double == 14)
		#expect(aDict["calculateAllSizes"] as? Bool == true)
		#expect(aDict["sortColumn"] as? String == "dateModified" && aArray["sortColumn"] as? String == "dateModified")
		let aCols = try #require(aDict["columns"] as? [String: [String: Any]])
		#expect(aCols.count == 3)
		#expect(aCols["name"]?["width"] as? Int == 400 && aCols["name"]?["index"] as? Int == 0)
		#expect(aCols["kind"]?["visible"] as? Bool == false && aCols["kind"]?["index"] as? Int == 2)
		#expect(aCols["dateModified"]?["ascending"] as? Bool == false)
		#expect(GlobalDefaultsWriter.decode(viewStyle: nil, standardViewSettings: a).differences(to: settings).isEmpty)

		// Only ListViewSettings exists: the array section is rebuilt from it, in index order.
		let onlyDict: [String: Any] = ["ListViewSettings": ["textSize": "14", "sortColumn": "name", "columns": ViewRecordCodec.dictColumns(fromArray: ViewRecordCodec.sanitizeListPlist(["columns": userColumns])["columns"] as! [[String: Any]])]]
		let d = GlobalDefaultsWriter.plannedValues(for: settings, current: onlyDict).standardViewSettings
		let dArray = try #require(d["ExtendedListViewSettingsV2"] as? [String: Any])
		let dDict = try #require(d["ListViewSettings"] as? [String: Any])
		#expect(dArray["textSize"] as? Double == 14 && dDict["textSize"] as? Double == 14)
		let dCols = try #require(dArray["columns"] as? [[String: Any]])
		#expect(dCols.map { $0["identifier"] as? String } == ["name", "dateModified", "kind"])
		#expect(dCols[0]["width"] as? Int == 400 && dCols[2]["visible"] as? Bool == false)
		#expect(dCols[1]["ascending"] as? Bool == false)
		#expect((dDict["columns"] as? [String: [String: Any]])?["dateModified"]?["ascending"] as? Bool == false)

		// Both present: each keeps its own values (the existing behaviour).
		var both = onlyArray
		both["ListViewSettings"] = ["textSize": "11", "sortColumn": "name", "columns": ["name": ["index": "0", "width": "250", "ascending": "1", "visible": "1"]]]
		let b = GlobalDefaultsWriter.plannedValues(for: settings, current: both).standardViewSettings
		#expect((b["ListViewSettings"] as? [String: Any])?["textSize"] as? Double == 11)
		#expect((b["ExtendedListViewSettingsV2"] as? [String: Any])?["textSize"] as? Double == 14)
	}

	// MARK: (b) write / read back / restore in a test domain

	@Test func writesReadsBackAndRestoresInATestDomain() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }

		let empty = GlobalDefaultsWriter.snapshot(domain: domain.name)
		#expect(empty.preferredViewStyle == nil && empty.standardViewSettings == nil)
		#expect(empty.decodedSettings.isEmpty)

		let svs: [String: Any] = [
			"IconViewSettings": ["iconSize": 88.0, "labelOnBottom": false, "viewOptionsVersion": 1, "arrangeBy": "kind"],
			"GalleryViewSettings": ["arrangeBy": "name"]
		]
		try GlobalDefaultsWriter.write(viewStyle: "clmv", standardViewSettings: svs, domain: domain.name)
		#expect(domain.style() == "clmv")
		#expect(FileManager.default.fileExists(atPath: domain.plistURL.path))   // the domain lives in the temp directory
		let back = try #require(domain.svs())
		#expect(Self.same(back, svs))
		#expect((back["IconViewSettings"] as? [String: Any])?["iconSize"] as? Double == 88)
		#expect((back["IconViewSettings"] as? [String: Any])?["labelOnBottom"] as? Bool == false)

		let taken = GlobalDefaultsWriter.snapshot(domain: domain.name)
		#expect(taken.preferredViewStyle == "clmv")
		#expect(Self.same(taken.standardViewSettingsDictionary, svs))
		#expect(taken.decodedSettings.viewStyle == .column && taken.decodedSettings.icon.iconSize == 88 && taken.decodedSettings.icon.arrangeBy == .kind)

		// nil view style leaves the key alone; an empty dictionary leaves StandardViewSettings alone.
		try GlobalDefaultsWriter.write(viewStyle: nil, standardViewSettings: [:], domain: domain.name)
		#expect(domain.style() == "clmv")
		#expect(Self.same(domain.svs(), svs))

		// The snapshot survives the JSON manifest format and restores exactly after other writes.
		let json = try JSONCoding.encoder().encode(taken)
		let decoded = try JSONCoding.decoder().decode(GlobalSnapshot.self, from: json)
		#expect(decoded.hasSameValues(as: taken))
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 16.0]], domain: domain.name)
		#expect(domain.style() == "icnv" && !Self.same(domain.svs(), svs))
		try GlobalDefaultsWriter.restore(decoded, domain: domain.name)
		#expect(domain.style() == "clmv")
		#expect(Self.same(domain.svs(), svs))

		// Restoring an "absent" snapshot removes both keys.
		try GlobalDefaultsWriter.restore(empty, domain: domain.name)
		#expect(domain.style() == nil)
		#expect(domain.svs() == nil)

		// A snapshot whose data cannot be parsed never turns into a key removal.
		try GlobalDefaultsWriter.write(viewStyle: "Nlsv", standardViewSettings: svs, domain: domain.name)
		let corrupt = GlobalSnapshot(preferredViewStyle: nil, standardViewSettings: Data("not a plist".utf8))
		#expect(throws: GlobalDefaultsError.self) { try GlobalDefaultsWriter.restore(corrupt, domain: domain.name) }
		#expect(domain.style() == "Nlsv" && Self.same(domain.svs(), svs))
	}

	// MARK: (c) GlobalApplier order, operation files, undo, quit failure

	@Test func applierQuitsWritesLaunchesAndUndoes() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }
		// Seeded string-typed, like Finder's own values come back through CFPreferences.
		let seed: [String: Any] = [
			"IconViewSettings": ["iconSize": "64", "textSize": "12", "viewOptionsVersion": "1"],
			"GalleryViewSettings": ["arrangeBy": "name"]
		]
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: seed, domain: domain.name)

		let appDir = Self.tempDir("finder-presets-global")
		defer { try? FileManager.default.removeItem(at: appDir) }
		let ops = OperationStore(dirs: AppDirectories(root: appDir))
		let finder = FakeFinder(domain: domain.name)
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)

		// Apply: quit sees the old value, launch sees the new one.
		let settings = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 88))
		let op = try applier.apply(settings, presetName: "P")
		#expect(finder.events == ["quit:icnv", "launch:Nlsv"])
		#expect(op.kind == .applyGlobal && op.finishedAt != nil && op.finderRelaunched)
		#expect(op.presetName == "P" && op.presetSnapshot == settings)
		#expect(op.globalSnapshotFile == "global-before.json")
		#expect(FileManager.default.fileExists(atPath: ops.directory(for: op.id).appendingPathComponent("global-before.json").path))
		#expect(FileManager.default.fileExists(atPath: ops.directory(for: op.id).appendingPathComponent("manifest.json").path))
		let before = try ops.loadGlobalSnapshot(try #require(op.globalSnapshotFile), for: op)
		#expect(before.preferredViewStyle == "icnv")
		#expect(Self.same(before.standardViewSettingsDictionary, seed))
		#expect(op.globalAfter?.preferredViewStyle == "Nlsv")
		#expect(domain.style() == "Nlsv")
		let written = try #require(domain.svs())
		#expect((written["IconViewSettings"] as? [String: Any])?["iconSize"] as? Double == 88)
		#expect((written["IconViewSettings"] as? [String: Any])?["textSize"] as? Double == 12)
		#expect((written["GalleryViewSettings"] as? [String: Any])?["arrangeBy"] as? String == "name")

		// The manifest round-trips with the new optional fields.
		let loaded = try ops.load(id: op.id)
		#expect(loaded.kind == .applyGlobal && loaded.globalSnapshotFile == op.globalSnapshotFile)
		#expect(loaded.globalAfter?.preferredViewStyle == "Nlsv" && loaded.presetSnapshot == settings)

		// Undo: same order, exact restore (string-typed values come back as strings).
		finder.reset()
		let undoOp = try applier.undo(op)
		#expect(finder.events == ["quit:Nlsv", "launch:icnv"])
		#expect(undoOp.kind == .undoGlobal && undoOp.undoOfOperationID == op.id && undoOp.finishedAt != nil)
		#expect(undoOp.globalSnapshotFile == "global-before.json")
		#expect(domain.style() == "icnv")
		#expect(Self.same(domain.svs(), seed))
		#expect((domain.svs()?["IconViewSettings"] as? [String: Any])?["iconSize"] as? String == "64")
		#expect(try ops.list().count == 2)

		// Quit failure: nothing written, nothing launched, no operation left behind.
		finder.reset()
		finder.quitSucceeds = false
		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(viewStyle: .column), presetName: "Q") }
		#expect(finder.events == ["quit:icnv"])
		#expect(domain.style() == "icnv")
		#expect(Self.same(domain.svs(), seed))
		#expect(try ops.list().count == 2)

		// Empty settings never restart Finder.
		finder.quitSucceeds = true
		finder.reset()
		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(), presetName: nil) }
		#expect(finder.events.isEmpty)

		// A folder operation cannot be undone as a global one.
		#expect(throws: GlobalApplyError.self) { try applier.undo(FinderPresetsOperation(kind: .apply, roots: [])) }

		// A sort direction without a sort column can never be written, so it is not a reason to restart Finder.
		finder.reset()
		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(list: ListViewSettings(sortAscending: false)), presetName: nil) }
		#expect(finder.events.isEmpty)
		let withDangling = ViewSettings(viewStyle: .list, list: ListViewSettings(sortAscending: false))
		let normalized = try applier.apply(withDangling, presetName: "N")
		#expect(normalized.presetSnapshot == ViewSettings(viewStyle: .list))   // the dangling direction is dropped, not verified
		#expect(finder.events == ["quit:icnv", "launch:Nlsv"])
		_ = try applier.undo(normalized)
	}

	/// The app writes the home folders' `.DS_Store` in the same Finder-down window (a running Finder would write
	/// its cached copy back on quit): the hook runs after the quit and before the domain is written.
	@Test func applierRunsTheHookWhileFinderIsQuit() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let appDir = Self.tempDir("finder-presets-global-hook")
		defer { try? FileManager.default.removeItem(at: appDir) }
		let ops = OperationStore(dirs: AppDirectories(root: appDir))
		let finder = FakeFinder(domain: domain.name)
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)

		var eventsAtHook: [String]? = nil
		var styleAtHook: String? = nil
		let op = try applier.apply(ViewSettings(viewStyle: .column), presetName: "P") {
			eventsAtHook = finder.events
			styleAtHook = domain.style()
		}
		#expect(eventsAtHook == ["quit:icnv"])          // Finder was down, nothing launched yet
		#expect(styleAtHook == "icnv")                   // and the domain was still untouched
		#expect(finder.events == ["quit:icnv", "launch:clmv"] && op.finderRelaunched)

		// Folder-only variant: quit → body → launch, nothing written to the domain.
		finder.reset()
		var ran = false
		let r = try applier.runWithFinderQuit { () -> Int in ran = true; #expect(finder.events == ["quit:clmv"]); return 7 }
		#expect(ran && r.result == 7 && r.finderRelaunched)
		#expect(finder.events == ["quit:clmv", "launch:clmv"])
		#expect(domain.style() == "clmv")

		// Finder stays alive: the body never runs and nothing is written.
		finder.reset(); finder.quitSucceeds = false
		ran = false
		#expect(throws: GlobalApplyError.self) { try applier.runWithFinderQuit { ran = true } }
		#expect(!ran && finder.events == ["quit:clmv"])
		var hookRan = false
		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(viewStyle: .gallery), presetName: "Q") { hookRan = true } }
		#expect(!hookRan && domain.style() == "clmv")

		// A throwing body still gets Finder launched again before the error propagates.
		finder.reset(); finder.quitSucceeds = true
		struct Boom: Error {}
		#expect(throws: Boom.self) { try applier.runWithFinderQuit { throw Boom() } }
		#expect(finder.events == ["quit:clmv", "launch:clmv"])
	}

	/// A grouping is never written to Finder's defaults (only folders hold it, `ViewSettings.globalDefaultsPart`): the rest
	/// of the preset is written and verified, a preset with nothing but a grouping never restarts Finder, and no
	/// `FXPreferredGroupBy` appears in the domain. The operation the hook recorded is named on the global one before the
	/// domain is written (`relatedOperationID`), so the history pairs the two exactly.
	@Test func applierNeverWritesTheGroupingAndRecordsTheRelatedOperation() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let appDir = Self.tempDir("finder-presets-global-group")
		defer { try? FileManager.default.removeItem(at: appDir) }
		let ops = OperationStore(dirs: AppDirectories(root: appDir))
		let finder = FakeFinder(domain: domain.name)
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)
		func groupKey() -> Any? { CFPreferencesCopyAppValue("FXPreferredGroupBy" as CFString, domain.name as CFString) }

		#expect(throws: GlobalApplyError.self) { try applier.apply(ViewSettings(groupBy: .kind), presetName: "G") }
		#expect(finder.events.isEmpty && groupKey() == nil)

		let folderOpID = UUID()
		let op = try applier.apply(ViewSettings(viewStyle: .list, groupBy: .dateModified), presetName: "LG", whileFinderIsQuit: {},
		                           relatedOperation: { folderOpID })
		let saved = try ops.load(id: op.id)
		#expect(op.presetSnapshot == ViewSettings(viewStyle: .list))   // what was written and verified
		#expect(op.relatedOperationID == folderOpID && saved.relatedOperationID == folderOpID)
		#expect(domain.style() == "Nlsv" && groupKey() == nil)
		#expect(finder.events == ["quit:icnv", "launch:Nlsv"])
		// Without a related operation nothing is named.
		finder.reset()
		let plain = try applier.apply(ViewSettings(viewStyle: .column), presetName: "C")
		#expect(plain.relatedOperationID == nil)
	}

	/// Finder's defaults already hold the recorded values (put back by hand, or by another tool): the undo writes nothing
	/// and leaves Finder alone, but it is recorded, so the apply counts as undone and `global-undo last` moves on. Such a
	/// record has nothing to redo. A verification that fails reports the differing properties as values, not as text.
	@Test func undoOfValuesAlreadyThereOnlyRecordsAndVerificationReportsDiffs() throws {
		let domain = TestDomain()
		defer { domain.cleanup() }
		try GlobalDefaultsWriter.write(viewStyle: "icnv", standardViewSettings: ["IconViewSettings": ["iconSize": 64.0]], domain: domain.name)
		let appDir = Self.tempDir("finder-presets-global-same")
		defer { try? FileManager.default.removeItem(at: appDir) }
		let ops = OperationStore(dirs: AppDirectories(root: appDir))
		let finder = FakeFinder(domain: domain.name)
		let applier = GlobalApplier(operations: ops, domain: domain.name, finder: finder)

		let older = try applier.apply(ViewSettings(viewStyle: .column), presetName: "Older")
		let g = try applier.apply(ViewSettings(viewStyle: .list), presetName: "L")
		// Asked to only record (a confirmation that promised to leave Finder alone) while the values differ: refused,
		// Finder untouched, nothing recorded.
		finder.reset()
		let count = try ops.list().count
		#expect(throws: GlobalApplyError.self) { try applier.undo(g, leaveFinderAlone: true) }
		let countAfter = try ops.list().count
		#expect(finder.events.isEmpty && domain.style() == "Nlsv" && countAfter == count)
		// Put back by hand what g recorded as "before" (the column view of `older`).
		try GlobalDefaultsWriter.restore(try ops.loadGlobalSnapshot(try #require(g.globalSnapshotFile), for: g), domain: domain.name)
		#expect(domain.style() == "clmv")
		finder.reset()
		let recorded = try applier.undo(g)
		#expect(finder.events.isEmpty)                                  // Finder never quit
		#expect(recorded.kind == .undoGlobal && recorded.undoOfOperationID == g.id && recorded.finishedAt != nil)
		#expect(recorded.globalSnapshotFile == nil && recorded.globalAfter?.preferredViewStyle == "clmv" && !recorded.finderRelaunched)
		#expect(OperationHistory.foundAlreadyRestored(recorded) && !OperationHistory.restoredSomething(recorded))
		#expect(domain.style() == "clmv")
		var history = try OperationHistory(store: ops)
		#expect(history.status(of: g) == .undone(by: recorded.id))
		#expect(history.status(of: recorded) == .nothingToUndo)         // nothing to redo
		#expect(history.latestUndoable(global: true)?.id == older.id)   // `global-undo last` moves on
		#expect(history.overview(of: recorded).foundAlreadyRestored)

		// Finder writes other values back at launch: the error carries the differing property (no text).
		finder.reset()
		finder.onLaunch = { try? GlobalDefaultsWriter.write(viewStyle: "glyv", standardViewSettings: [:], domain: domain.name) }
		do {
			_ = try applier.apply(ViewSettings(viewStyle: .list), presetName: "L2")
			Issue.record("the verification did not fail")
		} catch GlobalApplyError.verificationFailed(let id, let diffs) {
			#expect(diffs == [FieldDiff(field: "viewStyle", current: "gallery", target: "list")])
			history = try OperationHistory(store: ops)
			#expect(history.operation(id)?.kind == .applyGlobal && history.operation(id)?.finishedAt != nil)
		}
		finder.onLaunch = nil
	}

	@Test func manifestWithoutGlobalFieldsStillDecodes() throws {
		let json = """
		{"backups":[],"entries":[],"finderRelaunched":false,"id":"6A1B2C3D-0000-4000-8000-000000000001","kind":"apply","pinned":false,"roots":["/tmp/x"],"startedAt":"1700000000.000000"}
		"""
		let op = try JSONCoding.decoder().decode(FinderPresetsOperation.self, from: Data(json.utf8))
		#expect(op.kind == .apply && op.globalSnapshotFile == nil && op.globalAfter == nil && !op.kind.isGlobal)
		#expect(OperationKind.applyGlobal.isGlobal && OperationKind.undoGlobal.isGlobal)
	}

	// MARK: (d) HomeFolders

	@Test func homeFoldersReturnOnlyExistingStandardFoldersAndNeverLibrary() throws {
		let home = Self.tempDir("finder-presets-home")
		defer { try? FileManager.default.removeItem(at: home) }
		for name in ["Documents", "Music", "Library", "Library/Mobile Documents", "Desktop", "Movies-not-standard"] {
			try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		try Data("x".utf8).write(to: home.appendingPathComponent("Pictures"))   // a file, not a folder
		try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Downloads"), withDestinationURL: home.appendingPathComponent("Library"))

		let without = HomeFolders.standardFolders(home: home, includeDesktop: false)
		#expect(without.map(\.lastPathComponent) == ["Documents", "Music"])
		let with = HomeFolders.standardFolders(home: home, includeDesktop: true)
		#expect(with.map(\.lastPathComponent) == ["Documents", "Music", "Desktop"])
		#expect(!with.contains { $0.path.contains("/Library") })
		#expect(with.allSatisfy { $0.path.hasPrefix(home.path + "/") })
		#expect(!HomeFolders.standardNames.contains("Library") && !HomeFolders.standardNames.contains("Desktop"))
		#expect(HomeFolders.isForbidden(home.path + "/Library/Mobile Documents/com~apple~CloudDocs/Documents", home: home.path))
		#expect(HomeFolders.isForbidden(home.path + "/Library", home: home.path))
		#expect(!HomeFolders.isForbidden(home.path + "/Documents", home: home.path))
	}

	/// The home folder and every folder above it are refused as apply roots (they would reach the whole home folder).
	@Test func homeFolderAndItsAncestorsAreNeverRoots() {
		let home = URL(fileURLWithPath: "/Users/someone")
		for path in ["/Users/someone", "/Users/someone/", "/Users", "/", "/users/SOMEONE", "/Users/someone/."] {
			#expect(HomeFolders.isHomeOrAncestor(path, home: home), "\(path)")
		}
		for path in ["/Users/someone/Documents", "/Users/someone/Desktop", "/Users/someoneelse", "/Users/Shared", "/tmp", "/Volumes/X"] {
			#expect(!HomeFolders.isHomeOrAncestor(path, home: home), "\(path)")
		}
		#expect(HomeFolders.isHomeOrAncestor(FileManager.default.homeDirectoryForCurrentUser.path))
	}
}

import Foundation
import Testing
import DSStore
@testable import FinderPresetsCore

@Suite struct CodecAndStoreTests {
	static var fixture: URL { Bundle.module.url(forResource: "finder-native-parent", withExtension: "DS_Store", subdirectory: "Fixtures")! }

	static func tempDir() throws -> URL {
		let u = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
		return u
	}

	@Test func decodesFinderNativeRecords() throws {
		// Fixture: Finder-written parent store. Folder-A has icvp (64/12/none/bottom/no info) + lsvC (name/16/13); Folder-B has icvp only.
		let set = try StoreEditor.managedRecords(at: Self.fixture, key: "Folder-A")
		let s = try #require(set.map(ViewRecordCodec.decode))
		#expect(s.viewStyle == nil)                 // Finder wrote no vstl for this folder
		#expect(s.icon.iconSize == 64)
		#expect(s.icon.textSize == 12)
		#expect(s.icon.arrangeBy == SortKey.none)
		#expect(s.icon.labelOnBottom == true)
		#expect(s.icon.showItemInfo == false)
		#expect(s.icon.gridSpacing == 45)
		#expect(s.list.sortColumn == .name)
		#expect(s.list.sortAscending == true)
		#expect(s.list.iconSize == 16)
		#expect(s.list.textSize == 13)
		let b = try #require(try StoreEditor.managedRecords(at: Self.fixture, key: "Folder-B").map(ViewRecordCodec.decode))
		#expect(b.icon.iconSize == 64 && b.list.isEmpty)
		#expect(try StoreEditor.managedRecords(at: Self.fixture, key: "does-not-exist")?.isEmpty == true)
	}

	@Test func mergePreservesUnknownKeys() throws {
		let existing: [String: Any] = ["iconSize": 64.0, "customKey": "keep me", "gridSpacing": 45.0, "viewOptionsVersion": 1]
		let merged = ViewRecordCodec.mergeIcon(IconViewSettings(iconSize: 88, arrangeBy: .kind), into: existing, base: [:])
		#expect(merged["customKey"] as? String == "keep me")
		#expect(merged["gridSpacing"] as? Double == 45)
		#expect(merged["iconSize"] as? Double == 88)
		#expect(merged["arrangeBy"] as? String == "kind")
	}

	/// Finder's "자동 격자 정렬" (Snap to Grid) is `arrangeBy = grid` in `icvp` — what the home folder's own record held.
	/// It is read as a value of its own (not dropped as unknown, which would turn a folder's "자동 격자 정렬"
	/// into "유지" when a preset is made from it) and written back as the same string.
	@Test func snapToGridArrangement() throws {
		let decoded = ViewRecordCodec.decodeIcon(["arrangeBy": "grid", "iconSize": 60.0, "gridSpacing": 45.0])
		#expect(decoded.arrangeBy == .grid && decoded.iconSize == 60 && decoded.gridSpacing == 45)
		let merged = ViewRecordCodec.mergeIcon(IconViewSettings(arrangeBy: .grid), into: ["arrangeBy": "name"], base: [:])
		#expect(merged["arrangeBy"] as? String == "grid")
		#expect(SortKey(rawValue: "grid") == .grid && SortKey.allCases.prefix(3) == [.none, .grid, .name])
	}

	@Test func mergeListSetsSortDirectionInBothColumnForms() {
		let arr = ViewRecordCodec.mergeList(ListViewSettings(sortColumn: .size, sortAscending: false), into: nil, base: ViewRecordCodec.factoryListPlist)
		let cols = arr["columns"] as! [[String: Any]]
		#expect(cols.first { $0["identifier"] as? String == "size" }?["ascending"] as? Bool == false)
		#expect(arr["sortColumn"] as? String == "size")
		let dict = ViewRecordCodec.dictColumns(fromArray: cols)
		#expect(dict["size"]?["ascending"] as? Bool == false)
		#expect(dict["name"]?["index"] as? Int == 0)
	}

	/// Finder writes sort columns this app does not model (e.g. `shareOwner` on a shared folder). Such a record
	/// yields no sort column and, because the direction lives inside the column's entry, no direction either —
	/// a preset made from it would otherwise carry a direction that can never be written.
	@Test func unknownSortColumnYieldsNeitherColumnNorDirection() throws {
		let columns: [[String: Any]] = [["identifier": "name", "ascending": true, "width": 300, "visible": true],
		                                ["identifier": "shareOwner", "ascending": false, "width": 150, "visible": true]]
		let shared = ViewRecordCodec.decodeList(["sortColumn": "shareOwner", "textSize": 13.0, "columns": columns])
		#expect(shared.sortColumn == nil && shared.sortAscending == nil && shared.textSize == 13)
		#expect(!shared.hasDanglingSortDirection)
		let known = ViewRecordCodec.decodeList(["sortColumn": "name", "columns": columns])
		#expect(known.sortColumn == .name && known.sortAscending == true)
		let dict = ViewRecordCodec.decodeList(["sortColumn": "ubiquity", "columns": ["ubiquity": ["index": 0, "ascending": false]]])
		#expect(dict.sortColumn == nil && dict.sortAscending == nil)

		// The full record set path (what "이 폴더처럼" reads) behaves the same, and a store written from such a
		// preset converges: after apply, nothing is left to change.
		var store = DSStore()
		store = try StoreEditor.apply(ViewSettings(viewStyle: .list, list: shared), to: "S", in: store, bases: RecordBases())
		let back = ViewRecordCodec.decode(StoreEditor.managedRecords(in: store, key: "S"))
		#expect(back.differences(to: ViewSettings(viewStyle: .list, list: shared)).isEmpty)

		// dict ↔ array column conversion keeps order, width and flags.
		let asDict = ViewRecordCodec.dictColumns(fromArray: columns)
		let asArray = ViewRecordCodec.arrayColumns(fromDict: asDict)
		#expect(asArray.map { $0["identifier"] as? String } == ["name", "shareOwner"])
		#expect(asArray[1]["width"] as? Int == 150 && asArray[1]["ascending"] as? Bool == false && asArray[0]["visible"] as? Bool == true)
	}

	@Test func applyKeepsEveryOtherRecordAndWritesLevelsZeroCompatibleFile() throws {
		let dir = try Self.tempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = dir.appendingPathComponent(".DS_Store")
		try FileManager.default.copyItem(at: Self.fixture, to: store)
		let original = try DSStore.read(from: store)
		let originalOther = Set(original.records.filter { $0.filename != "Folder-C" }.map { "\($0.filename)/\($0.type.fourCC)/\($0.value)" })

		let target = ViewSettings(viewStyle: .gallery, icon: IconViewSettings(iconSize: 32), list: ListViewSettings(textSize: 11, sortColumn: .kind, sortAscending: true))
		let edited = try StoreEditor.apply(target, to: "Folder-C", in: original, bases: RecordBases())
		try StoreEditor.write(edited, to: store)

		let back = try DSStore.read(from: store)
		let backOther = Set(back.records.filter { $0.filename != "Folder-C" }.map { "\($0.filename)/\($0.type.fourCC)/\($0.value)" })
		#expect(backOther == originalOther)
		let c = StoreEditor.managedRecords(in: back, key: "Folder-C")
		let decoded = ViewRecordCodec.decode(c)
		#expect(decoded.viewStyle == .gallery)
		#expect(decoded.icon.iconSize == 32)
		#expect(decoded.list.textSize == 11)
		#expect(decoded.list.sortColumn == .kind)
		#expect(c["vSrn"]?.uint32Value == 1)
		#expect(c["lsvp"] != nil && c["lsvC"] != nil)
		// no temp file left behind
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }
		#expect(leftovers.isEmpty)
		// B-tree header: root-only tree must have levels == 0 (Finder rejects 1)
		let data = try Data(contentsOf: store)
		let rootOff = Int(data[8..<12].reduce(0) { $0 << 8 | UInt32($1) }) + 4
		let count = Int(data[rootOff..<rootOff+4].reduce(0) { $0 << 8 | UInt32($1) })
		var offs: [UInt32] = []
		for i in 0..<count { let o = rootOff + 8 + 4 * i; offs.append(data[o..<o+4].reduce(0) { $0 << 8 | UInt32($1) }) }
		let blk1 = Int(offs[1] & ~0x1f) + 4
		let levels = data[blk1+4..<blk1+8].reduce(0) { $0 << 8 | UInt32($1) }
		let nodes = data[blk1+12..<blk1+16].reduce(0) { $0 << 8 | UInt32($1) }
		#expect(nodes > 1 || levels == 0)
	}

	/// A preset changes only the options it contains: a record group it leaves at "유지" is kept exactly as stored, so an
	/// icon-only preset does not take a list-view folder's view style or list options away (and so on for each group).
	@Test func partialPresetKeepsTheRecordGroupsItDoesNotMention() throws {
		let full = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 64),
		                        list: ListViewSettings(textSize: 11, sortColumn: .dateModified, sortAscending: false))
		var store = try StoreEditor.apply(full, to: "T", in: DSStore(), bases: RecordBases())
		store.add(DSStore.Record(filename: "T", type: DSStore.RecordType(fourCC: DSStore.FourCC("lsvP")!), value: StoreEditor.managedRecords(in: store, key: "T")["lsvC"]!.toRecord(filename: "T")!.value))
		let before = StoreEditor.managedRecords(in: store, key: "T")
		#expect(["vSrn", "vstl", "icvp", "lsvC", "lsvp", "lsvP"].allSatisfy { before[$0] != nil })

		// Icon options only: vstl and the three list records stay as stored; icvp is merged.
		store = try StoreEditor.apply(ViewSettings(icon: IconViewSettings(iconSize: 48)), to: "T", in: store, bases: RecordBases())
		var now = StoreEditor.managedRecords(in: store, key: "T")
		for code in ["vstl", "lsvC", "lsvp", "lsvP"] { #expect(now[code] == before[code], "\(code)") }
		var decoded = ViewRecordCodec.decode(now)
		#expect(decoded.viewStyle == .list && decoded.icon.iconSize == 48)
		#expect(decoded.list.textSize == 11 && decoded.list.sortColumn == .dateModified && decoded.list.sortAscending == false)

		// List options only: vstl and icvp stay.
		let icon = now["icvp"]
		store = try StoreEditor.apply(ViewSettings(list: ListViewSettings(textSize: 12)), to: "T", in: store, bases: RecordBases())
		now = StoreEditor.managedRecords(in: store, key: "T")
		#expect(now["vstl"] == before["vstl"] && now["icvp"] == icon)
		decoded = ViewRecordCodec.decode(now)
		#expect(decoded.list.textSize == 12 && decoded.list.sortColumn == .dateModified && decoded.icon.iconSize == 48)

		// View style only: the icon and list records stay.
		let lists = ["lsvC", "lsvp", "lsvP"].map { now[$0] }
		store = try StoreEditor.apply(ViewSettings(viewStyle: .column), to: "T", in: store, bases: RecordBases())
		now = StoreEditor.managedRecords(in: store, key: "T")
		#expect(now["icvp"] == icon && ["lsvC", "lsvp", "lsvP"].map { now[$0] } == lists)
		#expect(ViewRecordCodec.decode(now).viewStyle == .column && ViewRecordCodec.decode(now).list.textSize == 12)
		#expect(store.records.filter { $0.filename == "T" }.count == 6)   // one record per type, nothing duplicated
	}

	/// Finder-written fixture: Folder-A has no vstl, so a preset made from it keeps the view style of the folder it is applied to.
	@Test func presetWithoutViewStyleKeepsTheFoldersViewStyle() throws {
		let original = try DSStore.read(from: Self.fixture)
		let fromA = ViewRecordCodec.decode(StoreEditor.managedRecords(in: original, key: "Folder-A"))
		#expect(fromA.viewStyle == nil && !fromA.icon.isEmpty && !fromA.list.isEmpty)
		let cBefore = StoreEditor.managedRecords(in: original, key: "Folder-C")
		let vstl = try #require(cBefore["vstl"])
		let edited = try StoreEditor.apply(fromA, to: "Folder-C", in: original, bases: RecordBases())
		let cAfter = StoreEditor.managedRecords(in: edited, key: "Folder-C")
		#expect(cAfter["vstl"] == vstl)
		#expect(ViewRecordCodec.decode(cAfter).viewStyle == ViewRecordCodec.decode(cBefore).viewStyle)
		#expect(ViewRecordCodec.decode(cAfter).differences(to: fromA).isEmpty)
	}

	@Test func restoreRemovesRecordsWhenBeforeWasAbsent() throws {
		var store = DSStore()
		store = try StoreEditor.apply(ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 48)), to: "X", in: store, bases: RecordBases())
		#expect(!StoreEditor.managedRecords(in: store, key: "X").isEmpty)
		let restored = StoreEditor.restore(ManagedRecordSet(), for: "X", in: store)
		#expect(StoreEditor.managedRecords(in: restored, key: "X").isEmpty)
	}

	@Test func sanitizesStringTypedDefaults() {
		let icon = ViewRecordCodec.sanitizeIconPlist(["viewOptionsVersion": "1", "iconSize": "64", "labelOnBottom": "1", "arrangeBy": "none"])
		#expect(icon["viewOptionsVersion"] as? Int == 1)
		#expect(icon["iconSize"] as? Double == 64)
		#expect(icon["labelOnBottom"] as? Bool == true)
		#expect(icon["arrangeBy"] as? String == "none")
		let list = ViewRecordCodec.sanitizeListPlist(["textSize": "13", "columns": [["identifier": "name", "width": "300", "ascending": "1", "visible": "1"]]])
		let col = (list["columns"] as! [[String: Any]])[0]
		#expect(col["width"] as? Int == 300 && col["ascending"] as? Bool == true)
		#expect(ViewRecordCodec.decodeIcon(["iconSize": "88", "showItemInfo": "0"]).iconSize == 88)
		#expect(ViewRecordCodec.decodeIcon(["iconSize": "88", "showItemInfo": "0"]).showItemInfo == false)
	}

	@Test func koreanNamesUseOnDiskSpelling() throws {
		let nfc = "D 예외".precomposedStringWithCanonicalMapping
		let nfd = nfc.decomposedStringWithCanonicalMapping
		func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }
		#expect(nfc == nfd && !same(nfc, nfd))          // Swift equality is canonical; bytes differ
		// Locator returns the spelling the file system reports (APFS keeps NFC input; the listing is what Finder keys by).
		for form in [nfc, nfd] {
			let parent = try Self.tempDir()
			defer { try? FileManager.default.removeItem(at: parent) }
			let dir = parent.appendingPathComponent(form)
			try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
			let listed = try #require(try FileManager.default.contentsOfDirectory(atPath: parent.path).first)
			#expect(same(try ParentStoreLocator.locate(dir).key, listed))
		}
		// A stale NFD-keyed record (from another tool) is unified under the on-disk NFC key on apply.
		var store = DSStore()
		store.add(DSStore.Record(filename: nfd, type: DSStore.RecordType(fourCC: DSStore.FourCC("vstl")!), value: .fourCC(DSStore.FourCC("clmv")!)))
		store = try StoreEditor.apply(ViewSettings(viewStyle: .list), to: nfc, in: store, bases: RecordBases())
		let vstl = store.records.filter { $0.type.fourCC.description == "vstl" }
		#expect(vstl.count == 1 && same(vstl[0].filename, nfc))
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: store, key: nfd)).viewStyle == .list)
		#expect(StoreEditor.managedRecords(in: StoreEditor.restore(ManagedRecordSet(), for: nfd, in: store), key: nfc).isEmpty)
		// A record that is kept (not mentioned by the preset) is unified under the on-disk key as well.
		var other = DSStore()
		other.add(DSStore.Record(filename: nfd, type: DSStore.RecordType(fourCC: DSStore.FourCC("vstl")!), value: .fourCC(DSStore.FourCC("clmv")!)))
		other = try StoreEditor.apply(ViewSettings(icon: IconViewSettings(iconSize: 48)), to: nfc, in: other, bases: RecordBases())
		let kept = other.records.filter { $0.type.fourCC.description == "vstl" }
		#expect(kept.count == 1 && same(kept[0].filename, nfc) && kept[0].value == .fourCC(DSStore.FourCC("clmv")!))
	}

	@Test func rawRecordRoundTrip() throws {
		let r = DSStore.Record(filename: "A", type: DSStore.RecordType(fourCC: DSStore.FourCC("vstl")!), value: .fourCC(DSStore.FourCC("icnv")!))
		let raw = RawRecord(record: r)
		#expect(raw.kind == .fourCC && raw.fourCCValue == "icnv" && raw.type == "vstl")
		#expect(raw.toRecord(filename: "A") == r)
		let json = try JSONCoding.encoder().encode(ManagedRecordSet(records: [raw]))
		#expect(try JSONCoding.decoder().decode(ManagedRecordSet.self, from: json) == ManagedRecordSet(records: [raw]))
	}

	/// Finder keeps a folder's grouping in the parent store as a `GRP0` record (`ustr`, e.g. "Kind", "None").
	/// A preset without a grouping leaves the record exactly as Finder wrote it, byte for byte, through apply and undo; an
	/// undo of an operation recorded before `GRP0` was managed (`legacyCodes`) never touches it either.
	@Test func groupByRecordIsKeptThroughApplyAndUndo() throws {
		let dir = try Self.tempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = dir.appendingPathComponent(".DS_Store")
		let grp0 = DSStore.RecordType(fourCC: DSStore.FourCC("GRP0")!)
		var store = DSStore()
		store.add(DSStore.Record(filename: "G1", type: grp0, value: .string("Kind")))
		store.add(DSStore.Record(filename: "G2", type: grp0, value: .string("None")))
		try StoreEditor.write(store, to: url)
		// Finder's bytes for this record: 'GRP0' 'ustr' length 4, UTF-16BE (a dump of a Finder-written store).
		let recordBytes = Data("GRP0ustr".utf8) + Data([0, 0, 0, 4]) + Data([0, 0x4B, 0, 0x69, 0, 0x6E, 0, 0x64])
		#expect(try Data(contentsOf: url).range(of: recordBytes) != nil)
		#expect(ManagedRecordSet.managedCodes.contains("GRP0") && !ManagedRecordSet.legacyCodes.contains("GRP0"))

		func groupValues() throws -> [String: DSStore.Value] {
			Dictionary(uniqueKeysWithValues: try DSStore.read(from: url).records.filter { $0.type == grp0 }.map { ($0.filename, $0.value) })
		}
		let before = try #require(try StoreEditor.managedRecords(at: url, key: "G1"))
		#expect(ViewRecordCodec.decode(before).groupBy == .kind)
		let target = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 48, arrangeBy: .kind), list: ListViewSettings(textSize: 11))
		try StoreEditor.write(try StoreEditor.apply(target, to: "G1", in: try DSStore.read(from: url), bases: RecordBases()), to: url)
		#expect(try groupValues() == ["G1": .string("Kind"), "G2": .string("None")])
		#expect(try Data(contentsOf: url).range(of: recordBytes) != nil)
		let after = try #require(try StoreEditor.managedRecords(at: url, key: "G1"))
		#expect(ViewRecordCodec.decode(after).icon.arrangeBy == .kind && ViewRecordCodec.decode(after).groupBy == .kind)
		// Undo puts back the recorded "before", which holds the grouping as Finder wrote it.
		try StoreEditor.write(StoreEditor.restore(before, for: "G1", in: try DSStore.read(from: url)), to: url)
		#expect(try groupValues() == ["G1": .string("Kind"), "G2": .string("None")])
		#expect(try StoreEditor.managedRecords(at: url, key: "G1") == before)
		// An operation recorded before GRP0 was managed: its undo reads and restores only the legacy codes.
		try StoreEditor.write(try StoreEditor.apply(target, to: "G1", in: try DSStore.read(from: url), bases: RecordBases()), to: url)
		let legacy = try #require(try StoreEditor.managedRecords(at: url, key: "G1", codes: ManagedRecordSet.legacyCodes))
		#expect(legacy["GRP0"] == nil && ViewRecordCodec.decode(legacy).groupBy == nil)
		try StoreEditor.write(StoreEditor.restore(ManagedRecordSet(), for: "G1", in: try DSStore.read(from: url), codes: ManagedRecordSet.legacyCodes), to: url)
		#expect(try groupValues() == ["G1": .string("Kind"), "G2": .string("None")])
		#expect(try StoreEditor.managedRecords(at: url, key: "G1", codes: ManagedRecordSet.legacyCodes)?.isEmpty == true)
		#expect(try Data(contentsOf: url).range(of: recordBytes) != nil)
	}

	/// A preset's grouping is written the way Finder writes it (a `ustr` with Finder's own string), read back, replaced, and
	/// removed by a restore to a state without it. A grouping the app does not offer ("Label", which Finder could not open
	/// a window with) decodes as none and is kept as it is by a preset without a grouping.
	@Test func groupByIsWrittenAsFinderWritesIt() throws {
		var store = try StoreEditor.apply(ViewSettings(groupBy: .kind), to: "G", in: DSStore(), bases: RecordBases())
		let grp0 = store.records.filter { $0.type.fourCC.description == "GRP0" }
		#expect(grp0.count == 1 && grp0.first?.value == .string("Kind"))
		#expect(store.records.map { $0.type.fourCC.description }.sorted() == ["GRP0", "vSrn"])   // nothing else
		let written = StoreEditor.managedRecords(in: store, key: "G")
		#expect(ViewRecordCodec.decode(written) == ViewSettings(groupBy: .kind))
		#expect(written["GRP0"]?.kind == .string && written["GRP0"]?.toRecord(filename: "G")?.value == .string("Kind"))
		store = try StoreEditor.apply(ViewSettings(groupBy: .dateLastOpened), to: "G", in: store, bases: RecordBases())
		#expect(store.records.first { $0.type.fourCC.description == "GRP0" }?.value == .string("Date Last Opened"))
		#expect(StoreEditor.managedRecords(in: StoreEditor.restore(ManagedRecordSet(), for: "G", in: store), key: "G").isEmpty)
		#expect(GroupBy.allCases.map(\.rawValue) == ["None", "Kind", "Application", "Date Last Opened", "Date Added", "Date Modified", "Date Created", "Size"])

		var other = DSStore()
		other.add(DSStore.Record(filename: "L", type: DSStore.RecordType(fourCC: DSStore.FourCC("GRP0")!), value: .string("Label")))
		#expect(ViewRecordCodec.decode(StoreEditor.managedRecords(in: other, key: "L")).groupBy == nil)
		other = try StoreEditor.apply(ViewSettings(viewStyle: .icon), to: "L", in: other, bases: RecordBases())
		#expect(other.records.first { $0.type.fourCC.description == "GRP0" }?.value == .string("Label"))
		// JSON round trip of a record set with a grouping (a manifest's before/after).
		let json = try JSONCoding.encoder().encode(written)
		#expect(try JSONCoding.decoder().decode(ManagedRecordSet.self, from: json) == written)
		// A preset file without "groupBy" (written before it existed) decodes with none.
		let old = try JSONCoding.decoder().decode(ViewSettings.self, from: Data(#"{"icon":{"iconSize":48},"list":{}}"#.utf8))
		#expect(old.groupBy == nil && old.icon.iconSize == 48)
		#expect(try JSONCoding.decoder().decode(ViewSettings.self, from: try JSONCoding.encoder().encode(ViewSettings(groupBy: .size))).groupBy == .size)
	}

	/// The root is refused. The home folder, whose parent (`/Users`) only root may write, is the `"."` record of its own
	/// `.DS_Store`, where Finder keeps it; any other folder is its parent's record under its on-disk name.
	@Test func locatorFindsWhereFinderKeepsAFolder() throws {
		#expect(throws: LocatorError.self) { try ParentStoreLocator.locate(URL(fileURLWithPath: "/")) }
		let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
		let own = try ParentStoreLocator.locate(home)   // reads and writes nothing
		#expect(own.key == StoreLocation.selfKey && own.storeURL == home.appendingPathComponent(".DS_Store") && own.folder == home)
		let dir = try Self.tempDir()
		defer { try? FileManager.default.removeItem(at: dir) }
		let loc = try ParentStoreLocator.locate(dir)
		#expect(loc.key == dir.lastPathComponent)
		#expect(loc.storeURL.lastPathComponent == ".DS_Store")
	}
}

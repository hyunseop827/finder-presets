import Foundation
import Testing
@testable import FinderPresetsCore

@Suite struct ModelTests {
	@Test func presetJSONRoundTrip() throws {
		let p = Preset(name: "My Default", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 88, textSize: 12, labelOnBottom: true, showItemInfo: true, showIconPreview: true, arrangeBy: .name), list: ListViewSettings(sortColumn: .dateModified, sortAscending: false)), createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
		let data = try JSONCoding.encoder().encode(p)
		let back = try JSONCoding.decoder().decode(Preset.self, from: data)
		#expect(back == p)
		#expect(String(data: data, encoding: .utf8)!.contains("\"viewStyle\" : \"icnv\""))
	}

	@Test func differencesOnlyReportSpecifiedFields() {
		let current = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 64))
		let target = ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 64, textSize: 12))
		let diffs = current.differences(to: target)
		#expect(diffs.map(\.field) == ["viewStyle", "icon.textSize"])
		#expect(diffs[1].current == nil)                          // no value: the caller words it
		#expect(diffs[1].text == "icon.textSize: 미설정 ≠ 12.0")    // finder-presets's form
	}

	/// `sortAscending` is only meaningful with `sortColumn` (it is stored in that column's entry): a value without
	/// a column is dropped when a preset is created or decoded, and never compared — otherwise a plan would stay
	/// "willChange" and a global apply would restart Finder and then fail verification every time.
	@Test func danglingSortDirectionIsDroppedAndNotCompared() throws {
		let dangling = ListViewSettings(textSize: 11, sortAscending: false)
		#expect(dangling.hasDanglingSortDirection && dangling.normalized() == ListViewSettings(textSize: 11))
		#expect(!ListViewSettings(sortColumn: .name, sortAscending: false).hasDanglingSortDirection)
		#expect(ListViewSettings(sortAscending: false).normalized().isEmpty)   // nothing left to apply

		// Preset(...) normalizes; a hand-edited / older JSON file decodes without the dangling value.
		let p = Preset(name: "D", settings: ViewSettings(viewStyle: .list, list: dangling))
		#expect(p.settings.list.sortAscending == nil && p.settings.list.textSize == 11)
		let json = Data("""
		{"id":"6A1B2C3D-0000-4000-8000-000000000002","name":"J","schemaVersion":1,"createdAt":"1700000000","updatedAt":"1700000000",
		 "settings":{"icon":{},"list":{"sortAscending":false,"textSize":11}}}
		""".utf8)
		let decoded = try JSONCoding.decoder().decode(Preset.self, from: json)
		#expect(decoded.settings.list.sortAscending == nil && decoded.settings.list.textSize == 11)
		let withColumn = Data("""
		{"id":"6A1B2C3D-0000-4000-8000-000000000003","name":"K","schemaVersion":1,"createdAt":"1700000000","updatedAt":"1700000000",
		 "settings":{"icon":{},"list":{"sortColumn":"size","sortAscending":false}}}
		""".utf8)
		let kept = try JSONCoding.decoder().decode(Preset.self, from: withColumn)
		#expect(kept.settings.list.sortColumn == .size && kept.settings.list.sortAscending == false)

		// differences: the direction is compared only when the target names a column.
		let current = ViewSettings(list: ListViewSettings(sortColumn: .name, sortAscending: true))
		#expect(current.differences(to: ViewSettings(list: ListViewSettings(sortAscending: false))).isEmpty)
		#expect(current.differences(to: ViewSettings(list: ListViewSettings(sortColumn: .name, sortAscending: false))).map(\.field) == ["list.sortAscending"])
		#expect(current.differences(to: ViewSettings(list: ListViewSettings(sortColumn: .size, sortAscending: false))).map(\.field) == ["list.sortColumn", "list.sortAscending"])
	}

	@Test func fillingUsesBaseForNilOnly() {
		let base = ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 64, textSize: 12))
		let s = ViewSettings(icon: IconViewSettings(iconSize: 88)).filling(from: base)
		#expect(s.viewStyle == .list)
		#expect(s.icon.iconSize == 88)
		#expect(s.icon.textSize == 12)
	}

	@Test func rulePriority() {
		let a = UUID(), b = UUID(), d = UUID()
		let rules = [
			FolderRule(path: "/tmp/x", presetID: a, appliesToSubfolders: true),
			FolderRule(path: "/tmp/x/dev", presetID: b, appliesToSubfolders: false)
		]
		let r = RuleResolver(rules: rules, defaultPresetID: d)
		#expect(r.resolve(path: "/tmp/x/dev").presetID == b)          // exact wins
		#expect(r.resolve(path: "/tmp/x/dev/sub").presetID == a)      // b does not inherit → nearest ancestor a
		#expect(r.resolve(path: "/tmp/x/other/deep").presetID == a)
		#expect(r.resolve(path: "/tmp/xylophone").presetID == d)      // prefix must be a path component
		#expect(r.resolve(path: "/elsewhere").source == .defaultPreset)
		#expect(RuleResolver(rules: [], defaultPresetID: nil).resolve(path: "/a").source == .none)
	}
}

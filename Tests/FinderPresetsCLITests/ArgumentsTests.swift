import Foundation
import Testing
import FinderPresetsCore
@testable import finder_presets

@Suite struct ArgumentsTests {
	/// `analyze`/`apply`: a bad or missing `--depth` value would have meant "no limit" (every nested folder written), and
	/// a mistyped flag a target folder named after it.
	@Test func planArguments() throws {
		#expect(try parsePlanArguments(["A", "--depth", "2", "--pin-defaults", "--relaunch", "B"])
			== PlanArguments(roots: ["A", "B"], depth: 2, pinDefaults: true))
		#expect(try parsePlanArguments(["A", "--depth", "0"]).depth == 0)
		#expect(try parsePlanArguments(["A"]).depth == nil)
		for bad in [["A", "--depth"], ["A", "--depth", "l"], ["A", "--depth", "-1"], ["A", "--depth", "1.5"]] {
			#expect(throws: PlanArgumentError.badDepth) { try parsePlanArguments(bad) }
		}
		#expect(throws: PlanArgumentError.unknown("--relaunh")) { try parsePlanArguments(["A", "--relaunh"]) }
	}

	/// `preset-set`: a value a key does not take is refused (the command then saves nothing) instead of clearing the
	/// field; "-" or nothing clears it on purpose.
	@Test func presetFields() throws {
		var s = ViewSettings()
		for pair in ["viewStyle=list", "groupBy=Date Modified", "icon.iconSize=88", "icon.textSize=12", "icon.labelOnBottom=false",
		             "icon.arrangeBy=dateAdded", "list.iconSize=32", "list.sortColumn=size", "list.sortAscending=true"] {
			try setPresetField(pair, in: &s)
		}
		#expect(s.viewStyle == .list && s.groupBy == .dateModified)
		#expect(s.icon.iconSize == 88 && s.icon.textSize == 12 && s.icon.labelOnBottom == false && s.icon.arrangeBy == .dateAdded)
		#expect(s.list.iconSize == 32 && s.list.sortColumn == .size && s.list.sortAscending == true)
		try setPresetField("viewStyle=icnv", in: &s)
		#expect(s.viewStyle == .icon)

		let before = s
		for bad in ["viewStyle=Icon", "viewStyle=lsvw", "icon.labelOnBottom=yes", "list.sortAscending=1", "icon.arrangeBy=Name",
		            "list.sortColumn=datemodified", "groupBy=folder", "icon.iconSize=8", "icon.textSize=12.5", "list.iconSize=24"] {
			#expect(throws: PresetFieldError.self) { try setPresetField(bad, in: &s) }
		}
		#expect(s == before)
		#expect(throws: PresetFieldError.badValue(key: "list.sortAscending", value: "yes", allowed: "true, false")) {
			try setPresetField("list.sortAscending=yes", in: &s)
		}
		#expect(throws: PresetFieldError.badValue(key: "icon.textSize", value: "9", allowed: "10–16 사이의 정수")) {
			try setPresetField("icon.textSize=9", in: &s)
		}
		#expect(throws: PresetFieldError.unknownKey("icon.size")) { try setPresetField("icon.size=64", in: &s) }
		#expect(throws: PresetFieldError.notAPair("viewStyle")) { try setPresetField("viewStyle", in: &s) }

		try setPresetField("viewStyle=-", in: &s)
		try setPresetField("list.sortAscending=", in: &s)
		try setPresetField("icon.iconSize=-", in: &s)
		#expect(s.viewStyle == nil && s.list.sortAscending == nil && s.icon.iconSize == nil)
	}

	@Test func numbers() {
		#expect(number(48) == "48" && number(48.5) == "48.5" && number(1e20) == "1e+20")
		#expect(days(30 * 86400) == "30" && days(2.5 * 86400) == "2.5" && days(86400 / 3) == "0.3")
	}
}

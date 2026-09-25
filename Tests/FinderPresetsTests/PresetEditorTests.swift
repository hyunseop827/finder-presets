import Foundation
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// The preset editor's model outside the UI: a draft mirrors a preset exactly, "유지" stays nil, a typed number is
/// brought into Finder's range, what cannot be saved is refused with its reason, and `PresetDraft.commit` writes only what it should (a temporary data folder, never the
/// app's). No AppModel is created here (it would open the default data folder).
@MainActor @Suite struct PresetEditorTests {
	static let full = ViewSettings(
		viewStyle: .icon,
		icon: IconViewSettings(iconSize: 48, textSize: 10, labelOnBottom: false, showItemInfo: false, showIconPreview: true, arrangeBy: .kind, gridSpacing: 54),
		list: ListViewSettings(textSize: 11, iconSize: 32, sortColumn: .dateModified, sortAscending: false, showIconPreview: true,
		                       useRelativeDates: true, calculateAllSizes: false))

	/// Opened and saved unchanged, every kind of preset keeps exactly its values (and its "유지" options stay nil).
	@Test func draftMirrorsThePreset() {
		let presets = [
			Preset(name: "full", settings: Self.full),
			Preset(name: "empty", settings: ViewSettings()),
			Preset(name: "list only", settings: ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 11, iconSize: 32, sortColumn: .name))),
			Preset(name: "fractions", settings: ViewSettings(icon: IconViewSettings(iconSize: 57.5, gridSpacing: 45.25))),
			Preset(name: "none sort", settings: ViewSettings(icon: IconViewSettings(arrangeBy: SortKey.none))),
			Preset(name: "gallery", settings: ViewSettings(viewStyle: .gallery)),
			Preset(name: "grouped", settings: ViewSettings(viewStyle: .list, list: ListViewSettings(sortColumn: .name), groupBy: .dateAdded)),
			Preset(name: "no groups", settings: ViewSettings(groupBy: GroupBy.none))
		]
		for p in presets {
			let draft = PresetDraft(preset: p)
			let check = draft.check(others: [])
			#expect(check.problems.isEmpty, "\(p.name): \(check.problems)")
			#expect(check.settings == p.settings, "\(p.name)")
			#expect(check.name == p.name && !draft.isNew && draft.original == p)
			#expect(draft.previewSettings == p.settings, "\(p.name)")
		}
		// "없음" (arrange by none, no groups) is a value, not "유지".
		#expect(PresetDraft(preset: presets[4]).arrangeBy == SortKey.none)
		#expect(PresetDraft(preset: presets[7]).groupBy == GroupBy.none && PresetDraft(preset: presets[6]).groupBy == .dateAdded)
		#expect(PresetDraft(preset: presets[0]).groupBy == nil)
		#expect(PresetDraft(preset: presets[1]).iconSize.isEmpty && PresetDraft(preset: presets[1]).arrangeBy == nil)
	}

	/// Numbers: empty = "유지", spaces are ignored, a finite number is brought to the nearest value Finder offers (text
	/// sizes rounded to whole points first), and only a text that is not a finite number is refused.
	@Test func numberFields() {
		typealias N = PresetDraft.Number
		func value(_ text: String, _ n: N) -> Double?? { if case .success(let v) = PresetDraft.parse(text, as: n) { v } else { nil } }
		#expect(value("", .iconSize) == .some(nil) && value("   ", .iconSize) == .some(nil))
		#expect(value(" 48 ", .iconSize) == 48 && value("16", .iconSize) == 16 && value("512", .iconSize) == 512 && value("57.5", .iconSize) == 57.5)
		#expect(value("15.9", .iconSize) == 16 && value("513", .iconSize) == 512 && value("900000000000000", .iconSize) == 512)
		#expect(value("-3", .iconSize) == 16 && value("1e300", .iconSize) == 512)
		#expect(PresetDraft.parse("abc", as: .iconSize) == .failure(.notANumber(.iconSize, "abc")))
		#expect(PresetDraft.parse("nan", as: .iconSize) == .failure(.notANumber(.iconSize, "nan")))
		#expect(PresetDraft.parse("inf", as: .gridSpacing) == .failure(.notANumber(.gridSpacing, "inf")))
		#expect(PresetDraft.parse("48px", as: .iconSize) == .failure(.notANumber(.iconSize, "48px")))
		#expect(value("10", .iconTextSize) == 10 && value("16", .listTextSize) == 16)
		#expect(value("12.5", .iconTextSize) == 13 && value("12.4", .iconTextSize) == 12 && value("16.4", .listTextSize) == 16)
		#expect(value("9", .listTextSize) == 10 && value("17", .listTextSize) == 16 && value("9.6", .listTextSize) == 10)
		#expect(value("1", .gridSpacing) == 1 && value("100", .gridSpacing) == 100 && value("33.3", .gridSpacing) == 33.3)
		#expect(value("0", .gridSpacing) == 1 && value("101", .gridSpacing) == 100)
		#expect(PresetDraft.parse("1e999", as: .iconSize) == .failure(.notANumber(.iconSize, "1e999")))
		#expect(PresetDraft.text(48) == "48" && PresetDraft.text(57.5) == "57.5" && PresetDraft.text(nil) == "")
	}

	/// A committed field (Return, the focus left it, "저장") shows the value it saves; while it is typed it keeps the text
	/// ("1" on the way to "12" is not turned into 10), and a text that is not a number, "유지" and a value kept from the
	/// preset stay as they are.
	@Test func committedFieldsShowTheClampedValue() {
		let preset = Preset(name: "p", settings: ViewSettings(icon: IconViewSettings(iconSize: 1000, textSize: 12.5)))
		var d = PresetDraft(preset: preset)
		d.gridSpacing = "900000000000000"
		d.listTextSize = "1"
		#expect(d.gridSpacing == "900000000000000" && d.listTextSize == "1")     // typing: shown as typed
		#expect(d.check(others: []).settings?.icon.gridSpacing == 100 && d.check(others: []).settings?.list.textSize == 10)
		d.commitNumber(.gridSpacing)
		#expect(d.gridSpacing == "100")
		d.listTextSize = " 12.6 "
		d.iconSize = "abc"
		let all = d.committed
		#expect(all.listTextSize == "13" && all.iconSize == "abc" && all.iconTextSize == "12.5" && all.gridSpacing == "100")
		#expect(all.check(others: []) == d.check(others: []))                  // committing never changes what is saved
		var kept = PresetDraft(preset: preset)
		kept.iconSize = " 1000 "                                                   // the preset's own value, retyped
		#expect(kept.committed.iconSize == "1000" && kept.committed.check(others: []).settings == preset.settings)
		let fresh = PresetDraft(newName: "n")
		#expect(fresh.committed == fresh)                                          // "유지" stays empty
	}

	/// Everything that cannot be saved is named (and blocks the save); a duplicate name and an empty preset only warn.
	@Test func checkRefusesAndWarns() {
		let other = Preset(name: "Photos", settings: Self.full)
		var d = PresetDraft(preset: Preset(name: "Mine", settings: Self.full))
		d.name = "  "
		d.iconSize = "600"                  // a number: clamped to 512, not refused
		d.iconTextSize = "12,5"
		d.gridSpacing = "x"
		d.sortColumn = nil               // the direction is still set: it cannot be written alone
		d.listIconSize = 20
		let bad = d.check(others: [other])
		#expect(!bad.canSave && bad.settings == nil)
		#expect(bad.problems == [.emptyName, .notANumber(.iconTextSize, "12,5"), .notANumber(.gridSpacing, "x"),
		                         .directionWithoutColumn, .listIconSize(20)])
		#expect(bad.nameInvalid && !bad.isInvalid(.iconSize) && bad.isInvalid(.iconTextSize) && bad.isInvalid(.gridSpacing) && !bad.isInvalid(.listTextSize))
		#expect(bad.directionInvalid && bad.listIconSizeInvalid)
		#expect(bad.problems.allSatisfy { !$0.message.isEmpty })

		var dup = PresetDraft(preset: Preset(name: "Mine", settings: Self.full))
		dup.name = "  photos "
		let warned = dup.check(others: [other])
		#expect(warned.canSave && warned.name == "photos" && warned.warnings.count == 1)
		// The preset being edited is not compared with itself.
		#expect(PresetDraft(preset: other).check(others: []).warnings.isEmpty)
		let empty = PresetDraft(newName: "New").check(others: [])
		#expect(empty.canSave && empty.settings == ViewSettings() && empty.warnings.count == 1)
	}

	/// A value the preset already had is kept as it is, even outside what the editor offers; a typed one is clamped.
	@Test func keptValuesFromThePreset() {
		let odd = Preset(name: "odd", settings: ViewSettings(icon: IconViewSettings(textSize: 12.5, gridSpacing: 150), list: ListViewSettings(iconSize: 20)))
		var d = PresetDraft(preset: odd)
		#expect(d.check(others: []).settings == odd.settings)
		d.commitNumber(.gridSpacing)
		d.commitNumber(.iconTextSize)
		#expect(d.gridSpacing == "150" && d.iconTextSize == "12.5")
		d.gridSpacing = "151"
		#expect(d.check(others: []).problems.isEmpty && d.check(others: []).settings?.icon.gridSpacing == 100)
		d.gridSpacing = "150"
		d.listIconSize = 24
		#expect(d.check(others: []).problems == [.listIconSize(24)])
		var n = PresetDraft(newName: "n")
		n.listIconSize = 20
		#expect(n.check(others: []).problems == [.listIconSize(20)])
	}

	/// "새 프리셋", then " 2", " 3" … for names already taken (ignoring case, like `finder-presets`).
	@Test func newPresetNames() {
		let base = "새 프리셋"
		#expect(PresetDraft.newName(taken: []) == base)
		#expect(PresetDraft.newName(taken: [base.uppercased(), "x"]) == "\(base) 2")
		#expect(PresetDraft.newName(taken: [base, "\(base) 2", "\(base) 3"]) == "\(base) 4")
		let draft = PresetDraft(newName: base)
		#expect(draft.isNew && draft.original == nil && draft.check(others: []).settings == ViewSettings())
	}

	/// `commit` in a temporary data folder: a new preset gets its own file; an edit keeps the ID and creation date; an
	/// unchanged edit writes nothing; a file changed or removed since the editor opened is never overwritten.
	@Test func commitWritesOnlyWhatItShould() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-preset-editor-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: base) }
		let store = PresetStore(dirs: AppDirectories(root: base))
		func file(_ id: UUID) -> URL { store.dirs.presets.appendingPathComponent("\(id.uuidString).json") }

		var fresh = PresetDraft(newName: "Fresh")
		fresh.viewStyle = .list
		fresh.listTextSize = "12"
		fresh.groupBy = .kind
		let check = fresh.check(others: [])
		let created = try PresetDraft.commit(fresh, name: check.name, settings: try #require(check.settings), store: store)
		#expect(try store.list() == [created])
		#expect(created.name == "Fresh" && created.settings == ViewSettings(viewStyle: .list, list: ListViewSettings(textSize: 12), groupBy: .kind))
		// A preset with only a grouping sets something: no "모든 값이 유지" warning.
		var onlyGroup = PresetDraft(newName: "G")
		onlyGroup.groupBy = GroupBy.none
		#expect(onlyGroup.check(others: []).warnings.isEmpty && onlyGroup.check(others: []).settings == ViewSettings(groupBy: GroupBy.none))

		var edit = PresetDraft(preset: created)
		edit.name = "Fresh 2"
		edit.iconSize = "96"
		let editCheck = edit.check(others: [])
		let edited = try PresetDraft.commit(edit, name: editCheck.name, settings: try #require(editCheck.settings), store: store)
		#expect(edited.id == created.id && edited.createdAt == created.createdAt && edited.schemaVersion == created.schemaVersion)
		#expect(edited.name == "Fresh 2" && edited.settings.icon.iconSize == 96 && edited.settings.list.textSize == 12 && edited.settings.groupBy == .kind)
		#expect(try store.list() == [edited])

		// Unchanged: nothing is written (the file stays byte for byte, updatedAt included).
		let bytes = try Data(contentsOf: file(edited.id))
		let same = PresetDraft(preset: edited)
		let sameCheck = same.check(others: [])
		#expect(try PresetDraft.commit(same, name: sameCheck.name, settings: try #require(sameCheck.settings), store: store) == edited)
		#expect(try Data(contentsOf: file(edited.id)) == bytes)

		// Changed elsewhere after the editor opened (e.g. finder-presets preset-set): refused, the other change stays.
		var late = PresetDraft(preset: edited)
		late.iconSize = "200"
		var outside = edited
		outside.settings.icon.iconSize = 128
		try store.save(outside)
		let lateCheck = late.check(others: [])
		#expect(throws: PresetDraft.CommitError.changedOnDisk) {
			try PresetDraft.commit(late, name: lateCheck.name, settings: try #require(lateCheck.settings), store: store)
		}
		#expect(try store.list().first?.settings.icon.iconSize == 128)

		// Removed meanwhile: refused, nothing is written back.
		try FileManager.default.removeItem(at: file(edited.id))
		#expect(throws: PresetDraft.CommitError.missing) {
			try PresetDraft.commit(late, name: lateCheck.name, settings: try #require(lateCheck.settings), store: store)
		}
		#expect(try store.list().isEmpty)
	}

	/// The sliders: "유지" rests at Finder's factory value, a position is snapped to the slider's steps inside the range,
	/// and a position equal to where the slider stands (a slider that only reports itself) changes nothing — so "유지"
	/// stays "유지" and a value the preset had outside the slider (or between its steps) is kept until the user moves it.
	@Test func sliderBinding() {
		typealias N = PresetDraft.Number
		#expect(N.allCases.map(\.view) == [.icon, .icon, .icon, .list])
		#expect(PresetDraft.sliderValue(47, .iconSize) == 48 && PresetDraft.sliderValue(45.9, .iconSize) == 44 && PresetDraft.sliderValue(1000, .iconSize) == 512)
		#expect(PresetDraft.sliderValue(0, .gridSpacing) == 1 && PresetDraft.sliderValue(33.4, .gridSpacing) == 33 && PresetDraft.sliderValue(12.6, .listTextSize) == 13)
		#expect(PresetDraft.sliderValue(.nan, .iconTextSize) == 12)
		var d = PresetDraft(newName: "n")
		#expect(d.isKept(.iconSize) && d.sliderPosition(.iconSize) == 64 && d.sliderPosition(.gridSpacing) == 54)
		#expect(d.sliderPosition(.iconTextSize) == 12 && d.sliderPosition(.listTextSize) == 13)
		d.setFromSlider(.iconSize, 64)              // not moved: still "유지"
		d.setFromSlider(.listTextSize, 13.2)
		#expect(d.isKept(.iconSize) && d.isKept(.listTextSize) && d.check(others: []).settings == ViewSettings())
		d.setFromSlider(.iconSize, 129)
		d.setFromSlider(.listTextSize, 15.6)
		#expect(d.iconSize == "128" && d.listTextSize == "16" && !d.isKept(.iconSize))
		#expect(d.check(others: []).settings == ViewSettings(icon: IconViewSettings(iconSize: 128), list: ListViewSettings(textSize: 16)))
		// A typed number is drawn where it is saved (clamped, text sizes whole).
		d.iconSize = "900000"
		d.listTextSize = "12.4"
		#expect(d.sliderPosition(.iconSize) == 512 && d.sliderPosition(.listTextSize) == 12)
		d.setFromSlider(.iconSize, 512)             // the slider only reports where it stands: the text stays as typed
		#expect(d.iconSize == "900000")
		// A typed text that is not a number rests the slider at the factory value; moving it replaces the text.
		d.gridSpacing = "abc"
		#expect(d.sliderPosition(.gridSpacing) == 54)
		d.setFromSlider(.gridSpacing, 20)
		#expect(d.gridSpacing == "20")
		// × (an empty field) is "유지" again.
		d.iconSize = ""
		#expect(d.isKept(.iconSize) && d.sliderPosition(.iconSize) == 64)
		// Values the preset had outside the slider are drawn clamped and kept as they are.
		let odd = Preset(name: "odd", settings: ViewSettings(icon: IconViewSettings(iconSize: 1000, textSize: 12.5, gridSpacing: 45.25)))
		var o = PresetDraft(preset: odd)
		#expect(o.sliderPosition(.iconSize) == 512 && o.sliderPosition(.gridSpacing) == 45.25 && o.sliderPosition(.iconTextSize) == 12.5)
		o.setFromSlider(.iconSize, 512)
		#expect(o.iconSize == "1000" && o.check(others: []).settings == odd.settings)
		o.setFromSlider(.iconSize, 508)
		#expect(o.iconSize == "508")
	}

	/// The view control is the preset's view style ("유지" = nil). Choosing a view changes nothing else: the values of the
	/// views not selected are kept and saved unchanged, and named as hidden.
	@Test func viewControlIsTheViewStyle() {
		let preset = Preset(name: "full", settings: Self.full)
		var d = PresetDraft(preset: preset)
		#expect(ViewSwitcher.choices == [nil, .icon, .list, .column, .gallery])
		#expect(ViewSwitcher.choices.map(ViewSwitcher.index) == [0, 1, 2, 3, 4])
		#expect(d.viewStyle == .icon && d.viewsWithValues == [.icon, .list] && d.hiddenViewsWithValues == [.list])
		for view in ViewSwitcher.choices {
			var e = PresetDraft(preset: preset)
			#expect(e.selectView(view).isEmpty)
			var expected = Self.full
			expected.viewStyle = view
			#expect(e.viewStyle == view && e.check(others: []).settings == expected, "\(String(describing: view))")
			#expect(e == PresetDraft(preset: Preset(name: "full", settings: expected)).with(token: e.token).with(original: preset))
		}
		d.selectView(.gallery)
		#expect(d.hiddenViewsWithValues == [.icon, .list] && EditorText.hiddenValues(d.hiddenViewsWithValues) != nil)
		d.selectView(nil)
		#expect(d.viewStyle == nil && d.hiddenViewsWithValues == [.icon, .list])
		var expected = Self.full
		expected.viewStyle = nil
		#expect(d.check(others: []).settings == expected)
		for view in ViewStyle.allCases {
			var e = PresetDraft(newName: "n")
			e.selectView(view)
			#expect(e.check(others: []).settings == ViewSettings(viewStyle: view) && e.hiddenViewsWithValues.isEmpty)
		}
		// Every choice has its own caption and panel name; the hidden-values note names icon, list or both.
		#expect(Set(ViewSwitcher.choices.map(EditorText.result)).count == 5 && Set(ViewSwitcher.choices.map(EditorText.viewTitle)).count == 5)
		#expect(EditorText.hiddenValues([]) == nil)
		#expect(Set([[.icon], [.list], [.icon, .list]].compactMap(EditorText.hiddenValues)).count == 3)
		#expect(ViewStyle.allCases.map(ViewSwitcher.symbol) == ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "squares.below.rectangle"])
	}

	/// A typed text that cannot be saved (not a number) and that the chosen view does not show goes back to the preset's
	/// value (empty for a new preset), so it never blocks "저장" out of sight; the numbers of the chosen view, valid (or
	/// clamped) values and values kept from the preset are never touched.
	@Test func invalidHiddenNumbersGoBack() {
		let preset = Preset(name: "p", settings: ViewSettings(viewStyle: .icon, icon: IconViewSettings(iconSize: 48, gridSpacing: 150),
		                                                      list: ListViewSettings(textSize: 11)))
		var d = PresetDraft(preset: preset)
		(d.iconSize, d.iconTextSize, d.listTextSize) = ("6OO", "12,5", "x")
		#expect(d.check(others: []).problems.count == 3)
		// Icon view shows the icon numbers: only the list text size (hidden) goes back.
		#expect(d.selectView(.icon) == [.listTextSize] && d.listTextSize == "11" && d.iconSize == "6OO" && d.iconTextSize == "12,5")
		#expect(d.check(others: []).problems == [.notANumber(.iconSize, "6OO"), .notANumber(.iconTextSize, "12,5")])
		// List view: the icon numbers go back (48 and "유지"); the grid spacing kept from the preset (150) stays.
		#expect(d.selectView(.list) == [.iconSize, .iconTextSize] && d.iconSize == "48" && d.iconTextSize.isEmpty && d.gridSpacing == "150")
		#expect(d.check(others: []).canSave)
		var saved = preset.settings
		saved.viewStyle = .list
		#expect(d.check(others: []).settings == saved)
		// "유지", column and gallery show no number: every invalid one goes back; a valid typed one stays.
		for view in [nil, ViewStyle.column, .gallery] {
			var n = PresetDraft(newName: "n")
			(n.iconSize, n.gridSpacing, n.listTextSize, n.iconTextSize) = ("abc", "40", "1x7", "17")
			#expect(n.selectView(view) == [.iconSize, .listTextSize] && n.iconSize.isEmpty && n.listTextSize.isEmpty && n.gridSpacing == "40")
			#expect(n.iconTextSize == "17")
			#expect(n.check(others: []).settings == ViewSettings(viewStyle: view, icon: IconViewSettings(textSize: 16, gridSpacing: 40)))
		}
	}

	/// A preset with only a view style and a grouping (Finder's column view has "그룹 기준" too): no view holds values,
	/// and the grouping is kept through a save whatever view is chosen.
	@Test func groupingOnlyPreset() throws {
		let preset = Preset(name: "g", settings: ViewSettings(viewStyle: .column, groupBy: .kind))
		var draft = PresetDraft(preset: preset)
		#expect(draft.viewsWithValues.isEmpty && draft.hiddenViewsWithValues.isEmpty)
		#expect(ViewStyle.allCases.allSatisfy { !draft.hasValues(for: $0) })
		let check = draft.check(others: [])
		#expect(check.canSave && check.warnings.isEmpty && check.settings == preset.settings)
		draft.selectView(nil)
		#expect(draft.check(others: []).settings == ViewSettings(groupBy: .kind))
		var typed = PresetDraft(newName: "n")
		typed.gridSpacing = "abc"
		#expect(typed.hasValues(for: .icon) && !typed.hasValues(for: .list))
		typed.gridSpacing = "  "
		#expect(!typed.hasValues(for: .icon))
	}

	/// The sheet has one fixed size inside the window's content for every view, from the tallest panel (eight options),
	/// a row holds a name, a menu and the grouping's hint, and a number row its name, slider, field, × and range.
	@Test func editorSheetFitsTheWindow() {
		typealias S = PresetEditorSheet
		let c = UILayout.content
		#expect(S.size.width <= c.width - 40 && S.size.height <= c.height - 20)
		// Padding, header, name row, panel, bottom row, with 10pt between them.
		let parts: [CGFloat] = [16, S.headerHeight, 10, S.topRowHeight, 10, S.panelHeight, 10, S.footerHeight, 16]
		#expect(S.size.height == parts.reduce(0, +))
		// The panel: padding, then the eight options.
		#expect(S.maxRows == 8 && S.panelHeight == 220)
		let inner = S.size.width - 32 - S.panelPadding.leading - S.panelPadding.trailing
		#expect(S.labelWidth + 6 + S.menuWidth + 6 + 120 <= inner)
		#expect(S.labelWidth + 6 + S.sliderWidth + 6 + S.numberWidth + 6 + 16 + 6 + 60 <= inner)
	}
}

private extension PresetDraft {
	/// The same draft with another opening's token (a draft opened twice differs only in it).
	func with(token: UUID) -> PresetDraft {
		var copy = self
		copy.token = token
		return copy
	}

	/// The same values opened for another preset (compares drafts made from two presets by their values only).
	func with(original: Preset) -> PresetDraft {
		var copy = self
		copy.original = original
		copy.name = original.name
		return copy
	}
}

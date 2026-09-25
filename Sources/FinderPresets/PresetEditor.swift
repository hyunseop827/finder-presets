import Foundation
import FinderPresetsCore

/// What the preset editor ("편집…", "새 프리셋…") holds while it is open: every option of a preset, each one either set
/// or "유지" (nil / an empty number field: the option is left as it is in each folder). Numbers are kept as the typed text
/// so that typing is never fought (a "1" on the way to "12"): a typed number stands for the nearest value Finder offers
/// (`Number.clamped`), shown in the field once it is committed (`commitNumber`), and a text that is not a number is shown
/// and refused instead of being silently changed. Nothing is written before `AppModel.savePresetEdit`; the sheet only
/// edits its own copy.
struct PresetDraft: Equatable {
	/// The number options. The ranges are what Finder offers (icon size 16–512, text size 10–16 in whole points); grid
	/// spacing has no verified range, so the editor keeps it to Finder's slider (1–100).
	enum Number: String, CaseIterable, Sendable {
		case iconSize, iconTextSize, gridSpacing, listTextSize

		var range: ClosedRange<Double> {
			switch self {
			case .iconSize: PresetLimits.iconSize
			case .iconTextSize, .listTextSize: PresetLimits.textSize
			case .gridSpacing: PresetLimits.gridSpacing
			}
		}
		/// Text sizes are whole points (Finder's menu offers 10–16); the other two are sliders in Finder and take any
		/// typed value.
		var wholeNumbers: Bool { self == .iconTextSize || self == .listTextSize }
		/// The value a typed number stands for: the nearest one Finder offers (900000 → 512, 8 → 16, a text size of
		/// 12.4 → 12). The user asked for the largest size, not for a refusal; the CLI's `preset-set` still refuses.
		func clamped(_ value: Double) -> Double {
			min(range.upperBound, max(range.lowerBound, wholeNumbers ? value.rounded() : value))
		}
		/// A value the editor's slider sets lies on these steps from the lower end (a typed value need not).
		var step: Double { self == .iconSize ? 4 : 1 }
		/// The view whose panel shows the option.
		var view: ViewStyle { self == .listTextSize ? .list : .icon }
		/// Where the slider rests while the option is "유지" and Finder's current default is not known: Finder's factory
		/// value (ViewRecordCodec). The editor uses `PresetDraft.restPositions` (Finder's current defaults) first.
		var start: Double {
			switch self {
			case .iconSize: 64
			case .iconTextSize: 12
			case .gridSpacing: 54
			case .listTextSize: 13
			}
		}
		var title: String {
			switch self {
			case .iconSize: String(localized: "아이콘 크기")
			case .iconTextSize, .listTextSize: String(localized: "텍스트 크기")
			case .gridSpacing: String(localized: "격자 간격")
			}
		}
		/// The name in a message, with its view ("아이콘 보기 · 텍스트 크기").
		var fullTitle: String {
			switch self {
			case .iconSize, .iconTextSize, .gridSpacing: String(localized: "아이콘 보기") + " · " + title
			case .listTextSize: String(localized: "목록 보기") + " · " + title
			}
		}
		/// "16–512"
		var rangeText: String { "\(PresetDraft.text(range.lowerBound))–\(PresetDraft.text(range.upperBound))" }
	}

	/// Why a value cannot be saved (shown in the sheet; the offending field's name turns to the warning color).
	enum Problem: Error, Equatable {
		case emptyName
		case notANumber(Number, String)
		case directionWithoutColumn
		case listIconSize(Double)

		var message: String {
			switch self {
			case .emptyName:
				String(localized: "이름을 넣으세요.")
			case .notANumber(let n, let text):
				String(localized: "\(n.fullTitle): 숫자가 아닙니다(\"\(text)\"). \(n.rangeText) 사이의 숫자를 넣거나 비워 두세요(유지).")
			case .directionWithoutColumn:
				String(localized: "정렬 방향은 정렬 열을 고른 뒤에만 정할 수 있습니다.")
			case .listIconSize(let value):
				String(localized: "목록 보기의 아이콘 크기는 작게(16)나 크게(32)만 쓸 수 있습니다(지금: \(PresetDraft.text(value))).")
			}
		}

		var field: Number? {
			switch self {
			case .notANumber(let n, _): n
			default: nil
			}
		}
	}

	/// The result of checking a draft: the settings it saves (nil while anything is invalid), what is wrong, and what is
	/// only worth a warning (a name another preset already has, a preset that sets nothing).
	struct Check: Equatable {
		var name: String
		var settings: ViewSettings?
		var problems: [Problem]
		var warnings: [String]

		var canSave: Bool { settings != nil }
		func isInvalid(_ number: Number) -> Bool { problems.contains { $0.field == number } }
		var nameInvalid: Bool { problems.contains(.emptyName) }
		var directionInvalid: Bool { problems.contains(.directionWithoutColumn) }
		var listIconSizeInvalid: Bool { problems.contains { if case .listIconSize = $0 { true } else { false } } }
	}

	/// Opened for this preset; nil for a new preset (nothing on disk until it is saved).
	var original: Preset?
	/// A new identity per opening, so the sheet starts from this draft even while another one is shown.
	var token = UUID()
	var name: String
	var viewStyle: ViewStyle?
	var groupBy: GroupBy?
	var iconSize = ""
	var iconTextSize = ""
	var arrangeBy: SortKey?
	var labelOnBottom: Bool?
	var showItemInfo: Bool?
	var iconShowPreview: Bool?
	var gridSpacing = ""
	var sortColumn: ListColumn?
	var sortAscending: Bool?
	var listTextSize = ""
	var listIconSize: Double?
	var listShowPreview: Bool?
	var useRelativeDates: Bool?
	var calculateAllSizes: Bool?

	/// Where each number's slider rests while the option is "유지": Finder's current default for it, the value the preview
	/// window draws for "유지" (`PresetPreview`, one source for both), set when the editor opens
	/// (`AppModel.beginEditPreset`, `beginNewPreset`). An option missing here rests at its factory value (`Number.start`).
	var restPositions: [Number: Double] = [:]

	var isNew: Bool { original == nil }

	/// A new preset: every option "유지".
	init(newName: String) {
		name = newName
	}

	/// The preset's values as they are (a value the editor cannot show exactly, such as an odd list icon size, is kept).
	init(preset: Preset) {
		original = preset
		name = preset.name
		let s = preset.settings
		viewStyle = s.viewStyle
		groupBy = s.groupBy
		iconSize = Self.text(s.icon.iconSize)
		iconTextSize = Self.text(s.icon.textSize)
		arrangeBy = s.icon.arrangeBy
		labelOnBottom = s.icon.labelOnBottom
		showItemInfo = s.icon.showItemInfo
		iconShowPreview = s.icon.showIconPreview
		gridSpacing = Self.text(s.icon.gridSpacing)
		sortColumn = s.list.sortColumn
		sortAscending = s.list.sortAscending
		listTextSize = Self.text(s.list.textSize)
		listIconSize = s.list.iconSize
		listShowPreview = s.list.showIconPreview
		useRelativeDates = s.list.useRelativeDates
		calculateAllSizes = s.list.calculateAllSizes
	}

	subscript(number: Number) -> String {
		get {
			switch number {
			case .iconSize: iconSize
			case .iconTextSize: iconTextSize
			case .gridSpacing: gridSpacing
			case .listTextSize: listTextSize
			}
		}
		set {
			switch number {
			case .iconSize: iconSize = newValue
			case .iconTextSize: iconTextSize = newValue
			case .gridSpacing: gridSpacing = newValue
			case .listTextSize: listTextSize = newValue
			}
		}
	}

	/// The value the edited preset had for `number` (nil for a new preset or an option it left alone).
	func originalValue(_ number: Number) -> Double? {
		guard let s = original?.settings else { return nil }
		switch number {
		case .iconSize: return s.icon.iconSize
		case .iconTextSize: return s.icon.textSize
		case .gridSpacing: return s.icon.gridSpacing
		case .listTextSize: return s.list.textSize
		}
	}

	/// What `number` saves: nil for an empty field ("유지"), else the typed value brought into range, or why it cannot be
	/// saved. A value the preset already had (read from a folder Finder wrote) is kept as it is, even outside the range the
	/// editor offers: only what is typed here is clamped.
	func value(_ number: Number) -> Result<Double?, Problem> {
		if let kept = originalValue(number), Double(self[number].trimmingCharacters(in: .whitespacesAndNewlines)) == kept {
			return .success(kept)
		}
		return Self.parse(self[number], as: number)
	}

	/// The field of `number` was committed (Return, the focus left it, "저장"): a typed number shows the value it saves
	/// ("900" → "512", "12.4" → "12"). Not done on every keystroke, which would turn the "1" of "12" into "10" while
	/// typing; a text that is not a number stays as typed, with its warning.
	mutating func commitNumber(_ number: Number) {
		guard case .success(let value?) = value(number) else { return }
		let text = Self.text(value)
		if self[number] != text { self[number] = text }
	}

	/// Every number field committed (what "저장" does first, so the fields show what is written).
	var committed: PresetDraft {
		var copy = self
		for number in Number.allCases { copy.commitNumber(number) }
		return copy
	}

	/// "48", "48.5", "" for nil.
	static func text(_ value: Double?) -> String { value.map(Fmt.number) ?? "" }

	/// nil for an empty field ("유지"), the nearest value Finder offers when it is a finite number (`Number.clamped`), else
	/// why not.
	static func parse(_ text: String, as number: Number) -> Result<Double?, Problem> {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return .success(nil) }
		guard let value = Double(trimmed), value.isFinite else { return .failure(.notANumber(number, trimmed)) }
		return .success(number.clamped(value))
	}

	// MARK: Sliders (icon size, grid spacing, text sizes: a slider next to the number field)

	/// Whether `number` is "유지" (its field is empty).
	func isKept(_ number: Number) -> Bool { self[number].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

	/// Where the slider of `number` stands: the value the field saves, drawn inside the range (a typed 900 at 512; a value
	/// the preset already had outside it, such as a grid spacing of 150, only moves the knob to the end; the value itself
	/// is kept), else — "유지" or a text that is not a number — where it rests dimmed (`restPosition`).
	func sliderPosition(_ number: Number) -> Double {
		guard case .success(let value?) = value(number) else { return restPosition(number) }
		return min(number.range.upperBound, max(number.range.lowerBound, value))
	}

	/// Where the slider of an option left "유지" rests: Finder's current default (`restPositions`), else the factory value,
	/// drawn inside the slider's range.
	func restPosition(_ number: Number) -> Double {
		let value = restPositions[number].flatMap { $0.isFinite ? $0 : nil } ?? number.start
		return min(number.range.upperBound, max(number.range.lowerBound, value))
	}

	/// The rest positions for Finder's current defaults (`GlobalDefaults.effectiveSettings`).
	static func restPositions(_ defaults: ViewSettings) -> [Number: Double] {
		var out: [Number: Double] = [:]
		out[.iconSize] = defaults.icon.iconSize
		out[.iconTextSize] = defaults.icon.textSize
		out[.gridSpacing] = defaults.icon.gridSpacing
		out[.listTextSize] = defaults.list.textSize
		return out
	}

	/// The value a slider position stands for: on the slider's steps from the lower end, inside the range.
	static func sliderValue(_ position: Double, _ number: Number) -> Double {
		guard position.isFinite else { return number.start }   // never set by a real slider
		let r = number.range
		let snapped = r.lowerBound + ((position - r.lowerBound) / number.step).rounded() * number.step
		return min(r.upperBound, max(r.lowerBound, snapped))
	}

	/// The slider moved: the option takes the position's value. A position equal to where the slider already stands
	/// changes nothing, so a slider that only reports its own position (never moved by the user) never turns "유지" into a
	/// value or rewrites a value the preset already had (e.g. 150 drawn at 100).
	mutating func setFromSlider(_ number: Number, _ position: Double) {
		let value = Self.sliderValue(position, number)
		guard value != sliderPosition(number) else { return }
		self[number] = Self.text(value)
	}

	/// Checks everything. `others`: the presets other than the one being edited (for the duplicate-name warning).
	func check(others: [Preset]) -> Check {
		var problems: [Problem] = []
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { problems.append(.emptyName) }
		var numbers: [Number: Double] = [:]
		for number in Number.allCases {
			switch value(number) {
			case .success(let value): numbers[number] = value
			case .failure(let problem): problems.append(problem)
			}
		}
		// The direction lives in the sort column's entry: alone it could never be written (ListViewSettings).
		if sortAscending != nil && sortColumn == nil { problems.append(.directionWithoutColumn) }
		// Finder's list view has two icon sizes; another value is only kept when the preset already had it.
		if let size = listIconSize, !PresetLimits.listIconSizes.contains(size), size != original?.settings.list.iconSize { problems.append(.listIconSize(size)) }

		let settings = ViewSettings(
			viewStyle: viewStyle,
			icon: IconViewSettings(iconSize: numbers[.iconSize], textSize: numbers[.iconTextSize], labelOnBottom: labelOnBottom,
			                       showItemInfo: showItemInfo, showIconPreview: iconShowPreview, arrangeBy: arrangeBy,
			                       gridSpacing: numbers[.gridSpacing]),
			list: ListViewSettings(textSize: numbers[.listTextSize], iconSize: listIconSize, sortColumn: sortColumn,
			                       sortAscending: sortAscending, showIconPreview: listShowPreview, useRelativeDates: useRelativeDates,
			                       calculateAllSizes: calculateAllSizes),
			groupBy: groupBy)
		var warnings: [String] = []
		if !trimmed.isEmpty, others.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame }) {
			warnings.append(String(localized: "같은 이름의 프리셋이 이미 있습니다. 목록과 폴더 행의 프리셋 메뉴에서 구별하기 어렵습니다."))
		}
		if settings.isEmpty {
			warnings.append(String(localized: "모든 값이 \"유지\"입니다. 이 프리셋은 적용해도 폴더를 바꾸지 않습니다."))
		}
		return Check(name: trimmed, settings: problems.isEmpty ? settings : nil, problems: problems, warnings: warnings)
	}

	// MARK: Views (the editor's view control: "유지" and Finder's four views)

	/// The view control of the editor: `view` becomes the preset's view style (nil: "유지"), and the panel shows that
	/// view's options. Nothing else is touched — the values of the other views stay and are saved unchanged — except a
	/// typed text the new view does not show and that could not be saved (not a number): it goes back to the preset's value (empty for
	/// "유지"), so a field that is no longer on screen never blocks "저장". Returns the numbers put back (the sheet names them).
	@discardableResult
	mutating func selectView(_ view: ViewStyle?) -> [Number] {
		viewStyle = view
		var reset: [Number] = []
		for number in Number.allCases where number.view != view {
			if case .failure = value(number) {
				self[number] = Self.text(originalValue(number))
				reset.append(number)
			}
		}
		return reset
	}

	/// Whether the options of `view` hold anything other than "유지" (a typed text counts, valid or not, so a view with a
	/// value that cannot be saved is named too). The grouping is shared by every view and is not counted for any of
	/// them; column and gallery view have no options in a preset (only the view style), so they never hold values.
	func hasValues(for view: ViewStyle) -> Bool {
		func typed(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		switch view {
		case .icon:
			return typed(iconSize) || typed(iconTextSize) || typed(gridSpacing)
				|| arrangeBy != nil || labelOnBottom != nil || showItemInfo != nil || iconShowPreview != nil
		case .list:
			return typed(listTextSize) || sortColumn != nil || sortAscending != nil || listIconSize != nil
				|| listShowPreview != nil || useRelativeDates != nil || calculateAllSizes != nil
		case .column, .gallery:
			return false
		}
	}

	/// The views whose options hold values, in the view control's order.
	var viewsWithValues: [ViewStyle] { ViewStyle.allCases.filter(hasValues(for:)) }

	/// The views that hold values the panel does not show (all of them unless the view style is one of them): kept and
	/// saved unchanged, and named at the bottom of the sheet so they are never forgotten.
	var hiddenViewsWithValues: [ViewStyle] { viewsWithValues.filter { $0 != viewStyle } }

	/// What the sheet's preview draws: the values that are valid so far (an invalid number counts as "유지").
	var previewSettings: ViewSettings {
		func value(_ n: Number) -> Double? { if case .success(let v) = self.value(n) { v } else { nil } }
		return ViewSettings(
			viewStyle: viewStyle,
			icon: IconViewSettings(iconSize: value(.iconSize), textSize: value(.iconTextSize), labelOnBottom: labelOnBottom,
			                       showItemInfo: showItemInfo, showIconPreview: iconShowPreview, arrangeBy: arrangeBy, gridSpacing: value(.gridSpacing)),
			list: ListViewSettings(textSize: value(.listTextSize), iconSize: listIconSize, sortColumn: sortColumn,
			                       sortAscending: sortColumn == nil ? nil : sortAscending, showIconPreview: listShowPreview,
			                       useRelativeDates: useRelativeDates, calculateAllSizes: calculateAllSizes),
			groupBy: groupBy)
	}

	/// "새 프리셋", or "새 프리셋 2", "새 프리셋 3", … when the name is taken (compared like `finder-presets`, ignoring case).
	static func newName(taken: [String]) -> String {
		uniqueName(String(localized: "새 프리셋")) { name in taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
	}

	/// `base`, or "`base` 2", "`base` 3", … — the first name that is not `taken` (a new preset, one made from a folder, an
	/// imported one).
	static func uniqueName(_ base: String, taken: (String) -> Bool) -> String {
		guard taken(base) else { return base }
		var n = 2
		while taken("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	enum CommitError: Error, Equatable {
		/// The edited preset's file is gone or cannot be read any more (removed or rewritten outside the app).
		case missing
		/// The file changed since the editor opened (e.g. `finder-presets preset-set`): saving would silently undo that change.
		case changedOnDisk

		var message: String {
			switch self {
			case .missing:
				String(localized: "프리셋 파일이 없어졌거나 읽을 수 없어 저장하지 않았습니다. 목록을 확인하세요.")
			case .changedOnDisk:
				String(localized: "편집하는 동안 프리셋 파일이 다른 곳에서 바뀌어 저장하지 않았습니다. 취소한 뒤 다시 여세요.")
			}
		}
	}

	/// Writes the draft: a new preset gets a new ID; an edited one keeps its ID, creation date and schema version. An edit
	/// that changes nothing writes nothing (and returns the original). An edited preset is only written while its file on
	/// disk is still exactly what the editor opened, so a change made elsewhere is never overwritten unseen.
	static func commit(_ draft: PresetDraft, name: String, settings: ViewSettings, store: PresetStore) throws -> Preset {
		guard let original = draft.original else {
			let preset = Preset(name: name, settings: settings)
			try store.save(preset)
			return try store.listReadable().presets.first { $0.id == preset.id } ?? preset
		}
		var edited = original
		edited.name = name
		edited.settings = settings.normalized()
		if edited == original { return original }
		guard let onDisk = try store.listReadable().presets.first(where: { $0.id == original.id }) else { throw CommitError.missing }
		guard onDisk == original else { throw CommitError.changedOnDisk }
		try store.save(edited)
		return try store.listReadable().presets.first { $0.id == edited.id } ?? edited
	}
}

extension AppModel {
	// MARK: Preset editor ("편집…", "새 프리셋…")

	/// The pencil of the summary box, "편집…" in a row's menu and a double-click on a row. The presets are read again first:
	/// a file changed since the list was read (e.g. by `finder-presets preset-set`) opens with what is on disk, so the save's check
	/// against the file (`PresetDraft.commit`) never refuses a draft the user could not have known was stale.
	func beginEditPreset(_ id: UUID) {
		reload()
		guard let preset = preset(id) else {
			report(String(localized: "이 프리셋의 파일이 없어졌거나 읽을 수 없어 편집하지 않습니다."))
			return
		}
		openEditor(PresetDraft(preset: preset))
	}

	/// Shows the editor with `draft`, its sliders at Finder's current defaults for the options left "유지".
	private func openEditor(_ draft: PresetDraft) {
		presetEditorProblem = nil
		var draft = draft
		draft.restPositions = editorRestPositions()
		presetEditor = draft
	}

	/// Finder's current defaults, read again (read only), for the sliders of the options left "유지" and the preview.
	private func editorRestPositions() -> [PresetDraft.Number: Double] {
		refreshGlobals()
		return PresetDraft.restPositions(globals.effectiveSettings)
	}

	/// The "+" of the preset list's header: a new preset with every option "유지", nothing on disk until "저장".
	func beginNewPreset() {
		openEditor(PresetDraft(newName: PresetDraft.newName(taken: presets.map(\.name))))
	}

	/// "취소" (or Esc): nothing is written and nothing else changes.
	func cancelPresetEdit() {
		presetEditor = nil
		presetEditorProblem = nil
	}

	/// The presets a draft's name is compared with: all but the one being edited.
	func presetsOtherThan(_ draft: PresetDraft) -> [Preset] {
		presets.filter { $0.id != draft.original?.id }
	}

	/// Folders assigned to `id` in "2. 적용할 폴더".
	func assignedFolderCount(_ id: UUID?) -> Int {
		guard let id else { return 0 }
		return targets.filter { $0.presetID == id }.count
	}

	/// "저장": checks the draft again, writes it (`PresetDraft.commit`) and closes the editor. The list, the summary box,
	/// the folder rows' capsules and the thumbnails follow at once (reload), and a plan made before the change is thrown
	/// away (`presets` changes the plan stamp). A new preset is selected. Returns false, and keeps the editor open with the
	/// reason, when nothing was saved.
	@discardableResult
	func savePresetEdit(_ draft: PresetDraft) -> Bool {
		let check = draft.check(others: presetsOtherThan(draft))
		guard let settings = check.settings else {
			presetEditor = draft
			presetEditorProblem = check.problems.first?.message
			return false
		}
		let saved: Preset
		do {
			saved = try PresetDraft.commit(draft, name: check.name, settings: settings, store: presetStore)
		} catch {
			presetEditor = draft
			presetEditorProblem = (error as? PresetDraft.CommitError)?.message ?? ErrorText.describe(error)
			// The list shows what is on disk now (the other change, or the preset gone); reopening starts from it.
			if error is PresetDraft.CommitError { reload() }
			return false
		}
		presetEditor = nil
		presetEditorProblem = nil
		if let original = draft.original, saved == original { return true }   // nothing changed, nothing written
		reload()
		if draft.isNew {
			selectedPresetID = saved.id
			status = String(localized: "새 프리셋 \"\(Fmt.name(saved.name))\"을(를) 만들었습니다. 선택하거나 폴더 행에 끌어다 놓아 적용하세요.")
		} else {
			let assigned = assignedFolderCount(saved.id)
			status = String(localized: "프리셋 \"\(Fmt.name(saved.name))\"을(를) 저장했습니다.")
				+ " " + (assigned > 0 ? String(localized: "지정한 폴더 \(assigned)개는 다시 적용해야 새 값으로 바뀝니다.")
				         : String(localized: "폴더는 다시 적용해야 새 값으로 바뀝니다."))
		}
		return true
	}
}

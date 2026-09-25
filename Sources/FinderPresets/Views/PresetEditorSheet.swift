import SwiftUI
import AppKit
import FinderPresetsCore

/// The names the editor shows: the ones of the rest of the app (`Fmt`), the long "유지" of its menus, and the texts that
/// name a view in a sentence (whole sentences per view, so each language can inflect them: "아이콘 보기로", "in Icon view").
enum EditorText {
	static var keep: String { String(localized: "유지 (바꾸지 않음)") }

	/// The caption next to the view control: what applying the preset does to the view.
	static func result(_ view: ViewStyle?) -> String {
		switch view {
		case .icon?: String(localized: "폴더는 아이콘 보기로 열립니다.")
		case .list?: String(localized: "폴더는 목록 보기로 열립니다.")
		case .column?: String(localized: "폴더는 컬럼 보기로 열립니다.")
		case .gallery?: String(localized: "폴더는 갤러리 보기로 열립니다.")
		case nil: String(localized: "폴더마다 지금 보기를 그대로 둡니다.")
		}
	}

	/// An option's view in its accessibility name ("아이콘 보기 · 아이콘 미리보기"), a segment's tooltip and name, and the
	/// panel's accessibility name ("보기 방식 유지" for "유지").
	static func viewTitle(_ view: ViewStyle?) -> String {
		switch view {
		case .icon?: String(localized: "아이콘 보기")
		case .list?: String(localized: "목록 보기")
		case .column?: String(localized: "컬럼 보기")
		case .gallery?: String(localized: "갤러리 보기")
		case nil: String(localized: "보기 방식 유지")
		}
	}

	/// The bottom line when nothing needs attention and views the panel does not show hold values: they are named, so a
	/// preset made from a folder (icon and list values) never hides half of what it writes.
	static func hiddenValues(_ views: [ViewStyle]) -> String? {
		switch (views.contains(.icon), views.contains(.list)) {
		case (true, true): String(localized: "아이콘 보기와 목록 보기의 값도 있습니다. 여기에는 보이지 않지만 그대로 저장되고 적용됩니다.")
		case (true, false): String(localized: "아이콘 보기의 값도 있습니다. 여기에는 보이지 않지만 그대로 저장되고 적용됩니다.")
		case (false, true): String(localized: "목록 보기의 값도 있습니다. 여기에는 보이지 않지만 그대로 저장되고 적용됩니다.")
		case (false, false): nil
		}
	}
}

/// "편집…" / "새 프리셋…", modelled on Finder's own "보기 옵션" window (⌘J), which shows the options of one view at a time.
/// Under the header: the name, and the view control — "유지" and Finder's view switcher (the toolbar's four symbols). The
/// selected segment is the preset's view style: a view means "folders this preset is applied to open in this view",
/// "유지" leaves each folder in its current view; a caption next to it says so. The panel under it lists the options of
/// the selected view in Finder's order, the grouping first (one value per folder, shared by every view, so the icon, list,
/// column and "유지" panels show the same menu; the gallery panel names its value, as Finder shows no groups there);
/// column and gallery view have no other options in a preset and say so. The values of the views not selected (a preset
/// made from a folder holds icon and list values) are kept and saved unchanged, and the bottom line names them.
///
/// Each option is either set or "유지" (left as it is in each folder): the menus start with "유지"; icon size, grid
/// spacing and text size are a slider and a number field, empty ("유지", the slider dimmed at Finder's current default, the value the preview draws)
/// until the slider moves or a number is typed, and × makes them "유지" again; the name of an option that is left alone is
/// dimmed. The sheet edits its own copy of the draft; "취소" drops it, "저장" hands it to the model, which checks it again
/// and writes it. A typed number outside Finder's range stands for the nearest value it offers, and the field shows that
/// value once it is committed (the focus leaves it, or "저장", which Return also presses as the default button;
/// `PresetDraft.commitNumber`, `committed`). Values that cannot be
/// saved are named at the bottom (with their view) and turn their option's name to the warning color, and "저장" stays
/// disabled; a typed text that is not a number goes back to the preset's value when another view is selected
/// (`PresetDraft.selectView`), which the bottom line says. One fixed size for every view and
/// state, nothing scrolls.
///
/// While the sheet is open, the preview window beside the main window (Views/PresetPreviewWindow.swift) draws a sample
/// folder with the sheet's draft, sent on every change; the eye button in the header hides and shows it (remembered).
struct PresetEditorSheet: View {
	@Environment(AppModel.self) private var model
	@State private var draft: PresetDraft
	/// The numbers `selectView` put back, with the value each has now (the preset's, or "유지"), shown until the next
	/// change of the draft.
	@State private var resetNote: ResetNote?
	@FocusState private var nameFocused: Bool
	/// The number field being typed in: when the focus leaves it, it shows the value it saves (`PresetDraft.commitNumber`).
	@FocusState private var numberFocus: PresetDraft.Number?
	private let preview = PresetPreviewController.shared

	private struct ResetNote {
		var text: String
		var draft: PresetDraft
	}

	/// Fixed size, smaller than the window's content (720×440), from the tallest panel (icon and list view: eight
	/// options): padding, header, name row, panel, bottom row, 10pt between them.
	static let size = CGSize(width: 600, height: 380)
	static let headerHeight: CGFloat = 44
	static let topRowHeight: CGFloat = 24
	static let footerHeight: CGFloat = 30
	/// One option: its row and the space between two rows; the panel's padding.
	static let rowHeight: CGFloat = 22
	static let rowSpacing: CGFloat = 4
	static let panelPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
	/// The most options a view has (icon and list view: eight, the grouping included).
	static let maxRows = 8
	/// The panel: its padding and `maxRows` options (220).
	static let panelHeight = panelPadding.top + CGFloat(maxRows) * rowHeight + CGFloat(maxRows - 1) * rowSpacing + panelPadding.bottom
	/// Width of an option's name, of the menus next to it, of a slider and of its number field.
	static let labelWidth: CGFloat = 124
	static let menuWidth: CGFloat = 160
	static let sliderWidth: CGFloat = 200
	static let numberWidth: CGFloat = 52
	/// The name field: one width for every view (the caption next to the view control changes with it, the field does not).
	static let nameWidth: CGFloat = 150
	static let preview = CGSize(width: 64, height: 40)

	init(initial: PresetDraft) {
		_draft = State(initialValue: initial)
	}

	var body: some View {
		let check = draft.check(others: model.presetsOtherThan(draft))
		VStack(alignment: .leading, spacing: 10) {
			header
				.probeFrame("editorHeader")
			topRow(check)
				.probeFrame("editorTopRow")
			panel(check)
				.probeFrame("editorPanel")
			footer(check)
				.probeFrame("editorFooter")
		}
		.controlSize(.small)
		.padding(16)
		.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
		.background { viewShortcuts }
		.probeFrame("editorSheet")
		.sheetSurface()
		.onAppear { nameFocused = true }
		// A change after a refused "저장" makes its reason stale; the fields "저장" itself committed ("900" → "512") do not.
		.onChange(of: draft) { old, new in if model.presetEditorProblem != nil && old.committed != new { model.presetEditorProblem = nil } }
		.onChange(of: numberFocus) { old, _ in if let old { draft.commitNumber(old) } }
		// The preview window follows every change of the sheet's own copy (Views/PresetPreviewWindow.swift).
		.onChange(of: draft, initial: true) { preview.follow(draft) }
		#if DEBUG
		// The layout probe checks the sheet's own copy (the model's is only written by "저장"): opening changes nothing,
		// the view control changes the view style.
		.onChange(of: draft, initial: true) { if LayoutProbe.isRequested { LayoutProbe.editorDraft = draft } }
		#endif
	}

	/// The view control, its shortcuts and the probe: the view style becomes `view` (nil: "유지").
	private func select(_ view: ViewStyle?) {
		let reset = draft.selectView(view)
		// "아이콘 보기 · 아이콘 크기 → 208" or "… → 유지": the field is not shown in the new view.
		let named = reset.map { "\($0.fullTitle) → \(draft.isKept($0) ? Fmt.keep : draft[$0])" }.joined(separator: ", ")
		resetNote = reset.isEmpty ? nil : ResetNote(text: String(localized: "쓸 수 없는 값을 원래대로 되돌렸습니다: \(named)"), draft: draft)
	}

	// MARK: Parts

	private var header: some View {
		let assigned = model.assignedFolderCount(draft.original?.id)
		let first: String = draft.isNew
			? String(localized: "저장하면 목록에 추가됩니다. 폴더 행에 끌어다 놓거나 선택해 적용합니다.")
			: (assigned > 0
				? String(localized: "폴더 \(assigned)개에 지정된 프리셋입니다. 이미 적용한 폴더는 다시 적용해야 바뀝니다.")
				: String(localized: "지정한 폴더가 없습니다. 이미 적용한 폴더는 다시 적용해야 바뀝니다."))
		let second = Self.headerSecondLine
		return HStack(spacing: 10) {
			// The view folders will open in; for "유지" an empty, dimmed window.
			ViewStyleThumbnail(settings: draft.previewSettings, size: Self.preview, neutralWhenKept: true)
			VStack(alignment: .leading, spacing: 1) {
				// The title in the primary color, like the other sheets' titles; only the two lines under it are dimmed.
				// The eye button shares the title's line only, so both lines under it keep the header's full width.
				HStack(spacing: 6) {
					Text(draft.isNew ? String(localized: "새 프리셋") : String(localized: "프리셋 편집"))
						.font(.headline)
						.foregroundStyle(.primary)
						.accessibilityAddTraits(.isHeader)
					Spacer(minLength: 0)
					previewToggle
				}
				Group {
					Text(first)
						.lineLimit(1)
						.truncationMode(.tail)
						.help(first)
						.accessibilityIdentifier("editorAssigned")
					Text(second)
						.lineLimit(1)
						.truncationMode(.tail)
						.help(second)
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)
			}
			.probeFrame("editorHeaderText")
		}
		.frame(height: Self.headerHeight)
	}

	/// The header's second line: what the view control and "유지" do (the layout probe checks it is never cut).
	static var headerSecondLine: String {
		String(localized: "고른 보기로 폴더를 엽니다. 아래에는 그 보기의 옵션이 보입니다. \"유지\"는 지금 값 그대로입니다.")
	}

	/// Hides or shows the preview window beside the main window (remembered; shown by default).
	private var previewToggle: some View {
		Button { preview.setShown(!preview.shown) } label: {
			// No taller than the headline, so the header keeps its height; the click area is larger than the symbol.
			Image(systemName: preview.shown ? "eye" : "eye.slash")
				.font(.system(size: 12))
				.frame(width: 22, height: 16)
				.contentShape(Rectangle().inset(by: -4))
		}
		.buttonStyle(.borderless)
		.foregroundStyle(preview.shown ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
		.help(String(localized: "미리보기 보기/숨기기"))
		.accessibilityLabel(String(localized: "미리보기"))
		.accessibilityValue(preview.shown ? String(localized: "보임") : String(localized: "숨김"))
		.accessibilityHint(String(localized: "미리보기 보기/숨기기"))
		.accessibilityIdentifier("editorPreviewToggle")
		.probeFrame("editorPreviewToggle")
	}

	/// The name, then (on the right, like Finder's toolbar) what the view does and the view control.
	private func topRow(_ check: PresetDraft.Check) -> some View {
		let result = EditorText.result(draft.viewStyle)
		return HStack(spacing: 8) {
			fieldName(String(localized: "이름"), kept: false, invalid: check.nameInvalid)
				.frame(width: 34, alignment: .leading)
			TextField(String(localized: "이름"), text: $draft.name, prompt: Text(String(localized: "프리셋 이름")))
				.textFieldStyle(.roundedBorder)
				.focused($nameFocused)
				.frame(width: Self.nameWidth)
				.accessibilityLabel(String(localized: "이름"))
				.accessibilityIdentifier("editorName")
				.probeFrame("editorNameField")
			Spacer(minLength: 8)
			Text(result)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.fixedSize()
				.help(result)
				.accessibilityIdentifier("editorViewResult")
				.probeFrame("editorViewResult")
			ViewSwitcher(selection: Binding(get: { draft.viewStyle }, set: { select($0) }))
				.fixedSize()
				.accessibilityIdentifier("editorViewPicker")
		}
		.frame(height: Self.topRowHeight)
	}

	/// The panel of the selected view: its options, or why it has none.
	private func panel(_ check: PresetDraft.Check) -> some View {
		VStack(alignment: .leading, spacing: Self.rowSpacing) {
			switch draft.viewStyle {
			case .icon?: iconOptions(check)
			case .list?: listOptions(check)
			case .column?:
				// Finder's column view has "그룹 기준" too, the same value as in the other views.
				groupRow
				noOptions(String(localized: "컬럼 보기의 다른 Finder 옵션은 이 앱이 정하지 않고, 폴더마다 지금 그대로 둡니다."))
			case .gallery?:
				noOptions(String(localized: "갤러리 보기에는 이 앱이 정하는 옵션이 없습니다. 갤러리 보기의 Finder 옵션은 폴더마다 지금 그대로 둡니다."),
				          galleryGrouping)
			case nil:
				groupRow
				noOptions(String(localized: "보기 방식은 폴더마다 지금 그대로 둡니다. 위에서 보기를 고르면 그 보기의 옵션이 여기에 보입니다."))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.padding(Self.panelPadding)
		.frame(maxWidth: .infinity)
		.frame(height: Self.panelHeight, alignment: .topLeading)
		.well(clips: false)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(EditorText.viewTitle(draft.viewStyle))
	}

	@ViewBuilder private func iconOptions(_ check: PresetDraft.Check) -> some View {
		let view = EditorText.viewTitle(.icon)
		groupRow
		// "자동 격자 정렬" keeps the icons' places, a sort lines them up: which one decides whether a new icon size can
		// leave icons overlapping.
		optionRow(String(localized: "정렬 기준"), in: view, selection: $draft.arrangeBy, options: SortKey.allCases.map { ($0, Fmt.sort($0)) },
		          help: String(localized: "자동 격자 정렬은 아이콘을 지금 자리에서 격자에만 맞추고, 이름·종류·날짜 등으로 정렬하면 Finder가 아이콘을 직접 줄 세웁니다."), identifier: "editorArrangeBy")
		numberRow(.iconSize, check, identifier: "editorIconSize")
		numberRow(.gridSpacing, check, identifier: "editorGridSpacing")
		numberRow(.iconTextSize, check, identifier: "editorIconTextSize")
		optionRow(String(localized: "레이블 위치"), in: view, selection: $draft.labelOnBottom,
		          options: [(true, String(localized: "아래")), (false, String(localized: "오른쪽"))], identifier: "editorLabelPosition")
		optionRow(String(localized: "항목 정보"), in: view, selection: $draft.showItemInfo, options: onOff, identifier: "editorItemInfo")
		optionRow(String(localized: "아이콘 미리보기"), in: view, selection: $draft.iconShowPreview, options: onOff, identifier: "editorIconPreview")
			.probeFrame("editorLastRow")
	}

	@ViewBuilder private func listOptions(_ check: PresetDraft.Check) -> some View {
		let view = EditorText.viewTitle(.list)
		groupRow
		optionRow(String(localized: "정렬 열"), in: view, selection: Binding(get: { draft.sortColumn }, set: { column in
			draft.sortColumn = column
			// A direction alone can never be written (it lives in the sort column's entry).
			if column == nil { draft.sortAscending = nil }
		}), options: ListColumn.allCases.map { ($0, Fmt.column($0)) }, identifier: "editorSortColumn")
		optionRow(String(localized: "정렬 방향"), in: view, selection: $draft.sortAscending,
		          options: [(true, String(localized: "오름차순")), (false, String(localized: "내림차순"))],
		          invalid: check.directionInvalid, identifier: "editorSortDirection")
			.disabled(draft.sortColumn == nil && draft.sortAscending == nil)
			.help(draft.sortColumn == nil ? String(localized: "정렬 열을 고른 뒤에 정할 수 있습니다.")
			      : String(localized: "고른 정렬 열의 방향입니다."))
		optionRow(String(localized: "아이콘 크기"), in: view, selection: $draft.listIconSize, options: listIconSizes,
		          invalid: check.listIconSizeInvalid, identifier: "editorListIconSize")
		numberRow(.listTextSize, check, identifier: "editorListTextSize")
		optionRow(String(localized: "상대적 날짜"), in: view, selection: $draft.useRelativeDates, options: onOff, identifier: "editorRelativeDates")
		optionRow(String(localized: "모든 크기 계산"), in: view, selection: $draft.calculateAllSizes, options: onOff, identifier: "editorCalculateSizes")
		optionRow(String(localized: "아이콘 미리보기"), in: view, selection: $draft.listShowPreview, options: onOff, identifier: "editorListPreview")
			.probeFrame("editorLastRow")
	}

	/// The gallery panel's word on the grouping: Finder shows no groups there, so no menu, but the preset's value (set in
	/// the other panels) is named, so a preset with a grouping never looks empty here.
	private var galleryGrouping: String {
		guard let group = draft.groupBy else {
			return String(localized: "Finder는 갤러리 보기에서 그룹을 보이지 않습니다. 그룹 기준은 다른 보기에서 쓰입니다.")
		}
		return String(localized: "그룹 기준: \(Fmt.group(group)) (모든 보기에 공통, 갤러리 보기에서는 보이지 않음)")
	}

	/// Column, gallery and "유지": no (other) option to set here, only why (no fake controls).
	private func noOptions(_ lines: String...) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(lines, id: \.self) { line in
				Label {
					Text(line)
						.fixedSize(horizontal: false, vertical: true)
				} icon: {
					Image(systemName: "info.circle")
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)
			}
		}
		.padding(.top, 2)
		.frame(maxWidth: 480, alignment: .leading)
		.accessibilityElement(children: .combine)
		.accessibilityIdentifier("editorNoOptions")
		.probeFrame("editorLastRow")
	}

	/// Finder's "그룹 기준" of the folder (`GRP0`): one value per folder, used by every view (the gallery view shows no
	/// groups; sorting applies within groups), so the icon, list, column and "유지" panels show the same value.
	private var groupRow: some View {
		let title = String(localized: "그룹 기준")
		let note = String(localized: "모든 보기 방식에 쓰입니다. 정렬 기준은 묶음 안에서 쓰이고, 갤러리 보기는 묶음을 보이지 않습니다. 유지: 폴더마다 지금 그룹 기준을 그대로 둡니다.")
		return HStack(spacing: 6) {
			fieldName(title, kept: draft.groupBy == nil, invalid: false)
				.frame(width: Self.labelWidth, alignment: .leading)
			Picker(title, selection: $draft.groupBy) {
				Text(EditorText.keep).tag(Optional<GroupBy>.none)
				Divider()
				ForEach(GroupBy.allCases, id: \.self) { Text(Fmt.group($0)).tag(Optional<GroupBy>.some($0)) }
			}
			.pickerStyle(.menu)
			.labelsHidden()
			.frame(width: Self.menuWidth, alignment: .leading)
			.help(note)
			.accessibilityHint(note)
			.accessibilityIdentifier("editorGroupBy")
			Text(String(localized: "모든 보기에 공통"))
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.fixedSize()
				.help(note)
				.accessibilityHidden(true)   // the menu's hint says it all
			Spacer(minLength: 0)
		}
		.frame(height: Self.rowHeight)
	}

	private func footer(_ check: PresetDraft.Check) -> some View {
		HStack(alignment: .center, spacing: 8) {
			message(check)
				.frame(maxWidth: .infinity, alignment: .leading)
			Button(String(localized: "취소"), role: .cancel) { model.cancelPresetEdit() }
				.keyboardShortcut(.cancelAction)
				.accessibilityIdentifier("editorCancel")
			Button(draft.isNew ? String(localized: "만들기") : String(localized: "저장")) {
				draft = draft.committed   // the fields show what is written, also when the save is refused
				model.savePresetEdit(draft)
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.defaultAction)
			.disabled(!check.canSave)
			.help(check.canSave ? String(localized: "프리셋 파일에 저장합니다.")
			      : String(localized: "쓸 수 없는 값이 있어 저장할 수 없습니다."))
			.accessibilityIdentifier("editorSave")
		}
		.frame(height: Self.footerHeight)
	}

	/// Two lines at most: what cannot be saved (with its view, so a value of a view not selected is found too), else a
	/// refused save's reason, else the numbers the view control put back, else the warnings, else the values of the views
	/// not selected, else what saving does.
	@ViewBuilder private func message(_ check: PresetDraft.Check) -> some View {
		let lines: (text: String, all: String, warning: Bool) = {
			if !check.problems.isEmpty {
				let all = check.problems.map(\.message)
				let more = all.count > 1 ? String(localized: " (외 \(all.count - 1)개)") : ""
				return (all[0] + more, all.joined(separator: "\n"), true)
			}
			if let problem = model.presetEditorProblem { return (problem, problem, true) }
			if let note = resetNote, note.draft == draft { return (note.text, note.text, true) }
			if !check.warnings.isEmpty { return (check.warnings.joined(separator: " "), check.warnings.joined(separator: "\n"), true) }
			if let hidden = EditorText.hiddenValues(draft.hiddenViewsWithValues) { return (hidden, hidden, false) }
			let note = String(localized: "저장하면 목록·요약·폴더 행에 바로 보입니다. 폴더에 쓰는 것은 적용할 때입니다.")
			return (note, note, false)
		}()
		Label {
			Text(lines.text)
				.lineLimit(2)
				.truncationMode(.tail)
				.fixedSize(horizontal: false, vertical: true)
		} icon: {
			Image(systemName: lines.warning ? "exclamationmark.triangle.fill" : "info.circle")
		}
		.font(.subheadline)
		.foregroundStyle(lines.warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
		.help(lines.all)
		.accessibilityElement(children: .ignore)
		.accessibilityAddTraits(.isStaticText)
		.accessibilityLabel(lines.all)
		.accessibilityIdentifier("editorMessage")
	}

	/// ⌘0 ("유지") and ⌘1–⌘4 (the views, like in Finder) choose the view; the app's menus use none of them. Invisible
	/// buttons that only carry the shortcuts; the view control itself is what VoiceOver and the pointer use.
	private var viewShortcuts: some View {
		ZStack {
			ForEach(Array(ViewSwitcher.choices.enumerated()), id: \.offset) { index, view in
				Button(EditorText.viewTitle(view)) { select(view) }
					.keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
			}
		}
		.opacity(0)
		.frame(width: 0, height: 0)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	// MARK: Building blocks

	private var onOff: [(Bool, String)] { [(true, Fmt.on), (false, Fmt.off)] }

	/// Small (16) and large (32), and a value the preset already had that is neither (kept, never offered otherwise).
	private var listIconSizes: [(Double, String)] {
		var sizes: [(Double, String)] = [(16, String(localized: "작게 (16)")), (32, String(localized: "크게 (32)"))]
		if let odd = draft.original?.settings.list.iconSize, !PresetLimits.listIconSizes.contains(odd) { sizes.append((odd, PresetDraft.text(odd))) }
		return sizes
	}

	/// An option's name: dimmed while it is "유지", the warning color while its value cannot be saved.
	private func fieldName(_ title: String, kept: Bool, invalid: Bool) -> some View {
		Text(title)
			.font(.subheadline.weight(kept ? .regular : .medium))
			.foregroundStyle(invalid ? AnyShapeStyle(Theme.warning) : (kept ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
			.lineLimit(1)
			.minimumScaleFactor(0.85)
			.accessibilityHidden(true)   // the control carries the name
	}

	/// An option with its menu. `view`: the view it belongs to — the menu's accessibility name is "아이콘 보기 · 아이콘
	/// 미리보기", like the number fields (`Number.fullTitle`), so the two "아이콘 미리보기" menus differ for VoiceOver and
	/// Voice Control.
	private func optionRow<Value: Hashable>(_ title: String, in view: String, selection: Binding<Value?>, options: [(Value, String)],
	                                        invalid: Bool = false, help: String? = nil, identifier: String) -> some View {
		// The menu's name (hidden on screen, read by VoiceOver and Voice Control) carries its view.
		let picker = Picker(view + " · " + title, selection: selection) {
			Text(EditorText.keep).tag(Value?.none)
			Divider()
			ForEach(options, id: \.0) { option in Text(option.1).tag(Value?.some(option.0)) }
		}
		.pickerStyle(.menu)
		.labelsHidden()
		.frame(width: Self.menuWidth, alignment: .leading)
		.accessibilityIdentifier(identifier)
		return HStack(spacing: 6) {
			fieldName(title, kept: selection.wrappedValue == nil, invalid: invalid)
				.frame(width: Self.labelWidth, alignment: .leading)
			if let help {
				picker.help(help).accessibilityHint(help)
			} else {
				picker
			}
			Spacer(minLength: 0)
		}
		.frame(height: Self.rowHeight)
	}

	/// A number option: a slider (Finder's own control for these), the number field for a value typed directly, × back to
	/// "유지" and the range. While the option is "유지" the field is empty with a dimmed "유지" and the slider rests dimmed at
	/// Finder's current default (`PresetDraft.restPosition`, the value the preview window draws); moving the slider or typing sets the option. The slider only draws a value outside its
	/// range at its end: the value itself is kept until the user changes it (`PresetDraft.setFromSlider`). A typed number is
	/// clamped into the range when the field is committed (the focus leaves it, or Return, which also saves: "저장" is the
	/// default button), not while it is typed.
	private func numberRow(_ number: PresetDraft.Number, _ check: PresetDraft.Check, identifier: String) -> some View {
		let text = Binding(get: { draft[number] }, set: { draft[number] = $0 })
		let position = Binding(get: { draft.sliderPosition(number) }, set: { draft.setFromSlider(number, $0) })
		let kept = draft.isKept(number)
		let invalid = check.isInvalid(number)
		let help = String(localized: "\(number.rangeText) · 비우면 유지(바꾸지 않음)")
		return HStack(spacing: 6) {
			fieldName(number.title, kept: kept, invalid: invalid)
				.frame(width: Self.labelWidth, alignment: .leading)
			NumberSlider(number: number, position: position, kept: kept, help: help, identifier: identifier + "Slider")
				.opacity(kept ? 0.45 : 1)
				.frame(width: Self.sliderWidth)
			// The dimmed "유지" is drawn over the empty field, right-aligned like the numbers: the field's own placeholder
			// would be centered while it has the focus.
			TextField(number.title, text: text, prompt: Text(verbatim: ""))
				.textFieldStyle(.roundedBorder)
				.multilineTextAlignment(.trailing)
				.overlay(alignment: .trailing) {
					if kept {
						Text(Fmt.keep)
							.font(.system(size: NSFont.smallSystemFontSize))
							.foregroundStyle(Color(nsColor: .placeholderTextColor))
							.lineLimit(1)
							.padding(.trailing, 6)
							.allowsHitTesting(false)
							.accessibilityHidden(true)
					}
				}
				.focused($numberFocus, equals: number)
				.onSubmit { draft.commitNumber(number) }
				.frame(width: Self.numberWidth)
				.help(help)
				.accessibilityLabel(number.fullTitle)
				.accessibilityHint(help)
				.accessibilityIdentifier(identifier)
			// Always takes its place (only hidden), so typing never moves the row.
			Button { draft[number] = "" } label: {
				Image(systemName: "xmark.circle.fill")
					.foregroundStyle(.tertiary)
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.borderless)
			.help(String(localized: "유지로 되돌리기(바꾸지 않음)"))
			.accessibilityLabel(String(localized: "\(number.fullTitle) 유지로 되돌리기"))
			.accessibilityIdentifier(identifier + "Keep")
			.opacity(kept ? 0 : 1)
			.disabled(kept)
			.accessibilityHidden(kept)
			Text(number.rangeText)
				.font(.caption.monospacedDigit())
				.foregroundStyle(invalid ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
				.lineLimit(1)
				.fixedSize()
				.accessibilityHidden(true)
			Spacer(minLength: 0)
		}
		.frame(height: Self.rowHeight)
	}
}

/// The slider of a number option, named with its view ("아이콘 보기 · 텍스트 크기"). Every slider is drawn the same way,
/// without tick marks, and `PresetDraft.sliderValue` puts the value on its steps (text sizes: whole points; icon size: 4).
///
/// An AppKit slider whose fill **and knob** are set on every update: both in the accent color while the option has a
/// value, both gray (the system's knob) while it is "유지" — a gray knob sitting on a blue fill read as a control that
/// was not set yet. SwiftUI's `Slider` did not keep the two apart on macOS 26 in this sheet: a slider once drawn gray
/// ("유지") stayed gray after a value was set. And in this sheet a slider with tick marks is drawn with no fill at all
/// (SwiftUI's and AppKit's alike), so the text sizes, which had one tick per point, never showed their value like the others.
struct NumberSlider: NSViewRepresentable {
	let number: PresetDraft.Number
	@Binding var position: Double
	let kept: Bool
	let help: String
	let identifier: String

	func makeCoordinator() -> Coordinator { Coordinator(position: $position) }

	func makeNSView(context: Context) -> NSSlider {
		let slider = NSSlider()
		// The cell holds the values, so it is replaced before they are set.
		slider.cell = AccentKnobCell()
		slider.isVertical = false
		slider.minValue = number.range.lowerBound
		slider.maxValue = number.range.upperBound
		slider.doubleValue = position
		slider.target = context.coordinator
		slider.action = #selector(Coordinator.changed(_:))
		slider.isContinuous = true
		slider.setAccessibilityLabel(number.fullTitle)
		slider.setAccessibilityIdentifier(identifier)
		return slider
	}

	func updateNSView(_ slider: NSSlider, context: Context) {
		context.coordinator.position = $position
		slider.controlSize = switch context.environment.controlSize {
			case .mini: .mini
			case .small: .small
			case .large, .extraLarge: .large
			default: .regular
		}
		if slider.doubleValue != position { slider.doubleValue = position }
		slider.trackFillColor = kept ? .tertiaryLabelColor : .controlAccentColor
		(slider.cell as? AccentKnobCell)?.accent = !kept
		slider.needsDisplay = true
		slider.toolTip = help
		slider.setAccessibilityHelp(help)
		// VoiceOver reads "유지" for an option left alone, not the position the slider rests at.
		slider.setAccessibilityValueDescription(kept ? Fmt.keep : nil)
	}

	final class Coordinator: NSObject {
		var position: Binding<Double>
		init(position: Binding<Double>) { self.position = position }

		@MainActor @objc func changed(_ sender: NSSlider) { position.wrappedValue = sender.doubleValue }
	}
}

/// The knob of a `NumberSlider`, drawn in the accent color while `accent` (the option has a value) and by the system
/// while not (it is "유지", and the whole row is dimmed). AppKit has no way to tint a knob, so it is drawn here: the
/// circle the system draws, in the accent color, with its shadow and a hairline edge, darker while it is dragged.
private final class AccentKnobCell: NSSliderCell {
	var accent = true

	/// The bar with the part up to the knob filled in the accent color. A cell of our own does not get AppKit's own
	/// `trackFillColor` drawing (that is the stock cell's), so the fill is drawn here — the same fill the stock slider
	/// shows, and none while the option is "유지".
	override func drawBar(inside rect: NSRect, flipped: Bool) {
		super.drawBar(inside: rect, flipped: flipped)
		guard accent, maxValue > minValue else { return }
		let knob = knobRect(flipped: flipped)
		var fill = rect
		fill.size.width = max(0, min(rect.width, knob.midX - rect.minX))
		guard fill.width > 0 else { return }
		NSColor.controlAccentColor.setFill()
		NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
	}

	override func drawKnob(_ knobRect: NSRect) {
		guard accent else { return super.drawKnob(knobRect) }
		let d = min(knobRect.width, knobRect.height) - 1
		let circle = NSBezierPath(ovalIn: NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d))
		NSGraphicsContext.saveGraphicsState()
		let shadow = NSShadow()
		shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
		shadow.shadowBlurRadius = 1.5
		shadow.shadowOffset = NSSize(width: 0, height: -0.5)
		shadow.set()
		(isHighlighted ? NSColor.controlAccentColor.blended(withFraction: 0.18, of: .black) ?? .controlAccentColor
			: .controlAccentColor).setFill()
		circle.fill()
		NSGraphicsContext.restoreGraphicsState()
		NSColor.black.withAlphaComponent(0.12).setStroke()
		circle.lineWidth = 0.5
		circle.stroke()
	}
}

/// The editor's view control as a native segmented control: "유지" (text), then Finder's view switcher (its toolbar's four
/// symbols, in its order). The selected segment is the preset's view style (nil: "유지"); each view segment has the view's
/// name as its tooltip and accessibility description, the selected segment is exposed as selected.
struct ViewSwitcher: NSViewRepresentable {
	@Binding var selection: ViewStyle?

	/// The segments in order: "유지", then the four views (also ⌘0–⌘4).
	static let choices: [ViewStyle?] = [nil] + ViewStyle.allCases.map { $0 }

	/// The symbols of Finder's own "보기" buttons (macOS 26).
	static func symbol(_ view: ViewStyle) -> String {
		switch view {
		case .icon: "square.grid.2x2"
		case .list: "list.bullet"
		case .column: "rectangle.split.3x1"
		case .gallery: "squares.below.rectangle"
		}
	}
	static let segmentWidth: CGFloat = 32

	static func index(_ view: ViewStyle?) -> Int { choices.firstIndex(of: view) ?? 0 }

	func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

	func makeNSView(context: Context) -> NSSegmentedControl {
		let control = NSSegmentedControl(labels: Self.choices.map { _ in "" }, trackingMode: .selectOne, target: context.coordinator,
		                                  action: #selector(Coordinator.changed(_:)))
		control.controlSize = .regular
		// "유지" in the size of the texts around it (the caption, the options), not the control's larger default; the
		// symbols keep their size.
		control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		for (index, view) in Self.choices.enumerated() {
			if let view {
				let title = EditorText.viewTitle(view)
				control.setImage(NSImage(systemSymbolName: Self.symbol(view), accessibilityDescription: title) ?? NSImage(), forSegment: index)
				// The tooltip also names the shortcut (no menu shows it); the accessibility description stays the plain name.
				control.setToolTip("\(title) (⌘\(index))", forSegment: index)
				control.setWidth(Self.segmentWidth, forSegment: index)
			} else {
				control.setLabel(Fmt.keep, forSegment: index)
				control.setToolTip("\(EditorText.result(nil)) (⌘0)", forSegment: index)
			}
		}
		control.setAccessibilityLabel(String(localized: "보기 방식"))
		control.setAccessibilityIdentifier("editorViewPicker")
		control.selectedSegment = Self.index(selection)
		return control
	}

	func updateNSView(_ control: NSSegmentedControl, context: Context) {
		context.coordinator.selection = $selection
		let index = Self.index(selection)
		if control.selectedSegment != index { control.selectedSegment = index }
	}

	final class Coordinator: NSObject {
		var selection: Binding<ViewStyle?>
		init(selection: Binding<ViewStyle?>) { self.selection = selection }

		@MainActor @objc func changed(_ sender: NSSegmentedControl) {
			guard ViewSwitcher.choices.indices.contains(sender.selectedSegment) else { return }
			selection.wrappedValue = ViewSwitcher.choices[sender.selectedSegment]
		}
	}
}

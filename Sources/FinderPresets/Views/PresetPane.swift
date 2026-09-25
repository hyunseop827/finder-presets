import SwiftUI
import FinderPresetsCore

/// "1. 프리셋": the presets. Finder folders, folder rows of "2. 적용할 폴더" and exported JSON files can be dropped on
/// the list. The header's "+", a row's "편집…" (or a double-click) and the summary box's pencil open the preset editor.
/// The star (a row's menu, the summary box) makes a preset the quick preset (QuickPreset.swift); its row shows the star.
struct PresetPane: View {
	@Environment(AppModel.self) private var model
	@State private var renaming: Preset?
	@State private var newName = ""
	@State private var dropTargeted = false

	var body: some View {
		@Bindable var model = model
		let tints = PresetTint.map(for: model.presets)
		let assignedCounts = Dictionary(grouping: model.targets.compactMap(\.presetID), by: { $0 }).mapValues(\.count)
		VStack(alignment: .leading, spacing: UILayout.spacing) {
			SectionHeader(step: 1, title: String(localized: "프리셋"), count: String(localized: "\(model.presets.count)개"),
			              help: String(localized: "Finder에서 원하는 모양으로 맞춘 폴더나 내보낸 JSON 파일을 여기에 끌어다 놓으면 프리셋이 됩니다. 오른쪽 목록의 폴더 행을 끌어다 놓아도 됩니다.")) {
				// A new preset with every option "유지", made in the editor (nothing is created before "만들기").
				Button { model.beginNewPreset() } label: {
					Label(String(localized: "새 프리셋…"), systemImage: "plus")
						.labelStyle(.iconOnly)
						.frame(width: PresetSummaryPanel.iconButton.width, height: PresetSummaryPanel.iconButton.height)
						.contentShape(Rectangle())
				}
				.buttonStyle(.borderless)
				.controlSize(.small)
				.help(String(localized: "새 프리셋… (값을 직접 정해 만듭니다)"))
				.accessibilityIdentifier("newPreset")
				.probeFrame("newPreset")
			}

			List(model.presets, selection: $model.selectedPresetID) { p in
				PresetRow(preset: p, tint: tints[p.id] ?? PresetTint.colors[0], assignedCount: assignedCounts[p.id] ?? 0,
				          isQuick: p.id == model.quickPresetID)
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
					// Dropped on a row of "2. 적용할 폴더", this assigns the preset to that folder.
					.draggable(PresetReference(id: p.id)) {
						DragPreview(title: p.name, hint: String(localized: "폴더 행에 놓아 지정")) {
							PresetDot(tint: tints[p.id] ?? PresetTint.colors[0])
						}
					}
					.tag(p.id)
			}
			.listStyle(.inset)
			.alternatingRowBackgrounds(.disabled)
			.scrollContentBackground(.hidden)
			// Directly on the list (like the folder list): the clicked row's menu, "새 프리셋…" on the empty area, and a
			// double-click (or Return) on a row opens the editor.
			.contextMenu(forSelectionType: UUID.self) { ids in
				if let p = ids.first.flatMap({ model.preset($0) }) {
					Button(String(localized: "편집…")) { model.beginEditPreset(p.id) }
					Button(PresetSummaryPanel.quickTitle(p.id == model.quickPresetID)) { model.toggleQuickPreset(p.id) }
					Button("이름 변경") { newName = p.name; renaming = p }
					Button("파일로 내보내기…") { model.selectedPresetID = p.id; model.exportSelectedPreset() }
					Button("삭제…", role: .destructive) { model.requestDeletePreset(p.id) }
				} else {
					Button(String(localized: "새 프리셋…")) { model.beginNewPreset() }
				}
			} primaryAction: { ids in
				if let id = ids.first { model.beginEditPreset(id) }
			}
			.accessibilityIdentifier("presetList")
			// An empty or short list does not bounce; a long one scrolls inside the list only.
			.scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
			// A list whose rows fit stays at its top (also after a preset that sorts first is imported), and an imported
			// preset below the visible rows is scrolled into view.
			.background { ListScrollKeeper(rows: model.presets.map(\.id), selection: model.selectedPresetID).accessibilityHidden(true) }
			.overlay {
				if model.presets.isEmpty {
					// Broken by hand: Hangul wraps between any two syllables.
					EmptyListHint(systemImage: "square.and.arrow.down.on.square", title: String(localized: "프리셋이 없습니다"),
					              message: String(localized: "Finder에서 모양을 맞춘 폴더를\n여기에 끌어다 놓으세요."))
				}
			}
			.well()
			.dropDestination(for: PresetAreaDrop.self) { items, _ in
				PresetAreaDropHandler.handle(items, model: model)
			} isTargeted: { dropTargeted = $0 }
			.dropHighlight(dropTargeted, message: String(localized: "놓으면 프리셋을 만듭니다"), systemImage: "plus.square.on.square")
			.frame(minHeight: 0, maxHeight: .infinity)

			PresetSummaryPanel(preset: model.selectedPreset, tint: model.selectedPresetID.flatMap { tints[$0] })

			HStack(spacing: 8) {
				Button("폴더에서 가져오기…") { model.chooseFolderForPreset() }
					.accessibilityIdentifier("importFromFolder")
				Button("파일에서 불러오기…") { model.chooseFilesToImport() }
					.accessibilityIdentifier("importFiles")
				Spacer(minLength: 0)
			}
			.controlSize(.small)
			.frame(height: UILayout.actionRowHeight)
		}
		// `newName` goes back to "" whenever the alert closes, so the next "이름 변경" always changes it (setting it to the
		// value it already had left the new text field empty) and the field opens with the preset's name.
		.alert("프리셋 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { endRename() } })) {
			TextField("이름", text: $newName)
			Button("저장") {
				if let p = renaming { model.rename(p, to: newName) }
				endRename()
			}
			.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			Button("취소", role: .cancel) { endRename() }
		}
	}

	private func endRename() {
		renaming = nil
		newName = ""
	}
}

/// One preset: view-style thumbnail, color dot and name, the star of the quick preset, how many folders it is assigned
/// to, short summary.
struct PresetRow: View {
	let preset: Preset
	let tint: Color
	let assignedCount: Int
	var isQuick = false

	var body: some View {
		// On the accent selection the colored parts switch to white (OnSelection), like the text does.
		HStack(spacing: 8) {
			ViewStyleThumbnail(settings: preset.settings)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 5) {
					PresetDot(tint: tint)
					Text(preset.name)
						.font(.callout.weight(.semibold))
						.lineLimit(1)
						.truncationMode(.middle)
						.help(preset.name)   // the whole name when it is cut
						// Not on screen any more (only folders with an assignment show a count), still read by VoiceOver.
						.accessibilityValue(assignedCount == 0 ? "지정한 폴더 없음" : "")
					if isQuick {
						Image(systemName: "star.fill")
							.font(.system(size: 9))
							.foregroundStyle(OnSelection(Theme.warning, selected: Color.white))
							.help(PresetSummaryPanel.quickHelp)
							.accessibilityLabel("빠른 적용 프리셋")
					}
					Spacer(minLength: 4)
					if assignedCount > 0 {
						HStack(spacing: 2) {
							Image(systemName: "folder.fill")
								.font(.system(size: 9))
								.foregroundStyle(OnSelection(tint, selected: Color.white))
							Text(verbatim: String(assignedCount))
								.font(.caption.monospacedDigit())
								.foregroundStyle(.secondary)
						}
						.help("폴더 \(assignedCount)개에 지정됨")
						.accessibilityElement(children: .ignore)
						.accessibilityLabel("폴더 \(assignedCount)개에 지정됨")
					}
				}
				Text(PresetRow.summary(preset.settings))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					// Every option it sets (the line names a few and counts the rest).
					.help(SettingsSummary.details(preset.settings).joined(separator: "\n"))
			}
			.layoutPriority(1)
		}
		.padding(.vertical, 1)
		// The row separator starts under the text column, not somewhere inside the thumbnail.
		.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + UILayout.thumbnail.width + 8 }
	}

	/// "아이콘 · 아이콘 48 · 정렬 종류 · +2": the view style, the options of that view a folder shows most, and how many
	/// other options the preset sets ("옵션 3개" when none is named), so a preset that sets only list options never reads
	/// like one that changes nothing. The line's tooltip names them all (`SettingsSummary.details`).
	static func summary(_ s: ViewSettings) -> String {
		var parts = [s.viewStyle.map { Fmt.style($0) } ?? String(localized: "보기 방식 유지")]
		var named = s.viewStyle == nil ? 0 : 1
		if s.viewStyle == .icon || s.viewStyle == nil {
			if let i = s.icon.iconSize { parts.append(String(localized: "아이콘 \(Fmt.number(i))")); named += 1 }
			// "자동 격자 정렬" already says it arranges; the others read "정렬 이름".
			if let k = s.icon.arrangeBy { parts.append(k == .grid ? Fmt.sort(k) : String(localized: "정렬 \(Fmt.sort(k))")); named += 1 }
		}
		if s.viewStyle == .list, let c = s.list.sortColumn { parts.append(String(localized: "정렬 \(Fmt.column(c))")); named += 1 }
		let others = SettingsSummary.setCount(s) - named
		if others > 0 { parts.append(parts.count == 1 ? String(localized: "옵션 \(others)개") : "+\(others)") }
		return parts.joined(separator: " · ")
	}
}

/// Fixed-height box under the list: the selected preset's name, its quick preset star, edit, export and delete buttons
/// (always there, disabled without a selection) and its values. Nothing in it scrolls, and the box never changes height.
struct PresetSummaryPanel: View {
	@Environment(AppModel.self) private var model
	let preset: Preset?
	let tint: Color?
	/// Clickable size of the icon buttons (the icons alone are about 11×13pt); also the "+" of the list's header.
	static let iconButton = CGSize(width: 22, height: 20)

	/// The star's menu item and button name.
	static func quickTitle(_ isQuick: Bool) -> String {
		isQuick ? String(localized: "빠른 적용 해제") : String(localized: "빠른 적용으로 지정")
	}

	/// What the quick preset does, with its shortcut (the star's tooltips).
	static var quickHelp: String {
		String(localized: "빠른 적용: 별표한 프리셋 하나를 단축키로 앞 Finder 창의 폴더에만 적용합니다(하위 폴더 제외). Finder가 다시 시작되고, 열려 있던 Finder 창과 그 폴더가 다시 열립니다. 단축키는 시스템 설정에서 정합니다(추천 ⌃⌥⌘P, 앱의 설정 창 참고).")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 5) {
				if let tint { PresetDot(tint: tint) }
				Text(preset?.name ?? String(localized: "선택한 프리셋 없음"))
					.font(.callout.weight(.semibold))
					.foregroundStyle(preset == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
					.lineLimit(1)
					.truncationMode(.middle)
					.help(preset?.name ?? "")
					.probeFrame("summaryName")
				Spacer(minLength: 4)
				HStack(spacing: 4) {
					let isQuick = preset != nil && preset?.id == model.quickPresetID
					Button {
						if let preset { model.toggleQuickPreset(preset.id) }
					} label: { iconLabel(Self.quickTitle(isQuick), systemImage: isQuick ? "star.fill" : "star") }
						.foregroundStyle(isQuick ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
						.help(Self.quickTitle(isQuick) + "\n" + Self.quickHelp)
						.disabled(preset == nil)
						.accessibilityIdentifier("quickPreset")
						.probeFrame("quickPreset")
					Button {
						if let preset { model.beginEditPreset(preset.id) }
					} label: { iconLabel(String(localized: "편집…"), systemImage: "pencil") }
						.help(String(localized: "프리셋 편집… (값과 이름을 바꿉니다)"))
						.disabled(preset == nil)
						.accessibilityIdentifier("editPreset")
						.probeFrame("editPreset")
					Button { model.exportSelectedPreset() } label: { iconLabel(String(localized: "파일로 내보내기…"), systemImage: "square.and.arrow.up") }
						.help("파일로 내보내기…")
						.disabled(preset == nil)
						.accessibilityIdentifier("exportPreset")
						.probeFrame("exportPreset")
					// Asks first (deleting cannot be undone and clears the folders' assignments to this preset).
					Button(role: .destructive) {
						if let preset { model.requestDeletePreset(preset.id) }
					} label: { iconLabel(String(localized: "삭제…"), systemImage: "trash") }
						.help("프리셋 삭제…")
						.disabled(preset == nil)
						.accessibilityIdentifier("deletePreset")
						.probeFrame("deletePreset")
				}
			}
			.buttonStyle(.borderless)
			.controlSize(.small)
			.frame(height: Self.iconButton.height)
			Group {
				if let preset {
					SettingsSummary(settings: preset.settings)
				} else {
					// Words only (the line breaker splits a symbol from the text next to it: "⌘-" / "클릭으로"), and the lines
					// are broken by hand: Hangul wraps between any two syllables ("적용" / "합니다"), and each line fits 242pt.
					Text("프리셋을 선택하면 값이 여기에 보입니다.\nCommand 키를 누른 채 클릭해 선택을 풀면\n지정한 폴더만 적용합니다.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(3)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.accessibilityElement(children: .contain)
			.accessibilityIdentifier("presetSummary")
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.frame(maxWidth: .infinity, alignment: .topLeading)
		.frame(height: UILayout.summaryHeight, alignment: .topLeading)
		.clipped()
		.well()
		.probeFrame("presetSummaryBox")
	}

	/// An icon with the whole button size clickable, not only the glyph.
	private func iconLabel(_ title: String, systemImage: String) -> some View {
		Label(title, systemImage: systemImage)
			.labelStyle(.iconOnly)
			.frame(width: Self.iconButton.width, height: Self.iconButton.height)
			.contentShape(Rectangle())
	}
}

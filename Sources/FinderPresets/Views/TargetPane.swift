import SwiftUI
import FinderPresetsCore

/// "2. 적용할 폴더": the folders to apply to. Finder folders are dropped on the list (or on a row), presets on a row.
struct TargetPane: View {
	@Environment(AppModel.self) private var model
	@State private var listTargeted = false
	@State private var rowFolderHover = false

	var body: some View {
		@Bindable var model = model
		let tints = PresetTint.map(for: model.presets)
		let count = String(localized: "\(model.targets.count)개 폴더")
			+ (model.selectedTargets.isEmpty ? "" : " · " + String(localized: "선택 \(model.selectedTargets.count)"))
		VStack(alignment: .leading, spacing: UILayout.spacing) {
			SectionHeader(step: 2, title: String(localized: "적용할 폴더"), count: count,
			              help: String(localized: "폴더를 끌어다 놓고, 전체 또는 선택한 폴더에 적용합니다. 폴더마다 다른 프리셋을 쓰려면 행의 메뉴에서 고르거나 왼쪽 프리셋을 그 행에 끌어다 놓으세요.")) {
				Toggle("하위 폴더 포함", isOn: $model.includeSubfolders)
					.controlSize(.small)
					.help("폴더와 그 하위 폴더에 같은 프리셋을 적용합니다.")
					.accessibilityIdentifier("includeSubfolders")
			}

			List(model.targets, selection: $model.selectedTargets) { t in
				TargetRow(target: t, tints: tints, listFolderHover: $rowFolderHover)
					.tag(t.path)
			}
			.listStyle(.inset)
			.alternatingRowBackgrounds(.disabled)
			.scrollContentBackground(.hidden)
			// Directly on the list: another modifier in between detaches the selection menu from the rows.
			.contextMenu(forSelectionType: String.self) { paths in
				if !paths.isEmpty { TargetContextMenu(paths: paths) }
			}
			.accessibilityIdentifier("targetList")
			// An empty or short list does not bounce; a long one scrolls inside the list only.
			.scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
			// A list whose rows fit stays at its top, whatever rows were inserted or removed above the others; folders
			// added at the end of a list that does not fit are scrolled into view.
			.background { ListScrollKeeper(rows: model.targets.map(\.path), revealsAppended: true).accessibilityHidden(true) }
			.overlay {
				if model.targets.isEmpty {
					EmptyListHint(systemImage: "folder.badge.plus", title: String(localized: "폴더가 없습니다"),
					              message: String(localized: "Finder에서 폴더를 여기에 끌어다 놓으세요."))
				}
			}
			.well()
			.dropDestination(for: URL.self) { urls, _ in
				// Files and web links are reported by addFolders; with no folder at all the drop counts as refused.
				model.addFolders(urls)
				return urls.contains(where: FinderWindows.isFolder)
			} isTargeted: { listTargeted = $0 }
			.dropHighlight(listTargeted || rowFolderHover, message: String(localized: "놓으면 폴더를 추가합니다"), systemImage: "folder.badge.plus")
			.frame(minHeight: 0, maxHeight: .infinity)

			HStack(spacing: 8) {
				Button("폴더 추가…") { model.chooseFolders() }
					.accessibilityIdentifier("addFolders")
				Button("제거") { model.removeSelectedTargets() }
					.disabled(model.selectedTargets.isEmpty)
					.accessibilityIdentifier("removeFolders")
				Spacer(minLength: 8)
				Button("선택한 폴더에 적용…") {
					model.prepareApply(to: model.selectedTargetPaths.map { URL(fileURLWithPath: $0) })
				}
				.disabled(model.selectedTargets.isEmpty || model.isWorking || !model.canApply(to: model.selectedTargetPaths))
				.help("선택한 각 폴더에 그 폴더에 지정한 프리셋(지정이 없으면 왼쪽에서 선택한 프리셋)을 적용합니다.")
				.accessibilityIdentifier("applySelected")
				Button("전체 폴더에 적용…") {
					model.prepareApply(to: model.targets.map(\.url))
				}
				.buttonStyle(.borderedProminent)
				.disabled(model.targets.isEmpty || model.isWorking || !model.canApply(to: model.targets.map(\.path)))
				.help("모든 폴더에 각자 지정한 프리셋(지정이 없으면 왼쪽에서 선택한 프리셋)을 한 번에 적용합니다.")
				.accessibilityIdentifier("applyAll")
			}
			.controlSize(.small)
			.frame(height: UILayout.actionRowHeight)
		}
	}
}

/// One folder in "2. 적용할 폴더": icon in the preset's color, name and risk note, the path (or the inherited or missing
/// preset note in its place), and the preset tag. A preset dropped here is assigned to this folder; the icon can be
/// dragged to the preset list.
struct TargetRow: View {
	@Environment(AppModel.self) private var model
	let target: TargetFolder
	let tints: [UUID: Color]
	@Binding var listFolderHover: Bool
	@State private var rowHover: RowDropHover?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		let assigned = model.preset(target.presetID)
		let inherited = model.inheritedAssignment(for: target)
		let missing = target.presetID != nil && assigned == nil
		let tint = assigned.flatMap { tints[$0.id] }
		let presetHover = rowHover == .preset
		HStack(spacing: 8) {
			// Only the icon is a drag handle: a drag started anywhere else on the row still extends the selection.
			folderIcon(tint: tint, inheritedTint: inherited.flatMap { tints[$0.preset.id] }, missing: missing)
				.contentShape(Rectangle())
				.draggable(TargetReference(path: target.path)) {
					DragPreview(title: target.name, hint: String(localized: "프리셋 영역에 놓아 프리셋 만들기")) {
						Image(systemName: "folder.fill").foregroundStyle(tint ?? Theme.accentText)
					}
				}
				.help("아이콘을 프리셋 영역에 끌어다 놓으면 이 폴더의 보기 설정으로 프리셋을 만듭니다.")
			// Every row has two lines (so seven folders always fit the list): the name, then the path — or, in the path's
			// place, why the folder is special. Names and paths are cut in the middle; the whole path is their tooltip.
			let path = Fmt.abbreviate(target.path)
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 4) {
					Text(target.name)
						.font(.callout.weight(.medium))
						.lineLimit(1)
						.truncationMode(.middle)
						.help(path)
					if let note = model.riskNote(target.path) {
						Image(systemName: "exclamationmark.triangle.fill")
							.font(.caption)
							.foregroundStyle(OnSelection(Theme.warning, selected: Color.white))
							.help(note)
							.accessibilityLabel(note)
					}
				}
				if missing {
					// Assigned to a preset that is not loaded (e.g. its file could not be read): kept, but skipped on apply.
					let sentence = String(localized: "지정한 프리셋을 찾을 수 없어 적용할 때 건너뜁니다")
					Text("프리셋을 찾을 수 없어 건너뜁니다")
						.font(.subheadline)
						.foregroundStyle(OnSelection(Theme.warning, selected: Color.white))
						.lineLimit(1)
						.help(path + "\n" + sentence)
						.accessibilityLabel(sentence)
						.accessibilityValue(path)
				} else if let inherited {
					// Short on screen (the words must never be cut, only the folder's name); the whole sentence is the
					// tooltip and what VoiceOver reads. The words around the name come from one text ("…의 지정을 따릅니다",
					// "Follows …").
					let sentence = String(localized: "상위 폴더 \(inherited.from.name)의 지정(\(inherited.preset.name))을 따릅니다")
					let words = AppLanguage.around(String(localized: "\(AppLanguage.slot)의 지정을 따릅니다"))
					Label {
						HStack(spacing: 0) {
							if !words.before.isEmpty { Text(words.before).fixedSize() }
							Text(inherited.from.name).lineLimit(1).truncationMode(.middle)
							if !words.after.isEmpty { Text(words.after).fixedSize() }
						}
					} icon: {
						Image(systemName: "arrow.turn.down.right")
					}
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					// One text element (not the symbol and the two texts apart): the sentence, then the path.
					.accessibilityElement(children: .ignore)
					.accessibilityAddTraits(.isStaticText)
					.accessibilityLabel(sentence)
					.accessibilityValue(path)
					.help(path + "\n" + sentence)
				} else {
					Text(path)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
						.help(path)
				}
			}
			.layoutPriority(1)
			Spacer(minLength: 4)
			ZStack {
				PresetTag(target: target, assigned: assigned, tint: tint)
					.opacity(presetHover ? 0 : 1)
				DropCapsuleSmall()
					.opacity(presetHover ? 1 : 0)
					.accessibilityHidden(!presetHover)
			}
			.frame(width: UILayout.tag.width, height: UILayout.tag.height)
		}
		.padding(.vertical, 1.5)
		.padding(.horizontal, 2)
		.frame(maxWidth: .infinity, alignment: .leading)
		// The row separator starts under the name column (without this, List takes the leading edge of whichever
		// Label it finds first — the hidden drop capsule or the inherited note — and the lines start at random places).
		.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 2 + 20 + 8 }
		.background {
			if presetHover {
				// On a selected row (accent background) the accent would disappear: white there, like the other row parts.
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(OnSelection(Theme.accentText.opacity(0.12), selected: Color.white.opacity(0.22)))
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(OnSelection(Theme.accentText, selected: Color.white), lineWidth: contrast == .increased ? 2.5 : 2)
			}
		}
		.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: presetHover)
		.contentShape(Rectangle())
		.onDrop(of: [.presetReference, .fileURL],
		        delegate: TargetRowDropDelegate(path: target.path, model: model, rowHover: $rowHover, listFolderHover: $listFolderHover))
	}

	@ViewBuilder private func folderIcon(tint: Color?, inheritedTint: Color?, missing: Bool) -> some View {
		Group {
			if let tint {
				Image(systemName: "folder.fill").foregroundStyle(OnSelection(tint, selected: Color.white))
			} else if missing {
				Image(systemName: "folder.fill").foregroundStyle(OnSelection(Theme.warning, selected: Color.white))
			} else if let inheritedTint {
				Image(systemName: "folder.fill").foregroundStyle(OnSelection(inheritedTint.opacity(0.5), selected: Color.white.opacity(0.6)))
			} else {
				Image(systemName: "folder").foregroundStyle(.secondary)
			}
		}
		.font(.system(size: 15))
		.frame(width: 20)
		.accessibilityHidden(true)
	}
}

/// Shown in the tag's place while a preset is dragged over the row: white text on the accent fill (like the list's
/// drop capsule) with a white rim, so it reads the same on a plain row and on the accent selection.
private struct DropCapsuleSmall: View {
	var body: some View {
		Label("여기에 놓아 지정", systemImage: "arrow.down.circle.fill")
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(.white)
			.lineLimit(1)
			.frame(width: UILayout.tag.width, height: UILayout.tag.height)
			.background(Theme.accent, in: Capsule())
			.overlay(Capsule().strokeBorder(OnSelection(Color.clear, selected: Color.white), lineWidth: 1.5))
			.shadow(color: Theme.shadow, radius: 3, y: 1)
	}
}

/// The folder's own preset: a capsule pull-down in the preset's color ("선택한 프리셋 사용", the presets, "찾을 수 없는 프리셋").
struct PresetTag: View {
	@Environment(AppModel.self) private var model
	@Environment(\.colorSchemeContrast) private var contrast
	/// Room for the name between the dot and the chevron (136 − 18 − 18 − the menu's own insets).
	static let textWidth: CGFloat = 92
	let target: TargetFolder
	let assigned: Preset?
	let tint: Color?

	var body: some View {
		let shown = assigned?.name ?? (target.presetID != nil ? String(localized: "찾을 수 없는 프리셋") : String(localized: "선택한 프리셋 사용"))
		let missing = target.presetID != nil && assigned == nil
		Menu {
			Picker("이 폴더의 프리셋", selection: Binding(get: { target.presetID }, set: { model.assignPreset($0, to: [target.path]) })) {
				Text("선택한 프리셋 사용").tag(UUID?.none)
				if !model.presets.isEmpty { Divider() }
				ForEach(model.presets) { p in Text(p.name).tag(UUID?.some(p.id)) }
				if let id = target.presetID, missing {
					Text("찾을 수 없는 프리셋").tag(UUID?.some(id))
				}
			}
			.pickerStyle(.inline)
			.labelsHidden()
		} label: {
			// The menu does not truncate its title (it would run past the capsule): shortened here to the text slot.
			Text(Fmt.fitted(shown, width: Self.textWidth, font: .systemFont(ofSize: NSFont.systemFontSize(for: .small))))
				.foregroundStyle(assigned == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
				.lineLimit(1)
				.truncationMode(.middle)
		}
		.menuStyle(.button)
		.buttonStyle(.borderless)
		.menuIndicator(.hidden)
		// The menu's label follows the control size, not `.font` (small = the 11pt of `.subheadline`).
		.controlSize(.small)
		.font(.subheadline)
		.padding(.leading, 18)
		.padding(.trailing, 18)
		.frame(width: UILayout.tag.width, height: UILayout.tag.height, alignment: .leading)
		.background {
			Capsule().fill(OnSelection(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(Theme.well),
			                           selected: Color.white.opacity(0.16)))
			Capsule().strokeBorder(OnSelection(missing ? AnyShapeStyle(Theme.warning)
			                                   : (tint.map { AnyShapeStyle($0.opacity(contrast == .increased ? 1 : 0.45)) } ?? AnyShapeStyle(Theme.cardStroke(contrast))),
			                                   selected: Color.white.opacity(0.55)),
			                       style: StrokeStyle(lineWidth: 1, dash: assigned == nil && !missing ? [3, 2] : []))
		}
		.overlay(alignment: .leading) {
			Group {
				if let tint {
					PresetDot(tint: tint)
				} else {
					Circle()
						.fill(OnSelection(missing ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.tertiary), selected: Color.white.opacity(0.7)))
						.frame(width: 7, height: 7)
				}
			}
			.padding(.leading, 8)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
		}
		.overlay(alignment: .trailing) {
			Image(systemName: "chevron.up.chevron.down")
				.font(.system(size: 8, weight: .semibold))
				.foregroundStyle(.secondary)
				.padding(.trailing, 8)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
		}
		.help(assigned.map { "이 폴더에는 프리셋 \"\($0.name)\"을(를) 적용합니다." }
			?? "지정한 프리셋이 없습니다: \(model.fallbackNote(for: target)) 다른 프리셋을 고르면 이 폴더에는 그 프리셋이 적용됩니다.")
		// Its own name ("프리셋" is the area's title, "Presets" in English): the menu of this folder's preset.
		.accessibilityLabel("이 폴더의 프리셋")
		.accessibilityValue(shown)
	}
}

/// Right-click menu of the folder list; acts on the clicked row or on every selected row.
struct TargetContextMenu: View {
	@Environment(AppModel.self) private var model
	let paths: Set<String>

	var body: some View {
		let rows = model.targets.filter { paths.contains($0.path) }
		Menu("프리셋 지정") {
			ForEach(model.presets) { p in
				Toggle(p.name, isOn: Binding(get: { !rows.isEmpty && rows.allSatisfy { $0.presetID == p.id } },
				                             set: { _ in model.assignPreset(p.id, to: paths) }))
			}
		}
		.disabled(model.presets.isEmpty)
		Button("지정 해제") { model.assignPreset(nil, to: paths) }
			.disabled(!rows.contains { $0.presetID != nil })
		Divider()
		Button(rows.count > 1 ? "\(rows.count)개 폴더 제거" : "제거") { model.removeTargets(paths) }
	}
}

import SwiftUI
import FinderPresetsCore

/// "3. 시스템 전체에 적용": one line under the two columns — the preset it writes (the one selected on the left), the
/// two options and the button. Finder's global defaults and the standard home folders.
struct SystemBar: View {
	@Environment(AppModel.self) private var model
	@Environment(\.colorSchemeContrast) private var contrast

	static var help: String { String(localized: "Finder의 기본 보기(고유 설정이 없는 모든 폴더)를 선택한 프리셋으로 바꿉니다. Finder가 자동으로 다시 시작됩니다.") }

	var body: some View {
		@Bindable var model = model
		let preset = model.selectedPreset
		let tint = preset.flatMap { PresetTint.map(for: model.presets)[$0.id] }
		let desktopWarning = model.applyToHomeFolders && model.includeDesktop
		HStack(spacing: 10) {
			HStack(spacing: 6) {
				StepBadge(number: 3)
				Text("시스템 전체")
					.font(.headline)
					.lineLimit(1)
					.accessibilityLabel("3. 시스템 전체에 적용")
					.accessibilityAddTraits(.isHeader)
					.accessibilityHint(Self.help)
			}
			.fixedSize()
			.help(Self.help)
			.probeFrame("systemTitle")
			PresetChip(preset: preset, tint: tint ?? PresetTint.colors[0])
				.frame(width: UILayout.presetChipWidth, alignment: .leading)
				.probeFrame("systemPreset")
			HStack(spacing: 10) {
				// VoiceOver and Voice Control use the visible name; the help (read as the hint) says what it covers.
				Toggle("홈 폴더 포함", isOn: $model.applyToHomeFolders)
					.help("홈 폴더 자체와 그 안의 폴더에도 적용합니다: 표준 폴더(문서·다운로드·사진·음악·동영상)는 하위 폴더까지 모두, 그 밖의 폴더는 고유 보기 설정이 있는 것만 바꿉니다(나머지는 바뀐 Finder 기본 보기를 따릅니다). ~/Library와 숨김 폴더는 건드리지 않습니다.")
					.accessibilityIdentifier("applyToHomeFolders")
				HStack(spacing: 4) {
					Toggle("데스크탑 포함", isOn: $model.includeDesktop)
						.disabled(!model.applyToHomeFolders)
						.accessibilityIdentifier("includeDesktop")
					// Always takes its place (only hidden), so switching it on or off moves nothing.
					Label("아이콘 위치 변경 주의", systemImage: "exclamationmark.triangle.fill")
						.font(.subheadline)
						.foregroundStyle(Theme.warning)
						.lineLimit(1)
						.help("데스크탑의 아이콘 위치가 바뀔 수 있습니다.")
						// One element (not the symbol and the text apart, both read with the same sentence and id).
						.accessibilityElement(children: .ignore)
						.accessibilityAddTraits(.isStaticText)
						.accessibilityLabel("데스크탑의 아이콘 위치가 바뀔 수 있습니다.")
						.opacity(desktopWarning ? 1 : 0)
						.accessibilityHidden(!desktopWarning)
						.accessibilityIdentifier("desktopWarning")
				}
			}
			.fixedSize()
			.accessibilityElement(children: .contain)
			.accessibilityIdentifier("systemOptions")
			.probeFrame("systemOptions")
			Spacer(minLength: 8)
			// A dangerous action: bordered, never the prominent style.
			Button("시스템 전체에 적용…") { model.prepareGlobalApply() }
				.buttonStyle(.bordered)
				.disabled(model.selectedPreset == nil || model.isWorking)
				.fixedSize()
				.accessibilityIdentifier("applySystem")
				.probeFrame("applySystem")
		}
		.controlSize(.small)
		.padding(.horizontal, UILayout.edge)
		.frame(width: UILayout.content.width, height: UILayout.systemBarHeight)
		.background(Theme.canvas)
		.overlay(alignment: .top) {
			Rectangle()
				.fill(Theme.hairline(contrast))
				.frame(height: 1)
				.padding(.horizontal, UILayout.edge)
				.accessibilityHidden(true)
		}
		.probeFrame("systemBar")
	}
}

/// The preset "시스템 전체에 적용…" writes: a capsule with its color dot and name, or a dashed hint to select one.
struct PresetChip: View {
	let preset: Preset?
	let tint: Color
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		Group {
			if let preset {
				HStack(spacing: 5) {
					PresetDot(tint: tint)
					Text(preset.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
				}
				.padding(.horizontal, 8)
				.frame(height: 20)
				.background(Theme.chip, in: Capsule())
				.overlay(Capsule().strokeBorder(Theme.hairline(contrast), lineWidth: 1))
			} else {
				// The only hint why "시스템 전체에 적용…" is disabled: secondary, not the faint tertiary.
				Label("프리셋을 선택하세요", systemImage: "arrow.left")
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.padding(.horizontal, 8)
					.frame(height: 20)
					.overlay(Capsule().strokeBorder(Theme.hairline(contrast), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
			}
		}
		.font(.subheadline)
		.help(preset.map { "적용할 프리셋: \($0.name)" } ?? "왼쪽에서 프리셋을 선택하세요")
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(preset.map { "적용할 프리셋: \($0.name)" } ?? "왼쪽에서 프리셋을 선택하세요")
	}
}

struct GlobalConfirmSheet: View {
	@Environment(AppModel.self) private var model
	static let width: CGFloat = 440

	var body: some View {
		let pending = model.pendingGlobalApply
		let tint = pending.flatMap { PresetTint.map(for: model.presets)[$0.preset.id] }
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				GradientTile(systemImage: "macwindow.on.rectangle", size: 30)
				VStack(alignment: .leading, spacing: 2) {
					Text("시스템 전체에 적용할까요?").font(.headline)
					HStack(spacing: 5) {
						Text("프리셋:")
						PresetDot(tint: tint ?? PresetTint.colors[0])
						Text(pending?.preset.name ?? "").lineLimit(1).truncationMode(.middle).help(pending?.preset.name ?? "")
					}
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel("프리셋 \(pending?.preset.name ?? "")")
				}
			}
			ScrollView {
				Text(message)
					.font(.callout)
					.frame(maxWidth: .infinity, alignment: .leading)
					.fixedSize(horizontal: false, vertical: true)
					.probeFrame("globalMessage")
			}
			.scrollBounceBehavior(.basedOnSize)
			.frame(maxHeight: 80)
			.fixedSize(horizontal: false, vertical: true)
			.probeFrame("globalMessageArea")
			if let pending, !pending.roots.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					Text("대상 폴더").font(.callout.weight(.semibold))
					ScrollView {
						VStack(alignment: .leading, spacing: 3) {
							// The home folder comes first: itself and its folders with settings of their own; the standard
							// folders after it, each with all its subfolders.
							ForEach(Array(pending.roots.enumerated()), id: \.element) { i, url in
								HStack(spacing: 6) {
									Label(FileManager.default.displayName(atPath: url.path), systemImage: i == 0 ? "house" : "folder")
										.foregroundStyle(.secondary)
									Text(i == 0 ? String(localized: "자체와 고유 설정이 있는 폴더") : String(localized: "하위 폴더 모두"))
										.foregroundStyle(.tertiary)
								}
								.font(.callout)
								.lineLimit(1)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					.scrollBounceBehavior(.basedOnSize)
					.frame(maxHeight: 72)
					.fixedSize(horizontal: false, vertical: true)
				}
			}
			RestartNote(text: String(localized: "열려 있는 Finder 창은 닫혔다가 다시 열립니다(검색·최근 항목 창 제외).\n진행 중인 복사나 이동이 있으면 끝난 뒤에 하세요.\n바뀌기 전 상태는 자동으로 백업됩니다."))
			HStack {
				Spacer()
				Button("취소", role: .cancel) { model.cancelPendingGlobalApply() }
					.keyboardShortcut(.cancelAction)
					.accessibilityIdentifier("globalCancel")
				// Quits Finder and writes its defaults: a click, never Return (like the history sheet's global undo).
				Button("적용") { model.confirmGlobalApply() }
					.buttonStyle(.borderedProminent)
					.accessibilityIdentifier("globalApply")
			}
		}
		.padding(16)
		.frame(width: Self.width)
		.sheetSurface()
	}

	private var message: String {
		guard let p = model.pendingGlobalApply else { return "" }
		let name = p.preset.name
		let global = !p.writesGlobalDefaults ? String(localized: "그룹 기준만 있는 프리셋이라 Finder 기본 보기는 바꾸지 않고,")
			: p.globalDiffs.isEmpty ? String(localized: "Finder 기본 보기는 이미 \"\(name)\"과 같고,")
			: String(localized: "Finder 기본 보기를 \"\(name)\"(으)로 바꾸고,")
		let resets = p.plan?.iconPositionResets ?? 0
		// No view changes but icon positions to reset: the positions note alone describes what is written in the home folder.
		let folders: String?
		if p.roots.isEmpty { folders = String(localized: "홈 폴더는 건드리지 않습니다.") }
		else if p.folderChanges == 0 { folders = resets == 0 ? String(localized: "홈 폴더는 이미 동일해 바꾸지 않습니다.") : nil }
		else { folders = String(localized: "\(p.folderChanges)개 폴더를 바꿉니다.") }
		let parts = [global, folders, resets == 0 ? nil : AppModel.iconPositionsNote(resets)].compactMap { $0 }
		return parts.joined(separator: " ") + GlobalApplyPlan.groupNote(p.preset) + " "
			+ String(localized: "Finder가 자동으로 다시 시작됩니다.")
	}
}

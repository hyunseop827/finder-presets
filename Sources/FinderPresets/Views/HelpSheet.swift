import SwiftUI
import AppKit

struct HelpSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.colorSchemeContrast) private var contrast
	@State private var dontShowAgain = UserDefaults.standard.bool(forKey: AppModel.helpDismissedKey)
	@State private var showDeveloper = false

	/// The steps, each short enough that ①–⑧ and the folded developer section fit the sheet without scrolling in both
	/// languages (the layout probe measures it); what more a step has to say is its tooltip.
	private static let steps: [(text: String, help: String?)] = [
		(String(localized: "Finder에서 폴더를 원하는 모양(보기 방식, 아이콘 크기, 정렬)으로 맞추고 창을 닫습니다."), nil),
		(String(localized: "그 폴더를 왼쪽 \"프리셋\" 목록에 끌어다 놓으면 그 모양이 프리셋이 됩니다."), nil),
		(String(localized: "바꿀 폴더를 오른쪽 \"적용할 폴더\"에 끌어다 놓고 \"선택한 폴더에 적용…\" 또는 \"전체 폴더에 적용…\"을 누릅니다. 폴더마다 다른 프리셋을 쓰려면 행의 메뉴에서 고르거나 프리셋을 그 행에 끌어다 놓습니다."),
		 String(localized: "지정하지 않은 폴더는 왼쪽에서 선택한 프리셋을 쓰고, \"하위 폴더 포함\"이면 하위 폴더도 같은 프리셋을 씁니다.")),
		(String(localized: "아래쪽 \"시스템 전체에 적용…\"은 Finder 기본 보기와 홈 폴더(창 자체와 그 안의 폴더)를 한 번에 바꿉니다. Finder가 자동으로 다시 시작됩니다."),
		 String(localized: "Finder가 다시 시작되면 열려 있던 Finder 창이 다시 열립니다(검색·최근 항목 창 제외).")),
		(String(localized: "이미 열어본 폴더는 Finder를 다시 시작해야 새 모양이 보입니다."), nil),
		(String(localized: "바뀌기 전 상태는 자동으로 백업되고, 툴바의 \"기록\"에서 되돌릴 수 있습니다."), nil),
		// The Finder services (FinderServices.swift): the titles Finder shows are the tooltip.
		(String(localized: "Finder에서 폴더를 오른쪽 클릭한 뒤 \"서비스\"에서도 폴더 추가, 프리셋 만들기, 적용을 할 수 있습니다."),
		 String(localized: "서비스 메뉴의 이름: \"\(FinderService.addFolders.localizedTitle)\", \"\(FinderService.makePresets.localizedTitle)\", \"\(FinderService.apply.localizedTitle)\"(적용 전에 확인 창을 엽니다).")),
		// The quick preset (QuickPreset.swift): where its shortcut is set and what it does to Finder is the tooltip.
		(String(localized: "별표한 프리셋은 단축키로 앞 Finder 창의 폴더에만 바로 적용할 수 있습니다."),
		 String(localized: "단축키는 시스템 설정 > 키보드 > 키보드 단축키 > 서비스의 \"\(FinderService.quickApply.localizedTitle)\"에 지정합니다(추천 ⌃⌥⌘P). 앱의 설정 창에서 \"설정 방법 보기…\"를 누르면 그 화면까지 단계별로 안내합니다. 적용하면 Finder가 다시 시작되고, 열려 있던 Finder 창과 그 폴더가 다시 열립니다. 되돌리기는 \"기록\"에서 합니다."))
	]
	private static let marks = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧"]
	private static let drags: [(symbol: String, from: String, to: String, result: String, spoken: String)] = [
		("folder.badge.plus", String(localized: "폴더"), String(localized: "프리셋"), String(localized: "프리셋 만들기"),
		 String(localized: "폴더를 프리셋 목록에 끌어다 놓아 프리셋 만들기")),
		("rectangle.stack", String(localized: "프리셋"), String(localized: "폴더 행"), String(localized: "지정"),
		 String(localized: "프리셋을 폴더 행에 끌어다 놓아 그 폴더에 지정")),
		("plus.rectangle.on.folder", String(localized: "Finder 폴더"), String(localized: "폴더 목록"), String(localized: "폴더 추가"),
		 String(localized: "Finder 폴더를 폴더 목록에 끌어다 놓아 폴더 추가"))
	]
	/// Height of the fade at the bottom of the steps: tells that more follows when the text does not fit.
	static let fade: CGFloat = 14
	/// Fixed size of the sheet (smaller than the window's content, so it never pushes the window).
	static let size = CGSize(width: 600, height: 420)

	/// For developers (folded away; undo is in "기록"): the `finder-presets` commands for the data folder the app is actually using.
	/// An app started with FINDER_PRESETS_DATA_DIR points them at the same operations (the default folder holds other, real
	/// operations). The path is written for the shell (`"$HOME/…"`, never a quoted `~`, which the shell would not expand).
	private var undoCommands: String {
		var lines: [String] = []
		if !(ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"] ?? "").isEmpty {
			lines.append("export FINDER_PRESETS_DATA_DIR=\(Self.shellQuoted(model.dirs.root.path))")
		}
		lines += [
			String(localized: "# 작업 목록과 ID"),
			"finder-presets ops",
			String(localized: "# 폴더 되돌리기"),
			"finder-presets undo <ID>",
			String(localized: "# Finder 기본 보기 되돌리기 (Finder가 다시 시작됩니다)"),
			"finder-presets global-undo <ID> --i-understand-finder-restarts",
			String(localized: "# 고정 / 보관 정책 미리보기"),
			"finder-presets pin <ID>",
			"finder-presets ops --prune"
		]
		return lines.joined(separator: "\n")
	}

	static func shellQuoted(_ path: String) -> String {
		func escaped(_ s: some StringProtocol) -> String {
			s.reduce(into: "") { out, c in
				if "\"$`\\".contains(c) { out.append("\\") }
				out.append(c)
			}
		}
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		if path.hasPrefix(home + "/") { return "\"$HOME/" + escaped(path.dropFirst(home.count + 1)) + "\"" }
		return "\"" + escaped(path) + "\""
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 10) {
				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 32, height: 32)
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 1) {
					Text("사용법").font(.title3.bold()).accessibilityAddTraits(.isHeader)
					Text("대부분의 작업은 끌어다 놓기로 합니다").font(.subheadline).foregroundStyle(.secondary)
				}
			}
			HStack(spacing: 8) {
				ForEach(Self.drags, id: \.result) { drag in
					HStack(alignment: .top, spacing: 7) {
						GradientTile(systemImage: drag.symbol, size: 22)
						VStack(alignment: .leading, spacing: 1) {
							Text(drag.from).font(.callout.weight(.semibold)).lineLimit(1)
							Text(verbatim: "→ \(drag.to)").font(.callout.weight(.semibold)).lineLimit(1)
							Text(drag.result).font(.caption).foregroundStyle(Theme.accentText).lineLimit(1)
						}
						Spacer(minLength: 0)
					}
					.padding(.horizontal, 7)
					.padding(.vertical, 6)
					.frame(maxWidth: .infinity)
					.background(Theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
					.overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline(contrast)))
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(drag.spoken)
				}
			}
			ScrollViewReader { proxy in
				ScrollView {
					VStack(alignment: .leading, spacing: 5) {
						ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
							HStack(alignment: .firstTextBaseline, spacing: 8) {
								Text(Self.marks[i]).font(.headline).foregroundStyle(Theme.accentText).accessibilityHidden(true)
								Text(step.text).font(.callout).fixedSize(horizontal: false, vertical: true)
									.frame(maxWidth: .infinity, alignment: .leading)
							}
							.accessibilityElement(children: .combine)
							.help(step.help ?? "")
						}
						DisclosureGroup(isExpanded: $showDeveloper) {
							developerDetails.padding(.top, 6)
						} label: {
							Text(String(localized: "개발자용: 터미널 명령")).font(.callout.weight(.semibold))
						}
						// One container carries the identifier (set on the group itself, every text inside got it).
						.accessibilityElement(children: .contain)
						.accessibilityIdentifier("helpDeveloper")
						.id("developer")
					}
					// The steps and the folded section; the layout probe checks they fit the scroll area above the fade.
					.probeFrame("helpSteps")
					.padding(.trailing, 8)
					.padding(.bottom, Self.fade)   // at the end, only this padding sits under the fade
				}
				.scrollBounceBehavior(.basedOnSize)
				.flashScrollIndicatorsOnAppear()
				.probeFrame("helpScroll")
				.mask {
					VStack(spacing: 0) {
						Color.black
						LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
							.frame(height: Self.fade)
					}
				}
				.frame(maxHeight: .infinity)
				.onChange(of: showDeveloper) { _, open in
					guard open else { return }
					Task { @MainActor in
						try? await Task.sleep(for: .milliseconds(50))
						withAnimation { proxy.scrollTo("developer", anchor: .top) }
					}
				}
			}
			Divider()
			HStack {
				Toggle("다시 보지 않기", isOn: $dontShowAgain)
					.accessibilityIdentifier("helpDontShowAgain")
				Spacer()
				Button("닫기") { model.dismissHelp(dontShowAgain: dontShowAgain) }
					.keyboardShortcut(.defaultAction)
					.accessibilityIdentifier("helpClose")
			}
		}
		.padding(16)
		.frame(width: Self.size.width, height: Self.size.height)
		.sheetSurface()
	}

	private var developerDetails: some View {
		VStack(alignment: .leading, spacing: 6) {
			if !(ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"] ?? "").isEmpty {
				// A development run: where the Finder services go (FinderServices.swift).
				Text(String(localized: "이 실행은 FINDER_PRESETS_DATA_DIR의 데이터 폴더를 씁니다. Finder 서비스도 떠 있는 이 앱이 받아 이 폴더에 씁니다. 앱이 꺼져 있을 때 서비스를 고르면 macOS가 앱을 기본 데이터 폴더로 실행합니다."))
					.font(.callout)
					.foregroundStyle(Theme.warning)
					.fixedSize(horizontal: false, vertical: true)
			}
			Text(String(localized: "되돌리기와 고정은 툴바의 \"기록\"에서 합니다. 아래는 소스에서 빌드한 명령줄 도구 finder-presets용입니다(디스크 이미지에는 없습니다)."))
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Text(String(localized: "백업 위치: \(Fmt.abbreviate(model.dirs.root.path) + "/operations")"))
				.font(.callout)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.truncationMode(.middle)
				.textSelection(.enabled)
			Text(undoCommands)
				.font(.system(.subheadline, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(8)
				.background(Theme.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline(contrast)))
			Text(String(localized: "시스템 전체 적용은 바뀐 쪽의 작업만 남깁니다(홈 폴더는 apply, Finder 기본 보기는 applyGlobal). 기록이나 finder-presets ops에서 같은 시각의 작업을 찾으세요."))
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

private extension View {
	/// macOS 15+: shows the scroll indicator briefly when the sheet opens (the overlay scroller is hidden otherwise).
	@ViewBuilder func flashScrollIndicatorsOnAppear() -> some View {
		if #available(macOS 15, *) {
			scrollIndicatorsFlash(onAppear: true)
		} else {
			self
		}
	}
}

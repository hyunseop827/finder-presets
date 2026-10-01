import SwiftUI

/// One line, fixed height. Text that does not fit is cut and gets a button that shows all of it in a popover (the
/// whole bar's tooltip carries it too). The icon slot has a fixed size, so switching between the spinner and an
/// icon never moves the text. On the right: quiet links to the history, the guide and this build's release page.
struct StatusBar: View {
	@Environment(AppModel.self) private var model
	@State private var showFull = false

	enum Tone: Equatable { case working, success, warning, info }

	/// Worded like the model's status strings, in both languages (the English texts in Resources/en.lproj use the same
	/// words; a unit test checks every translated text against its Korean one). The warnings are checked first: a
	/// "완료: …" line can still report failed folders ("3개 실패"), a failed Finder relaunch, folders Finder overwrote,
	/// home folders that were not changed or folders an undo skipped because they changed again ("충돌").
	static let warningPrefixes = ["중단", "아무것도 바꾸지 않았습니다", "확인하는 동안", "Stopped", "Nothing was changed", "While checking"]   // l10n-exempt
	static let warningWords = ["실패", "덮어씀", "덮어썼", "변경 안 됨", "변경됐을 수 있습니다", "충돌",   // l10n-exempt
	                           "failed", "overwrote", "not changed", "may already have changed", "conflict"]
	static let successPrefixes = ["완료", "Finder를 다시 시작했습니다", "Done", "Finder was restarted"]   // l10n-exempt

	/// Only the app's own words decide: the names a status text holds (presets, folders, files — set apart with `Fmt.name`)
	/// are left out first, so a preset called "Failed takes" or a folder called "충돌 보고서" changes nothing.
	static func tone(status: String, working: Bool) -> Tone {
		if working { return .working }
		let words = withoutNames(status)
		if warningPrefixes.contains(where: { words.hasPrefix($0) }) || warningWords.contains(where: { words.contains($0) }) { return .warning }
		if successPrefixes.contains(where: { words.hasPrefix($0) }) { return .success }
		return .info
	}

	/// `status` without the parts `Fmt.name` set apart (between U+2068 and U+2069, nested or not).
	static func withoutNames(_ status: String) -> String {
		var kept = String.UnicodeScalarView()
		var depth = 0
		for scalar in status.unicodeScalars {
			switch scalar.value {
			case 0x2068: depth += 1
			case 0x2069: depth = max(0, depth - 1)
			default: if depth == 0 { kept.append(scalar) }
			}
		}
		return String(kept)
	}

	var body: some View {
		let status = model.status
		let tone = Self.tone(status: status, working: model.isWorking)
		HStack(spacing: 6) {
			Group {
				switch tone {
				case .working:
					ProgressView().controlSize(.mini).accessibilityLabel("진행 중")
				case .success:
					Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityLabel("완료")
				case .warning:
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).accessibilityLabel("주의")
				case .info:
					Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel("정보")
				}
			}
			.imageScale(.small)
			.frame(width: 14, height: 14)
			ViewThatFits(in: .horizontal) {
				Text(status).lineLimit(1)
				HStack(spacing: 6) {
					Text(status).lineLimit(1).truncationMode(.tail)
					Button { showFull = true } label: { Image(systemName: "text.bubble") }
						.buttonStyle(.borderless)
						.controlSize(.small)
						.help("상태 전체 보기")
						.accessibilityLabel("상태 전체 보기")
						.accessibilityIdentifier("statusDetails")
						.probeFrame("statusDetails")
						.popover(isPresented: $showFull, arrowEdge: .top) {
							ScrollView {
								// Its own style: the bar's small secondary text is not meant for reading a long message.
								Text(status)
									.font(.body)
									.foregroundStyle(.primary)
									.textSelection(.enabled)
									.fixedSize(horizontal: false, vertical: true)
									.frame(maxWidth: .infinity, alignment: .leading)
									.padding(14)
							}
							// A message that fits does not bounce (like the app's other scroll areas).
							.scrollBounceBehavior(.basedOnSize)
							.frame(width: 420)
							.frame(maxHeight: 240)
						}
				}
			}
			.font(.subheadline)
			.foregroundStyle(.secondary)
			Spacer(minLength: 0)
			// Right after an apply, while its report is the status line: a shortcut to that operation's undo (the history
			// sheet opens on it with the confirmation; nothing is undone before "되돌리기" there).
			if let id = model.undoShortcutID, !model.isWorking {
				Button { model.openHistory(select: id, startUndo: true) } label: {
					Label(String(localized: "되돌리기…"), systemImage: "arrow.uturn.backward")
				}
				.buttonStyle(.borderless)
				.controlSize(.small)
				.font(.subheadline)
				.fixedSize()
				.help(String(localized: "방금 한 작업을 되돌립니다. 기록에서 확인을 먼저 묻습니다."))
				.accessibilityIdentifier("statusUndo")
				.probeFrame("statusUndo")
			}
			// The window's other places as text links, not toolbar buttons: the history (⌘Y), the guide (⌘?) and this
			// build's version, which opens GitHub's latest release page (ReleaseLink). The menus have the same three.
			Divider().frame(height: 12)
			HStack(spacing: 12) {
				FooterLink(Self.historyLabel, help: String(localized: "작업 기록 보기 · 되돌리기"), id: "history") { model.openHistory() }
				FooterLink(Self.helpLabel, help: String(localized: "사용법 보기"), id: "help") { model.showHelp = true }
				FooterLink(ReleaseLink.footerLabel(), symbol: "arrow.up.right", help: ReleaseLink.help(), id: "latestRelease",
				           accessibilityName: ReleaseLink.fallbackLabel) { model.openLatestRelease() }
			}
			.fixedSize()
		}
		.padding(.horizontal, UILayout.edge)
		.frame(maxWidth: .infinity)
		.frame(height: UILayout.statusBarHeight)
		.background(.bar)
		.overlay(alignment: .top) { Divider() }
		.help(status)
		.onChange(of: status) { showFull = false }
		.probeFrame("statusBar")
	}
}

extension StatusBar {
	/// The links' names, left to right (the layout probe and AppHelpersTests.fixedLayoutBudget measure them).
	static var historyLabel: String { String(localized: "기록") }
	static var helpLabel: String { String(localized: "사용법") }
	static func linkLabels(version: String? = ReleaseLink.appVersion) -> [String] {
		[historyLabel, helpLabel, ReleaseLink.footerLabel(version: version)]
	}
}

/// A text link for the status bar: secondary text that turns primary and underlined under the pointer, with the link
/// pointer. Still a button for VoiceOver and Full Keyboard Access.
struct FooterLink: View {
	let title: String
	let symbol: String?
	let help: String
	let id: String
	let accessibilityName: String?
	let action: () -> Void
	@State private var hovering = false

	init(_ title: String, symbol: String? = nil, help: String, id: String, accessibilityName: String? = nil,
	     action: @escaping () -> Void) {
		self.title = title
		self.symbol = symbol
		self.help = help
		self.id = id
		self.accessibilityName = accessibilityName
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 2) {
				Text(title).underline(hovering)
				if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
			}
			.foregroundStyle(hovering ? .primary : .secondary)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.font(.subheadline)
		.onHover { hovering = $0 }
		.modifier(LinkPointer())
		.help(help)
		.accessibilityLabel(accessibilityName ?? title)
		.accessibilityValue(accessibilityName == nil ? "" : title)
		.accessibilityIdentifier(id)
		// Not just `id`: the probe drops every frame whose name starts with "help" when the guide sheet closes.
		.probeFrame("link-" + id)
	}
}

/// The pointing hand over a link: the system pointer style from macOS 15, the cursor stack before it.
private struct LinkPointer: ViewModifier {
	func body(content: Content) -> some View {
		if #available(macOS 15.0, *) {
			content.pointerStyle(.link)
		} else {
			content.onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
		}
	}
}

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
			// update check (AppUpdater, like 앱 메뉴 > "업데이트 확인…"; its tooltip names this build's version).
			Divider().frame(height: 12)
			HStack(spacing: 12) {
				FooterLink(Self.historyLabel, help: String(localized: "작업 기록 보기 · 되돌리기"), id: "history") { model.openHistory() }
				FooterLink(Self.helpLabel, help: String(localized: "사용법 보기"), id: "help") { model.showHelp = true }
				FooterLink(AppUpdater.linkName, help: AppUpdater.help(enabled: AppUpdater.shared.canCheck), id: "checkForUpdates") {
					AppUpdater.shared.checkForUpdates()
				}
				.disabled(!AppUpdater.shared.canCheck)
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
	static var linkLabels: [String] { [historyLabel, helpLabel, AppUpdater.linkName] }
}

/// A text link for the status bar: secondary text that turns primary and underlined under the pointer, with the link
/// pointer. Still a button for VoiceOver and Full Keyboard Access. A disabled link (the update check without an updater)
/// is dimmed by the button and stays as it is under the pointer, so it does not look like something to click.
struct FooterLink: View {
	let title: String
	let help: String
	let id: String
	let action: () -> Void
	@Environment(\.isEnabled) private var isEnabled
	@State private var hovering = false

	init(_ title: String, help: String, id: String, action: @escaping () -> Void) {
		self.title = title
		self.help = help
		self.id = id
		self.action = action
	}

	var body: some View {
		let highlighted = hovering && isEnabled
		Button(action: action) {
			Text(title)
				.underline(highlighted)
				.foregroundStyle(highlighted ? .primary : .secondary)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.font(.subheadline)
		.onHover { hovering = $0 }
		.modifier(LinkPointer(active: isEnabled))
		.help(help)
		.accessibilityLabel(title)
		.accessibilityIdentifier(id)
		// Not just `id`: the probe drops every frame whose name starts with "help" when the guide sheet closes.
		.probeFrame("link-" + id)
	}
}

/// The pointing hand over a link that works: the system pointer style from macOS 15, the cursor stack before it. There
/// the hand is pushed at most once and popped when the pointer leaves, the link is turned off or the link goes away, so
/// a link that is disabled under the pointer never leaves the hand behind.
private struct LinkPointer: ViewModifier {
	let active: Bool
	@State private var inside = false
	@State private var pushed = false

	func body(content: Content) -> some View {
		if #available(macOS 15.0, *) {
			content.pointerStyle(active ? .link : nil)
		} else {
			content
				.onHover { now in
					inside = now
					update(inside: now, active: active)
				}
				.onChange(of: active) { _, now in update(inside: inside, active: now) }
				.onDisappear { update(inside: false, active: active) }
		}
	}

	private func update(inside: Bool, active: Bool) {
		let wanted = inside && active
		guard wanted != pushed else { return }
		if wanted { NSCursor.pointingHand.push() } else { NSCursor.pop() }
		pushed = wanted
	}
}

import SwiftUI
import AppKit

// "단축키 설정 방법": the walkthrough for the one step the app cannot do for the user — giving the quick preset's service a
// keyboard shortcut in System Settings (QuickPreset.swift, ServiceShortcut.swift). macOS keeps that shortcut per user and
// only the user can set it, so instead of one sentence that says where to go, the sheet leads the way through it one step
// at a time, each with a drawing of the pane in question and a ring around what to click. It never moves by itself: only
// "이전"·"다음" (and ← →) change the step, so each step stands for as long as the user reads it, and a user who leaves
// for System Settings comes back to the step they left. The last step shows whether macOS now has a shortcut for the
// service and whether a preset carries the star — so the user sees the result inside the app.
//
// The drawings are made of SwiftUI shapes, never a screenshot of System Settings: they must not pretend to be the real
// pane (and a bitmap would go stale with every macOS release). What the step is about carries a label and the ring;
// everything else is a grey placeholder bar.
//
// Nothing here writes anything: the only thing the sheet does outside itself is open System Settings (step ①), exactly
// what the Settings window's "키보드 단축키 열기…" does.

/// Opens the walkthrough and holds what it and the Settings window show: the step and the shortcut macOS has for the
/// service now. One instance (`shared`): the Settings window presents the sheet, and `--layout-probe` opens it at a
/// chosen step. The step changes only through `open(at:)`, `go(to:)`, `next()` and `previous()` — there is no timer and
/// no task here, so the walkthrough never advances by itself.
@MainActor
@Observable
final class ShortcutGuide {
	static let shared = ShortcutGuide()

	/// Whether the Settings window shows the sheet.
	var isOpen = false
	private(set) var step = 0
	/// The state the Settings window's line and the last step show, read again by `refresh()`.
	private(set) var shortcut: ServiceShortcutState = .notAssigned
	/// How `refresh()` reads that state: macOS's own domain in the app (`ServiceShortcut.forThisLaunch`, a dictionary in
	/// memory for the development hooks); the unit tests pass a fixed state, so they never read a domain of the system.
	private let readState: @MainActor () -> ServiceShortcutState

	init(readState: @escaping @MainActor () -> ServiceShortcutState = { ServiceShortcut.forThisLaunch.state }) {
		self.readState = readState
	}

	var stepCount: Int { ShortcutGuideSheet.steps.count }
	var isLast: Bool { step >= stepCount - 1 }
	var isFirst: Bool { step <= 0 }

	/// Reads the shortcut again: when the Settings window appears, when the app becomes active again (the user comes back
	/// from System Settings) and when this sheet closes. Only reads (`pbs`, or the dictionary of a development run).
	func refresh() { shortcut = readState() }

	/// Opens the sheet on `step` (kept within the six): "설정 방법 보기…" opens it on the step that mends the state the
	/// Settings window reports, the layout probe on the step it checks.
	func open(at step: Int = 0) {
		refresh()
		self.step = clamped(step)
		isOpen = true
	}

	func close() { isOpen = false }

	/// The step the user asked for ("이전"·"다음", ← →), kept within the six: "다음" on the last step and "이전" on the
	/// first change nothing (their buttons are disabled there).
	func go(to index: Int) { step = clamped(index) }
	func next() { go(to: step + 1) }
	func previous() { go(to: step - 1) }

	private func clamped(_ index: Int) -> Int { min(max(index, 0), stepCount - 1) }
}

/// How the Settings window's line and the walkthrough's last step word the state macOS is in (one wording for both).
///
/// A shortcut alone is not the whole story: without a starred preset, pressing it only brings up "빠른 적용 프리셋이
/// 없습니다" (QuickPreset.swift), so a shortcut without a star is worded as a warning rather than as done. `starred`:
/// `AppModel.quickPreset != nil`. While no shortcut is assigned the star is not the user's next move, so the
/// "아직 지정하지 않았습니다" line says nothing about it (the Settings window's own row above it does).
enum ShortcutStateText {
	static func line(_ state: ServiceShortcutState, starred: Bool) -> String {
		switch state {
		case .notAssigned: String(localized: "단축키: 아직 지정하지 않았습니다")
		case .assigned(let shortcut):
			starred ? String(localized: "단축키: \(shortcut)")
			        : String(localized: "단축키: \(shortcut) — 별표한 프리셋이 없습니다")
		case .switchedOff(let shortcut): String(localized: "단축키: \(shortcut) — 서비스가 꺼져 있습니다")
		}
	}

	static func symbol(_ state: ServiceShortcutState, starred: Bool) -> String {
		isWarning(state, starred: starred) ? "exclamationmark.triangle.fill" : state == .notAssigned ? "keyboard" : "checkmark.circle"
	}

	/// A warning is a state where the shortcut does nothing although macOS has one: the service is switched off, or no
	/// preset carries the star.
	static func isWarning(_ state: ServiceShortcutState, starred: Bool) -> Bool {
		switch state {
		case .notAssigned: false
		case .assigned: !starred
		case .switchedOff: true
		}
	}

	static func help(_ state: ServiceShortcutState, starred: Bool) -> String {
		switch state {
		case .notAssigned:
			String(localized: "\"설정 방법 보기…\"를 누르면 단축키를 지정하는 곳까지 단계별로 안내합니다. 이 앱은 단축키를 직접 지정하지 않습니다.")
		case .assigned:
			starred ? String(localized: "Finder에서 폴더를 열고 이 단축키를 누르면 빠른 적용 프리셋이 그 폴더에 적용됩니다.")
			        : String(localized: "프리셋 목록에서 쓸 프리셋의 별표를 눌러 두세요. 그러면 이 단축키가 그 프리셋을 앞 Finder 창의 폴더에 적용합니다.")
		case .switchedOff:
			String(localized: "시스템 설정 > 키보드 > 키보드 단축키 > 서비스에서 이 항목의 체크상자를 켜야 단축키가 작동합니다.")
		}
	}

	/// The step of the walkthrough that leads out of this state: the check box (④) when the service is switched off, the
	/// last step (which names the star) when that is what is missing, the beginning otherwise. On the main actor, like
	/// the sheet whose steps it counts.
	@MainActor static func step(for state: ServiceShortcutState, starred: Bool) -> Int {
		switch state {
		case .notAssigned: 0
		case .assigned: starred ? 0 : ShortcutGuideSheet.marks.count - 1
		case .switchedOff: 3
		}
	}
}

/// The walkthrough, at one fixed size. It opens on the Settings window (Views/LanguageSettings.swift), which is smaller
/// than the sheet: like the history sheet on the main window, the sheet is the size its content needs.
struct ShortcutGuideSheet: View {
	/// Fixed size. Wider than nothing scrolls: every step's drawing, sentence and controls have their own fixed height.
	static let size = CGSize(width: 440, height: 460)
	/// Heights inside the sheet (they add up to `size` with the 16pt padding and the 10pt spacing).
	/// `textHeight`: four lines of `.callout` (16pt a line in both languages) and 4pt to spare — the longest step needs
	/// three and a half of them in English. The layout probe measures the sentence's own height against this.
	static let textHeight: CGFloat = 68
	static let actionHeight: CGFloat = 24
	/// What the tallest drawing needs: the services list of ④ and ⑤ (a search row 18, "일반" 13, three 18pt rows 7pt
	/// apart 68 and three 8pt gaps 24 = 123) inside `GuidePanel` (title bar 20 + divider 1 + 10pt padding twice).
	static let drawingMinHeight: CGFloat = 164

	struct Step: Identifiable, Sendable {
		var id: Int
		var mark: String
		var title: String
		var text: String
	}

	static let marks = ["①", "②", "③", "④", "⑤", "⑥"]

	/// The six steps. The service's name is the one Finder and System Settings show in this language
	/// (`ServicesMenu.strings`), so the user looks for exactly the words on the screen.
	///
	/// ④ asks the user to *look at* the check box rather than to switch it on: the service is on by default (an empty
	/// `NSRequiredContext` in Info.plist, and `ServiceShortcut.isOn` reads an entry without `enabled_services_menu` as
	/// on), so "turn it on" would make a user who follows the step literally switch off the very service the shortcut
	/// needs. It also carries the two dead ends the README knows: the search field, and the app that macOS has not
	/// registered yet. ⑤ says what an already-taken combination looks like (macOS accepts it and the frontmost app wins,
	/// so the key press does nothing), and ⑥ names the star, without which the shortcut only brings up a refusal.
	static let steps: [Step] = [
		Step(id: 0, mark: marks[0], title: String(localized: "시스템 설정에서 \"키보드\" 열기"),
		     text: String(localized: "시스템 설정을 열고 왼쪽 목록에서 \"키보드\"를 고릅니다. 아래 버튼이 그 화면을 바로 엽니다. 그 화면이 열리면 이 앱으로 돌아와 \"다음\"을 누르세요.")),
		Step(id: 1, mark: marks[1], title: String(localized: "\"키보드 단축키…\" 누르기"),
		     text: String(localized: "키보드 화면 아래쪽의 \"키보드 단축키…\" 버튼을 누릅니다.")),
		Step(id: 2, mark: marks[2], title: String(localized: "왼쪽 목록에서 \"서비스\""),
		     text: String(localized: "열린 창의 왼쪽 목록에서 아래쪽의 \"서비스\"를 고릅니다.")),
		Step(id: 3, mark: marks[3], title: String(localized: "\"일반\" 묶음에서 항목 찾기"),
		     text: String(localized: "\"\(FinderService.quickApply.localizedTitle)\"을 찾습니다. 왼쪽 체크상자는 보통 이미 켜져 있으니 꺼져 있을 때만 켜세요. 안 보이면 위쪽 검색 칸에 이름 일부를 입력하고, 그래도 없으면 앱을 한 번 열었다가 다시 보세요.")),
		Step(id: 4, mark: marks[4], title: String(localized: "원하는 단축키 누르기"),
		     text: String(localized: "그 줄 오른쪽의 단축키 칸을 두 번 누른 뒤 쓰고 싶은 조합을 누릅니다. ⌃⌥⌘P를 권합니다. 이미 다른 앱이 쓰는 조합이면 눌러도 아무 일이 없을 수 있으니, 그럴 때는 다른 조합으로 지정하세요.")),
		Step(id: 5, mark: marks[5], title: String(localized: "앱으로 돌아오기"),
		     text: String(localized: "이 앱으로 돌아오면 지정한 단축키가 아래에 보입니다. 프리셋 목록에서 쓸 프리셋의 별표를 눌러 두면, Finder에서 폴더를 열고 그 단축키를 누르는 것으로 끝입니다."))
	]

	@Environment(\.colorSchemeContrast) private var contrast
	/// Only for the star: the last step must not say the shortcut is ready when nothing carries one (the Settings scene
	/// puts the model in the environment, and a sheet inherits it).
	@Environment(AppModel.self) private var model

	private var guide: ShortcutGuide { ShortcutGuide.shared }

	private var step: Step { Self.steps[min(guide.step, Self.steps.count - 1)] }

	private var starred: Bool { model.quickPreset != nil }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			header
			drawing
				.frame(maxWidth: .infinity, minHeight: Self.drawingMinHeight, maxHeight: .infinity)
				.accessibilityHidden(true)
				.probeFrame("guideDrawing")
			VStack(alignment: .leading, spacing: 4) {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text(verbatim: step.mark).font(.headline).foregroundStyle(Theme.accentText)
					Text(step.title).font(.headline)
					Spacer(minLength: 0)
				}
				.frame(height: 17, alignment: .leading)
				Text(step.text)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.lineLimit(4)
					.frame(maxWidth: .infinity, minHeight: Self.textHeight, maxHeight: Self.textHeight, alignment: .topLeading)
					// The height the sentence wants at this width, for the layout probe: the fixed frame above cuts a
					// longer text with an ellipsis instead of overlapping anything, so only this shows a step whose
					// words no longer fit (like the Settings window's two hidden `fixedSize` copies).
					.background(alignment: .topLeading) {
						Text(step.text)
							.font(.callout)
							.fixedSize(horizontal: false, vertical: true)
							.hidden()
							.probeFrame("guideTextIdeal")
					}
			}
			// VoiceOver reads a step as one element: its number, its title and its sentence (the drawing is decoration).
			.accessibilityElement(children: .combine)
			.accessibilityLabel(Text(verbatim: "\(step.mark) \(step.title). \(step.text)"))
			.probeFrame("guideText")
			action
				.frame(height: Self.actionHeight, alignment: .leading)
				.probeFrame("guideAction")
			dots
			Divider()
			bottomRow
		}
		.padding(16)
		.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
		.background { shortcuts }
		.probeFrame("guideRoot")
		.sheetSurface()
	}

	private var header: some View {
		HStack(spacing: 10) {
			GradientTile(systemImage: "keyboard", size: 30)
			VStack(alignment: .leading, spacing: 1) {
				Text("단축키 설정 방법").font(.title3.bold()).accessibilityAddTraits(.isHeader)
				Text("macOS에서만 지정할 수 있어 이 앱은 설정을 바꾸지 않습니다")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 0)
		}
		.frame(height: 34)
		.probeFrame("guideHeader")
	}

	/// What the step carries: the button that opens System Settings (①) or the live state (⑥). The other steps keep the
	/// row empty, so nothing below it moves from one step to the next.
	@ViewBuilder private var action: some View {
		switch guide.step {
		case 0:
			Button("키보드 설정 열기…") { NSWorkspace.shared.open(LanguageSettingsView.keyboardSettings) }
				.help("시스템 설정의 키보드 설정을 엽니다. 이 앱은 거기서 아무것도 바꾸지 않습니다.")
				.accessibilityIdentifier("guideOpenKeyboard")
		case Self.steps.count - 1:
			shortcutLine(guide.shortcut, starred: starred)
				.accessibilityIdentifier("guideShortcutState")
		default:
			Color.clear.frame(height: 1)
		}
	}

	/// The line the Settings window also shows, so both say the same thing in the same words.
	private func shortcutLine(_ state: ServiceShortcutState, starred: Bool, font: Font = .callout) -> some View {
		Label(ShortcutStateText.line(state, starred: starred), systemImage: ShortcutStateText.symbol(state, starred: starred))
			.font(font)
			.lineLimit(1)
			.foregroundStyle(ShortcutStateText.isWarning(state, starred: starred) ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
			.help(ShortcutStateText.help(state, starred: starred))
	}

	/// Where the user is among the six steps: a dot for each, the current one in the accent color. Only a position —
	/// the dots are not buttons ("이전"·"다음" and ← → move). The row keeps the 20pt it had when it also held the play
	/// button of the walkthrough that advanced by itself, so the sheet kept its size; VoiceOver reads it as one element,
	/// "단계 3/6".
	private var dots: some View {
		HStack(spacing: 6) {
			ForEach(Self.steps) { one in
				Circle()
					.fill(one.id == guide.step ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.tertiary))
					.frame(width: 6, height: 6)
			}
			Spacer(minLength: 0)
		}
		.frame(height: 20)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(String(localized: "단계 \(guide.step + 1)/\(guide.stepCount)"))
		.probeFrame("guideDots")
	}

	private var bottomRow: some View {
		HStack(spacing: 8) {
			Button("이전") { guide.previous() }
				.disabled(guide.isFirst)
				.accessibilityIdentifier("guidePrevious")
			Button("다음") { guide.next() }
				.disabled(guide.isLast)
				.accessibilityIdentifier("guideNext")
			Spacer(minLength: 0)
			Button("닫기") { guide.close() }
				.keyboardShortcut(.defaultAction)
				.accessibilityIdentifier("guideClose")
		}
		.frame(height: 24)
		.probeFrame("guideBottom")
	}

	/// ← and → walk the steps and Esc closes the sheet (Return is the "닫기" button's own `.defaultAction`). Invisible
	/// buttons that only carry the shortcuts, like the preset editor's ⌘0–⌘4: a sheet without a `.cancelAction` does not
	/// close on Esc, and every other dialog of this app has one.
	private var shortcuts: some View {
		ZStack {
			Button(String(localized: "이전")) { guide.previous() }
				.keyboardShortcut(.leftArrow, modifiers: [])
				.disabled(guide.isFirst)
			Button(String(localized: "다음")) { guide.next() }
				.keyboardShortcut(.rightArrow, modifiers: [])
				.disabled(guide.isLast)
			Button(String(localized: "닫기")) { guide.close() }
				.keyboardShortcut(.cancelAction)
		}
		.opacity(0)
		.frame(width: 0, height: 0)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	// MARK: The drawings (shapes only)

	@ViewBuilder private var drawing: some View {
		switch guide.step {
		case 0: systemSettingsDrawing
		case 1: keyboardPaneDrawing
		case 2: shortcutListDrawing
		case 3: servicesDrawing(chosen: false)
		case 4: servicesDrawing(chosen: true)
		default: appSettingsDrawing
		}
	}

	/// ①: System Settings with its sidebar, "키보드" ringed.
	private var systemSettingsDrawing: some View {
		GuidePanel(title: String(localized: "시스템 설정")) {
			HStack(alignment: .top, spacing: 10) {
				VStack(alignment: .leading, spacing: 9) {
					GuideBar(width: 74)
					GuideBar(width: 58)
					GuideBar(width: 66)
					GuideChip(text: String(localized: "키보드"), systemImage: "keyboard", ringed: true)
					GuideBar(width: 52)
					Spacer(minLength: 0)
				}
				.frame(width: 118, alignment: .leading)
				Divider()
				VStack(alignment: .leading, spacing: 11) {
					ForEach([160, 130, 150, 110], id: \.self) { width in
						GuideBar(width: CGFloat(width))
					}
					Spacer(minLength: 0)
				}
				Spacer(minLength: 0)
			}
		}
	}

	/// ②: the keyboard pane, its "키보드 단축키…" button at the bottom ringed.
	private var keyboardPaneDrawing: some View {
		GuidePanel(title: String(localized: "키보드")) {
			VStack(alignment: .leading, spacing: 12) {
				ForEach([0, 1, 2], id: \.self) { row in
					HStack(spacing: 10) {
						GuideBar(width: [110, 96, 124][row])
						Spacer(minLength: 0)
						GuideBar(width: [44, 60, 38][row])
					}
				}
				Spacer(minLength: 0)
				HStack(spacing: 0) {
					Spacer(minLength: 0)
					GuideChip(text: String(localized: "키보드 단축키…"), ringed: true)
				}
			}
		}
	}

	/// ③: the keyboard-shortcuts window, "서비스" in its left list ringed.
	private var shortcutListDrawing: some View {
		GuidePanel(title: String(localized: "키보드 단축키")) {
			HStack(alignment: .top, spacing: 10) {
				VStack(alignment: .leading, spacing: 9) {
					GuideBar(width: 84)
					GuideBar(width: 66)
					GuideBar(width: 78)
					GuideChip(text: String(localized: "서비스"), ringed: true)
					Spacer(minLength: 0)
				}
				.frame(width: 118, alignment: .leading)
				Divider()
				VStack(alignment: .leading, spacing: 11) {
					ForEach([150, 128, 142], id: \.self) { width in
						GuideBar(width: CGFloat(width))
					}
					Spacer(minLength: 0)
				}
				Spacer(minLength: 0)
			}
		}
	}

	/// ④ and ⑤: the services list with its search field and the "일반" group. `chosen` false is ④: the ring is around the
	/// check box of our service, which is drawn the way a fresh Mac has it — already on (the step says to look at it, not
	/// to switch it). True is ⑤: the ring is around the shortcut field of that row, which now holds the combination the
	/// step suggests, the way macOS fills the field once it has been pressed. Both draw the same three rows in the same
	/// places, so nothing jumps between the two steps.
	private func servicesDrawing(chosen: Bool) -> some View {
		GuidePanel(title: String(localized: "서비스")) {
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 5) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 8))
						.foregroundStyle(.secondary)
					GuideBar(width: 60)
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 6)
				.frame(height: 18)
				.background(Theme.well, in: Capsule())
				.overlay(Capsule().strokeBorder(Theme.cardStroke(contrast)))
				Text("일반").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 7) {
					serviceRow(bar: 130)
					serviceRow(title: FinderService.quickApply.localizedTitle, checked: true, ringCheck: !chosen,
					           shortcut: chosen ? "⌃⌥⌘P" : nil, ringShortcut: chosen)
					serviceRow(bar: 104)
				}
				Spacer(minLength: 0)
			}
		}
	}

	/// One row of the services list: a check box, a name (a placeholder bar for the other services) and the shortcut
	/// field, empty ("없음") or with the combination in it. `ringCheck` / `ringShortcut`: which of the two the step is
	/// about. The row keeps its fixed height whatever it holds, so the list stands still from ④ to ⑤.
	private func serviceRow(title: String? = nil, bar: CGFloat = 120, checked: Bool = false, ringCheck: Bool = false,
	                        shortcut: String? = nil, ringShortcut: Bool = false) -> some View {
		HStack(spacing: 7) {
			GuideCheck(on: checked)
				.guideHighlight(ringCheck, radius: 4)
			if let title {
				Text(title).font(.caption).lineLimit(1).truncationMode(.tail)
			} else {
				GuideBar(width: bar)
			}
			Spacer(minLength: 6)
			Group {
				if let shortcut {
					Text(verbatim: shortcut).font(.caption.weight(.semibold)).foregroundStyle(Theme.accentText)
				} else {
					Text("없음").font(.caption).foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 5)
			.padding(.vertical, 1)
			.background(Theme.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
			.guideHighlight(ringShortcut, radius: 4)
		}
		.frame(height: 18)
	}

	/// ⑥: this app's Settings window with the line that says what macOS now has. The "빠른 적용:" row draws a name only
	/// when a preset really carries the star; without one it says so, like the window itself, so the drawing never
	/// suggests that half of the setup is done.
	private var appSettingsDrawing: some View {
		GuidePanel(title: String(localized: "설정")) {
			VStack(alignment: .leading, spacing: 10) {
				GuideBar(width: 150)
				GuideBar(width: 120)
				Divider()
				HStack(spacing: 6) {
					Text("빠른 적용:").font(.caption).foregroundStyle(.secondary)
					if starred {
						GuideBar(width: 74)
					} else {
						Text("없음").font(.caption).foregroundStyle(.secondary)
					}
					Spacer(minLength: 0)
				}
				.guideHighlight(!starred, radius: 5)
				shortcutLine(guide.shortcut, starred: starred, font: .caption)
					.padding(.horizontal, 5)
					.padding(.vertical, 2)
					.guideHighlight(starred, radius: 5)
				Spacer(minLength: 0)
			}
		}
	}
}

// MARK: Pieces of the drawings

/// A drawing that stands for a window or pane: a card with a title bar of three dots and a title, and what the step puts
/// in it. Shapes only, no bitmap and no screenshot of System Settings.
private struct GuidePanel<Content: View>: View {
	let title: String
	@ViewBuilder var content: Content
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 4) {
				ForEach(0..<3, id: \.self) { _ in
					Circle().fill(Theme.grip).frame(width: 6, height: 6)
				}
				Text(title)
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.padding(.leading, 4)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8)
			.frame(height: 20)
			Divider()
			content
				// What the step's drawing really takes, not the box it was given: a step whose drawing grows past the
				// card would otherwise cross its bottom stroke and nothing would notice (the layout probe compares this
				// with the drawing's own frame).
				.probeFrame("guideDrawingContent")
				.padding(10)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		.background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke(contrast)))
	}
}

/// A grey bar that stands for a text the step is not about.
private struct GuideBar: View {
	var width: CGFloat
	var height: CGFloat = 7

	var body: some View {
		Capsule().fill(Theme.grip.opacity(0.55)).frame(width: width, height: height)
	}
}

/// A named row of a list, or a small button: what the step is about carries its own words.
private struct GuideChip: View {
	let text: String
	var systemImage: String?
	var ringed = false
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		HStack(spacing: 4) {
			if let systemImage {
				Image(systemName: systemImage).font(.system(size: 9))
			}
			Text(text).font(.caption).lineLimit(1)
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
		.background(Theme.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.cardStroke(contrast)))
		.guideHighlight(ringed, radius: 5)
	}
}

/// A check box of the services list.
private struct GuideCheck: View {
	let on: Bool

	var body: some View {
		RoundedRectangle(cornerRadius: 3, style: .continuous)
			.fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.well))
			.overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.grip))
			.overlay {
				if on {
					Image(systemName: "checkmark")
						.font(.system(size: 7, weight: .bold))
						.foregroundStyle(.white)
				}
			}
			.frame(width: 12, height: 12)
	}
}

private extension View {
	/// The ring around what to click. It pulses gently so the eye finds it, and stands still when "동작 줄이기" is on.
	/// Only the ring moves: the step itself never changes by itself.
	func guideHighlight(_ active: Bool = true, radius: CGFloat = 6) -> some View {
		modifier(GuideHighlight(active: active, radius: radius))
	}
}

private struct GuideHighlight: ViewModifier {
	let active: Bool
	let radius: CGFloat
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var pulsing = false

	func body(content: Content) -> some View {
		content
			.padding(2)
			.overlay {
				if active {
					RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
						.strokeBorder(Theme.accentText, lineWidth: 2)
						.opacity(reduceMotion || pulsing ? 1 : 0.35)
						.animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
						.onAppear { if !reduceMotion { pulsing = true } }
						.accessibilityHidden(true)
				}
			}
	}
}

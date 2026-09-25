import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderPresetsCore

/// The preset editor's live preview: a small window beside the main window, open while the editor is ("편집…", "새
/// 프리셋…") and following the sheet's draft (`PresetPreview` works out what to draw).
///
/// - **Window**: an `NSPanel` that can never become the key or the main window (`PreviewPanel`), so the editor sheet keeps
///   the keyboard: typing in the name field, Esc, Return and ⌘0–⌘4 keep going to the sheet while the preview shows, and a
///   click on the preview changes nothing. `.nonactivatingPanel` also keeps a click from activating the app when it is
///   in the background. It moves with the main window and hides while it is minimized; like the main window it stays on
///   screen while another app is in front; not a child window (the sheet's dimming of the main window would cover it
///   too). Fixed size (no resize, zoom or full screen, no tabs), not restorable, not in the Window menu, skipped by ⌘`.
/// - **Place**: to the right of the main window when it fits on that screen's visible frame, else to its left. When
///   neither side has room but the screen is wide enough for both (a centred window on a 1440pt screen), the main
///   window slides aside just enough (`roomMaking`) and slides back when the preview goes, unless the user moved it
///   meanwhile. Only on a screen too narrow for both does the preview overlap the main window (`placement`), and then it
///   is ordered below the editor sheet, so it never covers the sheet's controls. Top edges aligned.
/// - **Open/close**: opened when the model's editor draft appears and closed when it goes (save, cancel, Esc — MainView),
///   or with the app. The eye button of the sheet hides and shows it; the choice is remembered in the app's defaults
///   (`shownKey`, shown by default). The title bar's close button hides it the same way.
@MainActor @Observable
final class PresetPreviewController {
	static let shared = PresetPreviewController()

	/// The app's defaults key of the eye button (true or missing: shown).
	static let shownKey = "presetPreviewShown"
	/// Content below the title bar: header, hairline, content, hairline, footer.
	static let headerHeight: CGFloat = 34
	static let footerHeight: CGFloat = 22
	static var contentSize: CGSize {
		CGSize(width: PresetPreview.contentSize.width, height: headerHeight + 1 + PresetPreview.contentSize.height + 1 + footerHeight)
	}
	/// Space between the main window and the preview.
	nonisolated static let gap: CGFloat = 8

	/// The draft being followed (nil while no editor is open).
	private(set) var tracker: PreviewTracker?
	private(set) var token: UUID?
	/// Finder's defaults ("유지") and the time the samples are dated from, fixed while the editor is open.
	private(set) var defaults = PreviewDefaults.factory
	private(set) var now = Date()
	private(set) var shown: Bool

	@ObservationIgnored private var panel: PreviewPanel?
	@ObservationIgnored private var closeDelegate: CloseDelegate?
	@ObservationIgnored private weak var followed: NSWindow?
	@ObservationIgnored private var mainObservers: [NSObjectProtocol] = []
	/// The main window slid aside for the preview: where it was and where it went (put back if it is still there).
	@ObservationIgnored private var slid: (from: CGRect, to: CGRect)?
	/// While the main window slides, its moves do not re-place the preview (it is already at its final place).
	@ObservationIgnored private var sliding = false
	/// The latest slide (an earlier one's end changes nothing).
	@ObservationIgnored private var slideCount = 0
	@ObservationIgnored private var quitObserver: NSObjectProtocol?

	init() {
		shown = (UserDefaults.standard.object(forKey: Self.shownKey) as? Bool) ?? true
	}

	/// The editor opened with `draft`: the preview follows it from now on, and shows unless hidden.
	func begin(_ draft: PresetDraft, globals: GlobalDefaults) {
		token = draft.token
		tracker = PreviewTracker(draft)
		defaults = PreviewDefaults(globals, foldersFirst: Self.readFoldersFirst())
		now = Date()
		updateWindow()
	}

	/// The sheet's draft changed (every click, slider step, typed character). A sheet still closing (another token)
	/// is ignored.
	func follow(_ draft: PresetDraft) {
		guard draft.token == token, var t = tracker else { return }
		t.follow(draft)
		if t != tracker { tracker = t }
		panel?.title = title
	}

	/// The editor closed.
	func end() {
		token = nil
		tracker = nil
		updateWindow()
	}

	/// The eye button (and the title bar's close button): hides or shows the preview and remembers it.
	func setShown(_ on: Bool) {
		shown = on
		UserDefaults.standard.set(on, forKey: Self.shownKey)
		updateWindow()
	}

	var isEditing: Bool { tracker != nil }
	/// The window on screen (for the layout probe and the self-test).
	var window: NSPanel? { panel }
	var isVisible: Bool { panel?.isVisible == true }

	var title: String {
		let name = tracker?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return name.isEmpty ? String(localized: "미리보기") : String(localized: "미리보기 · \(name)")
	}

	/// What the window draws now.
	func preview(measure: (String, Double) -> Double = PreviewText.estimate) -> PresetPreview? {
		guard let tracker else { return nil }
		return PresetPreview.make(settings: tracker.settings, defaults: defaults, locale: AppLanguage.locale, now: now, measure: measure)
	}

	/// Finder's "Keep folders on top: In windows when sorting by name" (read only; Finder's defaults may hold it as a
	/// number or a string).
	nonisolated static func readFoldersFirst() -> Bool {
		guard let value = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "_FXSortFoldersFirst") else { return false }
		if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
		return (value as? NSNumber)?.boolValue ?? false
	}

	private func updateWindow() {
		guard isEditing, shown, let main = FinderServiceProvider.shared.mainWindow, main.isVisible, !main.isMiniaturized else {
			if let panel, panel.isVisible { panel.orderOut(nil) }
			if let main = followed ?? FinderServiceProvider.shared.mainWindow { slideBack(main) }
			follow(mainWindow: nil)
			return
		}
		let panel = self.panel ?? makePanel()
		panel.title = title
		makeRoom(beside: main, panel: panel)
		place(panel, beside: main)
		order(panel, main: main)
		follow(mainWindow: main)
	}

	private func panelSize(_ panel: NSPanel) -> CGSize {
		panel.frameRect(forContentRect: CGRect(origin: .zero, size: Self.contentSize)).size
	}

	private func visibleFrame(_ main: NSWindow) -> CGRect {
		(main.screen ?? NSScreen.main)?.visibleFrame ?? main.frame
	}

	/// The main window's frame `slid` expects (the one it slides to, while sliding).
	private func mainFrame(_ main: NSWindow) -> CGRect { sliding ? (slid?.to ?? main.frame) : main.frame }

	private func place(_ panel: NSPanel, beside main: NSWindow) {
		let frame = Self.placement(panel: panelSize(panel), main: mainFrame(main), visible: visibleFrame(main))
		if panel.frame != frame { panel.setFrame(frame, display: false) }
	}

	/// Not a child window (a child of the main window would be dimmed with it while the editor sheet is up): ordered
	/// just below the editor sheet while there is one (so even an overlapping preview never covers the sheet), else just
	/// above the main window.
	private func order(_ panel: NSPanel, main: NSWindow) {
		guard panel.isVisible || (isEditing && shown) else { return }
		if let sheet = main.attachedSheet {
			panel.order(.below, relativeTo: sheet.windowNumber)
		} else {
			panel.order(.above, relativeTo: main.windowNumber)
		}
	}

	/// Neither side of the main window has room but its screen fits both: slide the main window (with its sheet) the
	/// least distance that makes room, towards the side with more space (the right when equal). Once per showing.
	private func makeRoom(beside main: NSWindow, panel: NSPanel) {
		guard slid == nil else { return }
		let visible = visibleFrame(main)
		guard let target = Self.roomMaking(panel: panelSize(panel), main: main.frame, visible: visible) else { return }
		slid = (main.frame, target)
		slide(main, to: target)
		watchQuit(main)
	}

	/// The main window goes back where it was before `makeRoom`, unless the user moved it since (then it stays).
	private func slideBack(_ main: NSWindow) {
		guard let slid else { return }
		let current = mainFrame(main)
		self.slid = nil
		guard current.origin == slid.to.origin, main.isVisible, !main.isMiniaturized else { return }
		slide(main, to: slid.from)
	}

	private func slide(_ main: NSWindow, to frame: CGRect) {
		slideCount += 1
		let count = slideCount
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
			sliding = false
			main.setFrame(frame, display: true)
			return
		}
		sliding = true
		NSAnimationContext.runAnimationGroup({ context in
			context.duration = 0.2
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			main.animator().setFrame(frame, display: true)
		}, completionHandler: { [weak self] in
			MainActor.assumeIsolated {
				guard let self, count == self.slideCount else { return }
				self.sliding = false
				if main.frame != frame { main.setFrame(frame, display: true) }
				if let panel = self.panel, panel.isVisible { self.place(panel, beside: main); self.order(panel, main: main) }
			}
		})
	}

	/// Quitting while the main window is slid aside: it goes back first (its remembered frame is the user's own).
	private func watchQuit(_ main: NSWindow) {
		guard quitObserver == nil else { return }
		quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self, weak main] _ in
			MainActor.assumeIsolated {
				guard let self, let main, let slid = self.slid else { return }
				self.slid = nil
				if main.frame.origin == slid.to.origin { main.setFrame(slid.from, display: false) }
			}
		}
	}

	/// While the preview shows, it moves with the main window and hides while that is minimized.
	private func follow(mainWindow main: NSWindow?) {
		guard main !== followed else { return }
		mainObservers.forEach { NotificationCenter.default.removeObserver($0) }
		mainObservers = []
		followed = main
		guard let main else { return }
		for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
			mainObservers.append(NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, !self.sliding, let panel = self.panel, panel.isVisible else { return }
					self.place(panel, beside: main)
				}
			})
		}
		// The sheet attaches after the editor opened (and activating the app brings the main window forward): order the
		// preview again once it is there, so an overlapping preview stays below the sheet.
		for name in [NSWindow.willBeginSheetNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
			mainObservers.append(NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.reorderSoon() }
			})
		}
		mainObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
			let window = note.object.map { ObjectIdentifier($0 as AnyObject) }
			MainActor.assumeIsolated {
				guard let self, let window, let sheet = self.followed?.attachedSheet, window == ObjectIdentifier(sheet) else { return }
				self.reorderSoon()
			}
		})
		for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
			let closing = name == NSWindow.willCloseNotification
			mainObservers.append(NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self else { return }
					if closing { self.panel?.orderOut(nil); self.follow(mainWindow: nil) } else { self.updateWindow() }
				}
			})
		}
	}

	/// Orders the preview again on the next turn of the run loop (after AppKit has finished attaching or ordering).
	private func reorderSoon() {
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				guard let self, let main = self.followed, let panel = self.panel, panel.isVisible else { return }
				self.order(panel, main: main)
			}
		}
	}

	/// Where the main window slides so the preview fits beside it, or nil when it needs not (a side has room) or cannot
	/// (the screen is narrower than both with the gap). The least move: to the side with more space, the right when
	/// equal; only horizontally.
	nonisolated static func roomMaking(panel: CGSize, main: CGRect, visible: CGRect) -> CGRect? {
		let right = main.maxX + gap + panel.width <= visible.maxX
		let left = main.minX - gap - panel.width >= visible.minX
		guard !right, !left, main.width + gap + panel.width <= visible.width else { return nil }
		// Preview right: the main window's right edge at visible.maxX - panel - gap; left: its left edge after them.
		let toRight = (visible.maxX - panel.width - gap - main.width).rounded(.down)
		let toLeft = (visible.minX + panel.width + gap).rounded(.up)
		let x = abs(main.minX - toRight) <= abs(toLeft - main.minX) ? toRight : toLeft
		return CGRect(x: x, y: main.minY, width: main.width, height: main.height)
	}

	/// Right of the main window if it fits on the screen's visible frame, else left of it, else (a screen narrower than
	/// both) over it with an offset, inside the visible frame; the top edges aligned.
	nonisolated static func placement(panel: CGSize, main: CGRect, visible: CGRect) -> CGRect {
		let y = min(max(main.maxY - panel.height, visible.minY), visible.maxY - panel.height)
		if main.maxX + gap + panel.width <= visible.maxX { return CGRect(x: main.maxX + gap, y: y, width: panel.width, height: panel.height) }
		if main.minX - gap - panel.width >= visible.minX { return CGRect(x: main.minX - gap - panel.width, y: y, width: panel.width, height: panel.height) }
		let x = min(max(main.maxX - panel.width + 40, visible.minX), visible.maxX - panel.width)
		let offsetY = min(max(main.maxY - panel.height - 40, visible.minY), visible.maxY - panel.height)
		return CGRect(x: x, y: offsetY, width: panel.width, height: panel.height)
	}

	private func makePanel() -> PreviewPanel {
		let panel = PreviewPanel(contentRect: CGRect(origin: .zero, size: Self.contentSize),
		                         styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isReleasedWhenClosed = false
		panel.isRestorable = false
		// Stays on screen with the main window and its sheet while another app is in front (like them).
		panel.hidesOnDeactivate = false
		// A normal-level window (a utility panel would float above other apps' windows), ordered above the main window.
		panel.isFloatingPanel = false
		panel.level = .normal
		panel.becomesKeyOnlyIfNeeded = true
		panel.isExcludedFromWindowsMenu = true
		panel.tabbingMode = .disallowed
		panel.collectionBehavior = [.fullScreenNone, .ignoresCycle, .managed]
		panel.contentMinSize = Self.contentSize
		panel.contentMaxSize = Self.contentSize
		panel.animationBehavior = .utilityWindow
		let delegate = CloseDelegate { [weak self] in self?.setShown(false) }
		panel.delegate = delegate
		closeDelegate = delegate
		let host = NSHostingView(rootView: PresetPreviewView(controller: self))
		host.sizingOptions = []
		host.frame = CGRect(origin: .zero, size: Self.contentSize)
		panel.contentView = host
		panel.setAccessibilityIdentifier("presetPreviewWindow")
		self.panel = panel
		return panel
	}

	/// The title bar's close button hides the preview (like the eye button) instead of closing it.
	@MainActor private final class CloseDelegate: NSObject, NSWindowDelegate {
		let hide: @MainActor () -> Void
		init(hide: @escaping @MainActor () -> Void) { self.hide = hide }
		func windowShouldClose(_ sender: NSWindow) -> Bool {
			hide()
			return false
		}
	}
}

/// A panel that never takes the keyboard (see `PresetPreviewController`).
final class PreviewPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

// MARK: Icons

/// The system's icons for the sample types, one copy per drawn size (a shared icon drawn larger than its size is blurry).
@MainActor
enum PreviewIcons {
	private static var cache: [String: NSImage] = [:]

	static func image(_ type: PreviewFileType, side: Double) -> NSImage {
		let points = max(8, Int(side.rounded(.up)))
		let key = "\(type.rawValue)-\(points)"
		if let image = cache[key] { return image }
		if cache.count > 400 { cache.removeAll() }   // a slider dragged over every size
		let base = UTType(type.typeIdentifier).map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data)
		let image = (base.copy() as? NSImage) ?? base
		image.size = NSSize(width: points, height: points)
		cache[key] = image
		return image
	}

	/// AppKit's width of a text in the system font (the preview's text measurement).
	static func measure(_ text: String, _ size: Double) -> Double {
		(text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
	}
}

// MARK: The window's content

struct PresetPreviewView: View {
	let controller: PresetPreviewController
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		let preview = controller.preview(measure: PreviewIcons.measure)
		VStack(spacing: 0) {
			if let preview {
				header(preview)
					.frame(height: PresetPreviewController.headerHeight)
					.probeFrame("previewHeader")
				Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
				PreviewContent(preview: preview)
					.frame(width: PresetPreview.contentSize.width, height: PresetPreview.contentSize.height, alignment: .topLeading)
					.background(Theme.well)
					.clipped()
					.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: preview.content)
					.probeFrame("previewContent")
				Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
				footer(preview)
					.frame(height: PresetPreviewController.footerHeight)
					.probeFrame("previewFooter")
			} else {
				Color.clear
			}
		}
		.frame(width: PresetPreviewController.contentSize.width, height: PresetPreviewController.contentSize.height, alignment: .top)
		.background(Theme.canvas)
		// One element for the whole window: a picture with a one-line summary, not the sample items one by one.
		.accessibilityElement(children: .ignore)
		.accessibilityAddTraits(.isImage)
		.accessibilityLabel(String(localized: "미리보기"))
		.accessibilityValue(preview?.summary ?? "")
		.accessibilityIdentifier("presetPreview")
		#if DEBUG
		.onChange(of: preview, initial: true) { if LayoutProbe.isRequested || SelfTest.isRequested { LayoutProbe.previewModel = preview } }
		#endif
	}

	/// The sample folder's name and Finder's four view symbols, the drawn view selected (display only).
	private func header(_ preview: PresetPreview) -> some View {
		HStack(spacing: 8) {
			Image(nsImage: PreviewIcons.image(.folder, side: 16))
				.resizable()
				.frame(width: 16, height: 16)
			Text(String(localized: "예시 폴더"))
				.font(.system(size: 13, weight: .semibold))
				.lineLimit(1)
				.fixedSize()
			// How much is drawn: "8개 중 6개", "실제 크기의 75%" (never over the content).
			HStack(spacing: 4) {
				ForEach([preview.countBadge, preview.scaleBadge].compactMap { $0 }, id: \.self) { text in
					Text(text)
						.font(.system(size: 10, weight: .medium).monospacedDigit())
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.fixedSize()
						.padding(.horizontal, 6)
						.padding(.vertical, 1)
						.background(Capsule().fill(Theme.well))
						.overlay(Capsule().strokeBorder(Theme.hairline(contrast)))
				}
			}
			.probeFrame("previewBadges")
			Spacer(minLength: 8)
			if preview.viewKept {
				Text(Fmt.keep)
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.secondary)
					.padding(.horizontal, 6)
					.padding(.vertical, 1)
					.overlay(Capsule().strokeBorder(Theme.hairline(contrast), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
					.help(String(localized: "보기 방식 유지: Finder 기본 보기로 그렸습니다."))
			}
			HStack(spacing: 2) {
				ForEach(ViewStyle.allCases, id: \.self) { view in
					Image(systemName: ViewSwitcher.symbol(view))
						.font(.system(size: 11, weight: .medium))
						.frame(width: 28, height: 20)
						.foregroundStyle(view == preview.view ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
						.background {
							if view == preview.view {
								RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.hairline(contrast))
							}
						}
				}
			}
			.padding(2)
			.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well.opacity(0.6)))
			.overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline(contrast)))
		}
		.padding(.horizontal, 12)
	}

	private func footer(_ preview: PresetPreview) -> some View {
		HStack(spacing: 8) {
			Text(preview.footerLeading)
				.lineLimit(1)
				.truncationMode(.tail)
				.layoutPriority(0)
			Spacer(minLength: 8)
			Label {
				Text(preview.footerTrailing).lineLimit(1)
			} icon: {
				Image(systemName: "info.circle")
			}
			.labelStyle(.titleAndIcon)
			.fixedSize()
			.layoutPriority(1)
		}
		.font(.system(size: 11))
		.foregroundStyle(.secondary)
		.padding(.horizontal, 12)
		.frame(maxWidth: .infinity)
		.contentShape(Rectangle())
		.help(preview.details.joined(separator: "\n"))
	}
}

/// The preview's whole picture, smaller: the same drawing, scaled down as one, in a window-like box. The history sheet
/// draws a recorded operation's preset with it, where there is no room for the window's 520×392.
struct PreviewPicture: View {
	/// How much of the drawn size is shown — as much as the history sheet's pane holds beside a folder list (281×212),
	/// because everything in the picture, its icon labels and its list rows included, shrinks with it.
	static let scale = 0.54
	static let size = CGSize(width: (PresetPreview.contentSize.width * scale).rounded(),
	                         height: (PresetPreview.contentSize.height * scale).rounded())

	let preview: PresetPreview
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		PreviewContent(preview: preview)
			.frame(width: PresetPreview.contentSize.width, height: PresetPreview.contentSize.height, alignment: .topLeading)
			.scaleEffect(Self.scale, anchor: .topLeading)
			.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
			.background(Theme.well)
			.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline(contrast)))
	}
}

/// The content area of one view, drawn from the model's positions (in the area's coordinates).
struct PreviewContent: View {
	let preview: PresetPreview

	var body: some View {
		ZStack(alignment: .topLeading) {
			switch preview.content {
			case .icon(let grid): IconGridView(grid: grid).transition(.opacity)
			case .list(let table): ListTableView(table: table).transition(.opacity)
			case .column(let browser): ColumnBrowserView(browser: browser).transition(.opacity)
			case .gallery(let gallery): GalleryView(gallery: gallery).transition(.opacity)
			}
		}
		.id(preview.view)
	}
}

/// Finder's blue of the item info line.
private let infoBlue = Color(light: 0x0A64D8, dark: 0x5AA8FF)
private let tagColors: [PreviewTag: Color] = [.red: Color(hex: 0xF2514F), .blue: Color(hex: 0x3B8CF5)]

/// A sample's picture: its drawn preview (images, movies, documents) while previews are on, else the system icon.
private struct SampleIcon: View {
	let item: PresetPreview.Item
	let side: Double
	let preview: Bool

	var body: some View {
		if preview, let thumbnail = item.thumbnail {
			ThumbnailView(kind: thumbnail, side: side)
		} else {
			Image(nsImage: PreviewIcons.image(item.type, side: side))
				.resizable()
				.interpolation(.high)
				.frame(width: side, height: side)
		}
	}
}

/// The name with a colored dot per tag, joined by a no-break space (as the model measures it, `PresetPreview.labelText`).
private func labelText(_ item: PresetPreview.Item) -> Text {
	var text = Text(item.name)
	for tag in item.tags { text = text + Text(PresetPreview.tagMark).foregroundStyle(tagColors[tag] ?? .gray) }
	return text
}

/// A "⋯" line: rows or groups skipped in the order before the next one.
private struct GapMark: View {
	let frame: CGRect
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		HStack(spacing: 6) {
			Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
			Text(verbatim: "⋯").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
			Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
		}
		.frame(width: frame.width, height: frame.height)
		.offset(x: frame.minX, y: frame.minY)
	}
}

private struct IconGridView: View {
	let grid: PresetPreview.IconGrid
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		ZStack(alignment: .topLeading) {
			ForEach(Array(grid.gaps.enumerated()), id: \.offset) { _, frame in GapMark(frame: frame) }
			ForEach(grid.headers) { header in
				VStack(alignment: .leading, spacing: 0) {
					HStack(spacing: 6) {
						Text(header.title)
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(.primary)
							.lineLimit(1)
						Spacer(minLength: 0)
						// The row scrolls sideways in Finder: how many of the group it does not show.
						if header.hidden > 0 {
							Text(String(localized: "\(header.hidden)개 더"))
								.font(.system(size: 11).monospacedDigit())
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
					Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
				}
				.frame(width: header.frame.width, height: header.frame.height)
				.offset(x: header.frame.minX, y: header.frame.minY)
			}
			ForEach(grid.cells) { cell in
				item(cell)
					.frame(width: cell.frame.width, height: cell.frame.height, alignment: .topLeading)
					.offset(x: cell.frame.minX, y: cell.frame.minY)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private func item(_ cell: PresetPreview.IconCell) -> some View {
		let origin = cell.frame.origin
		return ZStack(alignment: .topLeading) {
			SampleIcon(item: cell.item, side: grid.iconSide, preview: grid.showPreview)
				.frame(width: cell.icon.width, height: cell.icon.height)
				.offset(x: cell.icon.minX - origin.x, y: cell.icon.minY - origin.y)
			labelText(cell.item)
				.font(.system(size: grid.textSize))
				.foregroundStyle(.primary)
				.multilineTextAlignment(grid.labelOnBottom ? .center : .leading)
				.lineLimit(cell.labelLines)
				.truncationMode(.middle)
				// Wrapped exactly where the model measured it (`PresetPreview.labelInset` on each side).
				.frame(width: cell.label.width - 2 * PresetPreview.labelInset, height: cell.label.height, alignment: grid.labelOnBottom ? .top : .leading)
				.offset(x: cell.label.minX - origin.x + PresetPreview.labelInset, y: cell.label.minY - origin.y)
			if let info = cell.info, let text = cell.item.info {
				Text(text)
					.font(.system(size: grid.textSize))
					.foregroundStyle(infoBlue)
					.lineLimit(1)
					.frame(width: info.width, height: info.height, alignment: grid.labelOnBottom ? .top : .leading)
					.offset(x: info.minX - origin.x, y: info.minY - origin.y)
			}
		}
	}
}

private struct ListTableView: View {
	let table: PresetPreview.ListTable
	@Environment(\.colorSchemeContrast) private var contrast
	private static let stripe = Color(nsColor: NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : .clear)

	var body: some View {
		ZStack(alignment: .topLeading) {
			ForEach(Array(table.gaps.enumerated()), id: \.offset) { _, frame in GapMark(frame: frame.insetBy(dx: 12, dy: 0)) }
			ForEach(table.rows) { row in
				rowView(row)
					.frame(width: PresetPreview.contentSize.width, height: table.rowHeight, alignment: .topLeading)
					.background(row.stripe ? Self.stripe : Color.clear)
					.offset(y: row.y)
			}
			ForEach(table.headers) { header in
				VStack(alignment: .leading, spacing: 0) {
					Text(header.title)
						.font(.system(size: 12, weight: .semibold))
						.lineLimit(1)
						.padding(.leading, 10)
						.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
					Rectangle().fill(Theme.hairline(contrast)).frame(height: 1)
				}
				.frame(width: header.frame.width, height: header.frame.height)
				.background(Theme.well)
				.offset(y: header.frame.minY)
			}
			headerRow
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private var headerRow: some View {
		ZStack(alignment: .topLeading) {
			ForEach(table.columns) { column in
				HStack(spacing: 3) {
					if column.trailing { Spacer(minLength: 0) }
					Text(column.title)
						.font(.system(size: 11, weight: column.ascending == nil ? .regular : .semibold))
						.lineLimit(1)
					if let ascending = column.ascending {
						Image(systemName: ascending ? "chevron.up" : "chevron.down")
							.font(.system(size: 8, weight: .bold))
					}
					if !column.trailing { Spacer(minLength: 0) }
				}
				.foregroundStyle(column.ascending == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
				.padding(.horizontal, 8)
				.frame(width: column.width, height: table.headerHeight)
				.overlay(alignment: .trailing) {
					if column.id != table.columns.last?.id { Rectangle().fill(Theme.hairline(contrast)).frame(width: 1, height: 12) }
				}
				.offset(x: column.x)
			}
		}
		.frame(width: PresetPreview.contentSize.width, height: table.headerHeight, alignment: .topLeading)
		.background(Theme.well)
		.overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline(contrast)).frame(height: 1) }
	}

	private func rowView(_ row: PresetPreview.ListRow) -> some View {
		ZStack(alignment: .topLeading) {
			ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
				Group {
					if column.id == .name {
						HStack(spacing: PresetPreview.listIconSpacing) {
							SampleIcon(item: row.item, side: table.iconSide, preview: table.showPreview)
								.frame(width: table.iconSide, height: table.iconSide)
							labelText(row.item)
								.lineLimit(1)
								.truncationMode(.middle)
						}
						// No spacer inside the stack: its spacing would take room the model gave the name.
						.frame(maxWidth: .infinity, alignment: .leading)
					} else {
						Text(row.cells[index])
							.lineLimit(1)
							.truncationMode(.tail)
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: column.trailing ? .trailing : .leading)
					}
				}
				.font(.system(size: table.textSize))
				.padding(.horizontal, PresetPreview.listPadding)
				.frame(width: column.width, height: table.rowHeight)
				.offset(x: column.x)
			}
		}
	}
}

private struct ColumnBrowserView: View {
	let browser: PresetPreview.ColumnBrowser
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		ZStack(alignment: .topLeading) {
			ForEach(Array(browser.panes.enumerated()), id: \.offset) { index, pane in
				ZStack(alignment: .topLeading) {
					ForEach(pane.rows) { row in
						rowView(row, active: index == browser.panes.count - 1)
							.frame(width: pane.width - 8, height: browser.rowHeight)
							.offset(x: 4, y: row.y)
					}
				}
				.frame(width: pane.width, height: PresetPreview.contentSize.height, alignment: .topLeading)
				.overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline(contrast)).frame(width: 1) }
				.offset(x: pane.x)
			}
			previewPane
				.frame(width: PresetPreview.contentSize.width - browser.previewX, height: PresetPreview.contentSize.height, alignment: .top)
				.offset(x: browser.previewX)
		}
	}

	@ViewBuilder private func rowView(_ row: PresetPreview.ColumnRow, active: Bool) -> some View {
		if let header = row.header {
			Text(header)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.padding(.leading, 6)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		} else if let item = row.item {
			HStack(spacing: 5) {
				SampleIcon(item: item, side: 16, preview: false)
				Text(item.name).lineLimit(1).truncationMode(.middle)
				Spacer(minLength: 0)
				if row.isFolder { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
			}
			.font(.system(size: 13))
			.foregroundStyle(row.selected && active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
			.padding(.horizontal, 6)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background {
				if row.selected {
					RoundedRectangle(cornerRadius: 5, style: .continuous)
						.fill(active ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
				}
			}
		}
	}

	private var previewPane: some View {
		VStack(spacing: 8) {
			ThumbnailView(kind: browser.preview.thumbnail ?? .beach, side: 132)
				.padding(.top, 24)
			Text(browser.preview.name)
				.font(.system(size: 12, weight: .semibold))
				.lineLimit(1)
			VStack(spacing: 2) {
				ForEach(browser.previewLines.filter { !$0.isEmpty }, id: \.self) { line in
					Text(line).lineLimit(1).truncationMode(.middle)
				}
			}
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 10)
	}
}

private struct GalleryView: View {
	let gallery: PresetPreview.Gallery

	var body: some View {
		VStack(spacing: 8) {
			ThumbnailView(kind: gallery.selected.thumbnail ?? .trip, side: 236)
				.padding(.top, 14)
			VStack(spacing: 1) {
				Text(gallery.selected.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
				Text(gallery.lines.filter { !$0.isEmpty }.joined(separator: " · "))
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 0)
			HStack(spacing: 8) {
				ForEach(gallery.strip) { item in
					SampleIcon(item: item, side: 44, preview: true)
						.frame(width: 50, height: 50)
						.background {
							if item.id == gallery.selected.id {
								RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2.5)
							}
						}
				}
			}
			.padding(.bottom, 14)
		}
		.frame(width: PresetPreview.contentSize.width, height: PresetPreview.contentSize.height)
		.overlay(alignment: .topLeading) {
			if let note = gallery.note {
				Label(note, systemImage: "info.circle")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(Capsule().fill(Theme.canvas.opacity(0.9)))
					.padding(8)
			}
		}
	}
}

// MARK: Drawn previews (no image files)

/// A picture drawn in code for an image, a movie or a document, fitted into a `side`×`side` square like Finder's icon
/// previews (images with a thin white border and a soft shadow, documents as a page).
struct ThumbnailView: View {
	let kind: PreviewThumbnail
	let side: Double

	var body: some View {
		let aspect = kind.aspect
		let width = aspect >= 1 ? side : side * aspect
		let height = aspect >= 1 ? side / aspect : side
		let border = max(1, side * 0.035)
		ZStack {
			switch kind {
			case .pdf, .text:
				page
					.frame(width: width, height: height)
					.shadow(color: .black.opacity(0.18), radius: max(0.5, side * 0.02), y: max(0.3, side * 0.01))
			default:
				picture
					.frame(width: width - 2 * border, height: height - 2 * border)
					.padding(border)
					.background(Color.white)
					.shadow(color: .black.opacity(0.22), radius: max(0.5, side * 0.025), y: max(0.3, side * 0.012))
			}
		}
		.frame(width: side, height: side)
	}

	@ViewBuilder private var picture: some View {
		switch kind {
		case .trip:
			Canvas { ctx, size in
				let w = size.width, h = size.height
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(hex: 0x4E9BE8), Color(hex: 0xCDE7FB)]),
				                                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.7)))
				ctx.fill(Path(ellipseIn: CGRect(x: w * 0.68, y: h * 0.14, width: w * 0.14, height: w * 0.14)), with: .color(Color(hex: 0xFFD66B)))
				var far = Path()
				far.move(to: CGPoint(x: 0, y: h * 0.72)); far.addLine(to: CGPoint(x: w * 0.3, y: h * 0.36)); far.addLine(to: CGPoint(x: w * 0.55, y: h * 0.62))
				far.addLine(to: CGPoint(x: w * 0.78, y: h * 0.42)); far.addLine(to: CGPoint(x: w, y: h * 0.66)); far.addLine(to: CGPoint(x: w, y: h)); far.addLine(to: CGPoint(x: 0, y: h))
				ctx.fill(far, with: .color(Color(hex: 0x7A97C2)))
				var near = Path()
				near.move(to: CGPoint(x: 0, y: h * 0.86)); near.addQuadCurve(to: CGPoint(x: w, y: h * 0.78), control: CGPoint(x: w * 0.5, y: h * 0.6))
				near.addLine(to: CGPoint(x: w, y: h)); near.addLine(to: CGPoint(x: 0, y: h))
				ctx.fill(near, with: .color(Color(hex: 0x3F7A5C)))
			}
		case .beach:
			Canvas { ctx, size in
				let w = size.width, h = size.height
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(hex: 0x86CBF3), Color(hex: 0xE9F7FF)]),
				                                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.5)))
				ctx.fill(Path(CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.22)), with: .linearGradient(Gradient(colors: [Color(hex: 0x1E7FC4), Color(hex: 0x49B3D9)]),
				                                                                                          startPoint: CGPoint(x: 0, y: h * 0.5), endPoint: CGPoint(x: 0, y: h * 0.72)))
				var sand = Path()
				sand.move(to: CGPoint(x: 0, y: h * 0.74)); sand.addQuadCurve(to: CGPoint(x: w, y: h * 0.7), control: CGPoint(x: w * 0.6, y: h * 0.64))
				sand.addLine(to: CGPoint(x: w, y: h)); sand.addLine(to: CGPoint(x: 0, y: h))
				ctx.fill(sand, with: .color(Color(hex: 0xF0D6A2)))
			}
		case .walk:
			Canvas { ctx, size in
				let w = size.width, h = size.height
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(hex: 0xDDEFD6), Color(hex: 0x9CCB8E)]),
				                                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
				for (x, y, r) in [(0.2, 0.3, 0.2), (0.78, 0.26, 0.22), (0.5, 0.18, 0.16)] {
					ctx.fill(Path(ellipseIn: CGRect(x: w * (x - r), y: h * y - w * r, width: w * r * 2, height: w * r * 2)), with: .color(Color(hex: 0x4A8A46)))
				}
				var path = Path()
				path.move(to: CGPoint(x: w * 0.44, y: h * 0.5)); path.addLine(to: CGPoint(x: w * 0.56, y: h * 0.5))
				path.addLine(to: CGPoint(x: w * 0.9, y: h)); path.addLine(to: CGPoint(x: w * 0.1, y: h))
				ctx.fill(path, with: .color(Color(hex: 0xCDAE7E)))
			}
		case .screenshot:
			Canvas { ctx, size in
				let w = size.width, h = size.height
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xEEF0F5)))
				ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.12)), with: .color(Color(hex: 0xDADDE5)))
				for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
					ctx.fill(Path(ellipseIn: CGRect(x: w * (0.03 + Double(i) * 0.045), y: h * 0.035, width: h * 0.05, height: h * 0.05)), with: .color(Color(hex: UInt32(c))))
				}
				ctx.fill(Path(CGRect(x: 0, y: h * 0.12, width: w * 0.24, height: h * 0.88)), with: .color(Color(hex: 0xE2E5EE)))
				for i in 0..<3 {
					ctx.fill(Path(roundedRect: CGRect(x: w * (0.3 + Double(i) * 0.23), y: h * 0.22, width: w * 0.2, height: h * 0.3), cornerRadius: w * 0.01),
					         with: .color(i == 1 ? Color(hex: 0x6C7BF0) : Color(hex: 0xC7CEDC)))
				}
				ctx.fill(Path(roundedRect: CGRect(x: w * 0.3, y: h * 0.6, width: w * 0.66, height: h * 0.06), cornerRadius: h * 0.03), with: .color(Color(hex: 0xC7CEDC)))
				ctx.fill(Path(roundedRect: CGRect(x: w * 0.3, y: h * 0.72, width: w * 0.45, height: h * 0.06), cornerRadius: h * 0.03), with: .color(Color(hex: 0xC7CEDC)))
			}
		case .movie:
			Canvas { ctx, size in
				let w = size.width, h = size.height
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x14161E)))
				let scene = CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h)
				ctx.fill(Path(scene), with: .linearGradient(Gradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0xE0785A)]),
				                                          startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
				ctx.fill(Path(ellipseIn: CGRect(x: scene.midX - h * 0.14, y: h * 0.42, width: h * 0.28, height: h * 0.28)), with: .color(Color(hex: 0xFFC56B)))
				ctx.fill(Path(CGRect(x: scene.minX, y: h * 0.72, width: scene.width, height: h * 0.28)), with: .color(Color(hex: 0x241B3A)))
				let hole = h / 9
				for i in 0..<5 {
					let y = hole * 0.6 + Double(i) * hole * 1.7
					for x in [w * 0.02, w * 0.94] {
						ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w * 0.04, height: hole), cornerRadius: hole * 0.2), with: .color(.white.opacity(0.85)))
					}
				}
			}
		case .pdf, .text:
			page
		}
	}

	private var page: some View {
		Canvas { ctx, size in
			let w = size.width, h = size.height
			let fold = w * 0.2
			var sheet = Path()
			sheet.move(to: .zero); sheet.addLine(to: CGPoint(x: w - fold, y: 0)); sheet.addLine(to: CGPoint(x: w, y: fold))
			sheet.addLine(to: CGPoint(x: w, y: h)); sheet.addLine(to: CGPoint(x: 0, y: h)); sheet.closeSubpath()
			ctx.fill(sheet, with: .color(.white))
			ctx.stroke(sheet, with: .color(Color(hex: 0xC9CCD6)), lineWidth: max(0.5, w * 0.01))
			var corner = Path()
			corner.move(to: CGPoint(x: w - fold, y: 0)); corner.addLine(to: CGPoint(x: w - fold, y: fold)); corner.addLine(to: CGPoint(x: w, y: fold)); corner.closeSubpath()
			ctx.fill(corner, with: .color(Color(hex: 0xE4E6EC)))
			let bar = max(0.8, h * 0.035)
			var y = h * 0.12
			if kind == .pdf {
				ctx.fill(Path(CGRect(x: w * 0.12, y: y, width: w * 0.5, height: bar * 1.8)), with: .color(Color(hex: 0xD2453D)))
				y += bar * 4
			}
			var i = 0
			while y < h * 0.9 {
				let length = [0.76, 0.7, 0.74, 0.5][i % 4]
				ctx.fill(Path(CGRect(x: w * 0.12, y: y, width: w * length, height: bar)), with: .color(Color(hex: kind == .pdf ? 0xB7BCC8 : 0x9AA0AE)))
				y += bar * 2.6
				i += 1
			}
		}
	}
}

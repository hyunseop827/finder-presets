import SwiftUI
import AppKit

// A fixed-size window: the content below the toolbar is always `UILayout.content`, and the user cannot resize it
// (no edge or corner drag, no zoom button, no full screen, no title-bar double-click zoom). Every area takes exactly
// the space given to it here (`section`), so nothing the content shows (summaries, warnings, long status text, folder
// counts, sheets) can push the window or another area. Only the two lists scroll, and only when their rows do not fit.

enum UILayout {
	/// Content below the toolbar (`.unifiedCompact`), fixed.
	static let content = CGSize(width: 720, height: 440)
	/// Window edge ↔ content, left and right.
	static let edge: CGFloat = 12
	/// Above and below the areas, and on both sides of the vertical divider.
	static let inset: CGFloat = 10
	/// Width of "1. 프리셋", padding included (258 inside).
	static let presetColumnWidth: CGFloat = 280
	/// Width of "2. 적용할 폴더", padding included (417 inside); 1pt divider in between.
	static var targetColumnWidth: CGFloat { content.width - presetColumnWidth - 1 }
	static let systemBarHeight: CGFloat = 36
	static let statusBarHeight: CGFloat = 22
	static let headerHeight: CGFloat = 20
	static let spacing: CGFloat = 6
	static let actionRowHeight: CGFloat = 22
	static let summaryHeight: CGFloat = 78
	static let wellRadius: CGFloat = 7
	static let thumbnail = CGSize(width: 48, height: 30)
	static let tag = CGSize(width: 136, height: 20)
	static let presetChipWidth: CGFloat = 136
	/// The two columns above the whole-system bar and the status bar (382).
	static var workbenchHeight: CGFloat { content.height - systemBarHeight - statusBarHeight }
	/// Inside a column, below and above its insets (362).
	static var sectionInnerHeight: CGFloat { workbenchHeight - inset * 2 }
	/// Preset list: header, summary and button row take the rest (224: five whole rows).
	static var presetListHeight: CGFloat { sectionInnerHeight - headerHeight - summaryHeight - actionRowHeight - spacing * 3 }
	/// Folder list: header and button row take the rest (308: seven whole rows).
	static var targetListHeight: CGFloat { sectionInnerHeight - headerHeight - actionRowHeight - spacing * 2 }
}

extension View {
	/// Root of the window: exactly `UILayout.content`, whatever the content is. With `.windowResizability(.contentSize)`
	/// this is also the window's minimum and maximum content size.
	func fixedContentSize() -> some View {
		frame(width: UILayout.content.width, height: UILayout.content.height, alignment: .topLeading)
	}

	/// An area of the window: takes the offered size as is (its content can neither grow nor shrink it). Overflow is
	/// cut, but not the focus rings (≈3pt) of the controls at its edges.
	func section(_ insets: EdgeInsets) -> some View {
		frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
			.clipShape(Rectangle().inset(by: -4))
			.padding(insets)
	}

	/// Inner area of a column (lists, the preset summary). `clips` false leaves the content unclipped, for a panel whose
	/// controls may draw a focus ring over the border (the editor's option panel).
	func well(clips: Bool = true) -> some View { modifier(Well(clips: clips)) }

	/// Debug builds started with `--layout-probe` record this view's frame (window coordinates) for the probe's
	/// overlap checks. Otherwise (and always in release builds) the view is returned unchanged.
	@ViewBuilder func probeFrame(_ id: String) -> some View {
		#if DEBUG
		if LayoutProbe.isRequested {
			onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
				MainActor.assumeIsolated { LayoutProbe.frames[id] = frame }
			}
		} else {
			self
		}
		#else
		self
		#endif
	}
}

private struct Well: ViewModifier {
	let clips: Bool
	@Environment(\.colorSchemeContrast) private var contrast

	@ViewBuilder func body(content: Content) -> some View {
		let shape = RoundedRectangle(cornerRadius: UILayout.wellRadius, style: .continuous)
		(clips ? AnyView(content.clipShape(shape)) : AnyView(content))
			.background(Theme.well, in: shape)
			.overlay { shape.strokeBorder(Theme.hairline(contrast), lineWidth: 1) }
	}
}

/// Keeps the main window at its fixed size on macOS 14–26 through one AppKit path (the macOS 15 scene modifiers
/// `windowResizeBehavior` / `windowFullScreenBehavior` are not used, so the path checked here is the one macOS 14 runs):
/// no `.resizable` in the style mask (no edge or corner drag, no title-bar double-click zoom, no Fill/Tile resize), no
/// full screen, zoom button disabled, no window tabs (a tab bar would make the window 28pt taller; the app also turns
/// off `NSWindow.allowsAutomaticWindowTabbing`, which removes 보기 > 탭 막대 보기). SwiftUI finishes configuring the
/// window after the first attach and may touch it again (after a sheet), so the settings are applied again then;
/// applying them twice changes nothing.
struct FixedWindow: NSViewRepresentable {
	func makeNSView(context: Context) -> Hook { Hook() }
	func updateNSView(_ view: Hook, context: Context) { view.apply() }

	final class Hook: NSView {
		private var observers: [NSObjectProtocol] = []
		private var corrected = false

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewWillMove(toWindow newWindow: NSWindow?) {
			super.viewWillMove(toWindow: newWindow)
			observers.forEach { NotificationCenter.default.removeObserver($0) }
			observers = []
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let window else { return }
			apply()
			// The Finder services bring this window back (FinderServices.swift).
			FinderServiceProvider.shared.mainWindow = window
			for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
				observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.apply() }
				})
			}
			Task { @MainActor [weak self] in
				self?.apply()
				self?.correctSizeOnce()
			}
		}

		func apply() {
			guard let window, window.sheetParent == nil else { return }
			if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
			var behavior = window.collectionBehavior
			behavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
			behavior.insert(.fullScreenNone)
			if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
			if let zoom = window.standardWindowButton(.zoomButton), zoom.isEnabled { zoom.isEnabled = false }
			if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
		}

		/// A frame remembered by an older version (1080×700) or a restored window state can open the window larger.
		/// Once, at launch, the window goes back to the fixed content size, its top-left corner staying where it is.
		/// Nothing happens when the size is already right.
		private func correctSizeOnce() {
			guard !corrected, let window else { return }
			corrected = true
			let content = window.contentLayoutRect.size
			guard abs(content.width - UILayout.content.width) > 1 || abs(content.height - UILayout.content.height) > 1 else { return }
			var frame = window.frame
			let toolbar = frame.height - content.height
			frame.size = NSSize(width: UILayout.content.width, height: UILayout.content.height + toolbar)
			frame.origin.y = window.frame.maxY - frame.height
			window.setFrame(frame, display: true)
		}
	}
}

/// Keeps a list's scroll position where it belongs (one AppKit path on macOS 14–26). NSTableView can leave a list whose
/// rows all fit scrolled by the height it guessed wrong for a row inserted above the others (a preset that sorts first,
/// imported and selected: 16pt, the first row cut at the top), and nothing brings it back until the user scrolls. So
/// whenever the rows, the visible area or the document change and the rows fit, the list goes back to its top. With a
/// `selection`, a list whose rows do not fit scrolls the selected row into view when the rows change under it (an
/// imported preset, the preset selected after a delete). With `revealsAppended`, rows added at the end of a list that
/// does not fit are scrolled into view (folders dropped on a long folder list). Put it in the list's `background`: it
/// finds the list by its frame and draws nothing.
struct ListScrollKeeper: NSViewRepresentable {
	var rows: [AnyHashable]
	var selection: AnyHashable?
	var revealsAppended: Bool

	init<ID: Hashable & Sendable>(rows: [ID], selection: ID? = nil, revealsAppended: Bool = false) {
		self.rows = rows.map { AnyHashable($0) }
		self.selection = selection.map { AnyHashable($0) }
		self.revealsAppended = revealsAppended
	}

	func makeNSView(context: Context) -> Hook { Hook() }
	func updateNSView(_ view: Hook, context: Context) { view.update(rows: rows, selection: selection, revealsAppended: revealsAppended) }

	final class Hook: NSView {
		private weak var scroll: NSScrollView?
		private var observers: [NSObjectProtocol] = []
		private var rows: [AnyHashable] = []
		private var selection: AnyHashable?
		private var scheduled = false

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewWillMove(toWindow newWindow: NSWindow?) {
			super.viewWillMove(toWindow: newWindow)
			observers.forEach { NotificationCenter.default.removeObserver($0) }
			observers = []
			scroll = nil
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			schedule()
		}

		/// Reveals the selection when the rows changed and it is new (an imported preset) or moved to another row (the
		/// first preset after the selected one was deleted); a rename that only reorders the rows leaves the list alone.
		/// With `revealsAppended`, rows added after all the old ones reveal the last of them. The first rows a list gets
		/// (at launch, or dropped on an empty list) are shown from the top.
		func update(rows new: [AnyHashable], selection newSelection: AnyHashable?, revealsAppended: Bool) {
			let (old, oldSelection) = (rows, selection)
			(rows, selection) = (new, newSelection)
			var target: Int?
			if let newSelection, new != old, !old.isEmpty, !old.contains(newSelection) || newSelection != oldSelection,
			   let index = new.firstIndex(of: newSelection) {
				target = index
			} else if revealsAppended, !old.isEmpty, new.count > old.count, new.starts(with: old) {
				target = new.count - 1
			}
			if let target {
				// After the table has the new rows.
				DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reveal(row: target) } }
			}
			schedule()
		}

		/// One check per run loop turn, after AppKit has finished what it was doing.
		private func schedule() {
			guard !scheduled else { return }
			scheduled = true
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated {
					guard let self else { return }
					self.scheduled = false
					self.keepAtTopIfFitting()
				}
			}
		}

		private func list() -> NSScrollView? {
			if let scroll, scroll.window === window { return scroll }
			guard let window, let root = window.contentView else { return nil }
			let mine = convert(bounds, to: nil)
			guard mine.width > 1, mine.height > 1 else { return nil }
			func find(_ view: NSView) -> NSScrollView? {
				if let s = view as? NSScrollView, s.documentView is NSTableView {
					let f = s.convert(s.bounds, to: nil)
					if abs(f.minX - mine.minX) < 2, abs(f.minY - mine.minY) < 2, abs(f.width - mine.width) < 2, abs(f.height - mine.height) < 2 { return s }
				}
				for sub in view.subviews { if let s = find(sub) { return s } }
				return nil
			}
			guard let found = find(root) else { return nil }
			scroll = found
			found.contentView.postsBoundsChangedNotifications = true
			var watched: [(NSView, Notification.Name)] = [(found.contentView, NSView.boundsDidChangeNotification)]
			if let document = found.documentView {
				document.postsFrameChangedNotifications = true
				watched.append((document, NSView.frameDidChangeNotification))
			}
			for (view, name) in watched {
				observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.schedule() }
				})
			}
			return found
		}

		private static func fits(_ scroll: NSScrollView) -> Bool {
			let insets = scroll.contentInsets
			let visible = scroll.contentView.bounds.height - insets.top - insets.bottom
			return (scroll.documentView?.frame.height ?? 0) <= visible + 0.5
		}

		private func keepAtTopIfFitting() {
			guard let scroll = list(), Self.fits(scroll) else { return }
			let clip = scroll.contentView
			let top = -scroll.contentInsets.top
			guard abs(clip.bounds.minY - top) > 0.5 else { return }
			clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
			scroll.reflectScrolledClipView(clip)
		}

		private func reveal(row: Int) {
			guard let scroll = list(), !Self.fits(scroll), let table = scroll.documentView as? NSTableView, row < table.numberOfRows else { return }
			table.scrollRowToVisible(row)
		}
	}
}

import SwiftUI
import AppKit
import FinderPresetsCore

// Colors are built in code (no asset catalog): each token is a light/dark pair resolved with the appearance of the
// view that draws it, so windows, sheets and FINDER_PRESETS_APPEARANCE (debug builds) all follow. The system accent color stays
// in charge of selection, checkboxes and prominent buttons (no global `.tint`); the brand colors below are for
// decoration and drop feedback only.

extension NSColor {
	convenience init(hex: UInt32, alpha: CGFloat = 1) {
		self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
		          blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
	}
}

extension Color {
	init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }

	/// A light/dark pair resolved with the drawing view's appearance.
	init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
		self.init(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
				? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
		})
	}
}

enum Theme {
	/// Window body: both columns and the whole-system bar (the toolbar keeps the system look).
	static let canvas = Color(light: 0xF3F4F8, dark: 0x222329)
	/// Lists and the preset summary: a step lighter than the canvas in light mode, a step darker in dark mode.
	static let well = Color(light: 0xFFFFFF, dark: 0x18191E)
	/// Well borders, the column divider and the line above the whole-system bar.
	static let hairline = Color(light: 0xDFE1E8, dark: 0x34353E)
	/// Replaces `hairline`, `cardStroke` and the dashed outlines when "대비 증가" is on.
	static let strokeHighContrast = Color(light: 0x8A8FA3, dark: 0x8A8D99)
	/// The preset chip of the whole-system bar.
	static let chip = Color(light: 0xFFFFFF, dark: 0x2C2D35)
	/// The mini window of the view-style thumbnails.
	static let card = Color(light: 0xFFFFFF, dark: 0x26272E)
	/// Outline of the thumbnails and of the preset capsules.
	static let cardStroke = Color(light: 0xE3E5EE, dark: 0x3A3B44)
	/// Sheets (사용법, 시스템 전체 확인): a step lighter than the canvas in dark mode, so a sheet's edge stands out from
	/// the dimmed window behind it.
	static let sheet = Color(light: 0xFFFFFF, dark: 0x2E2F38)
	/// Title-bar dots of the thumbnails.
	static let grip = Color(light: 0xC9CCD8, dark: 0x4A4C57)
	static let shadow = Color(light: 0x1B1F3B, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.35)
	/// Fill behind white text (drop capsules): 5.3:1 light, 4.7:1 dark.
	static let accent = Color(light: 0x1F66D6, dark: 0x1E6FE3)
	/// Accent as text, icon or stroke: 5.3:1 on the light well (4.9:1 on the canvas), 7.2–8.0:1 dark.
	static let accentText = Color(light: 0x1F66D6, dark: 0x6BB4FF)
	/// Warning text and icons (the old `.orange` was 2.2:1 on white): 5.0:1 on the light well (4.6:1 on the canvas),
	/// 8.6:1 or more dark.
	static let warning = Color(light: 0xB45309, dark: 0xF5B544)
	static let success = Color(light: 0x1E7F45, dark: 0x4CC983)

	/// The app icon's two blues, sky to royal (lighter in dark mode). Decoration only (empty-state symbols, "image" cells
	/// of the thumbnails) — never behind text.
	static let brandColors = [Color(light: 0x2A8CF5, dark: 0x5CC0FF), Color(light: 0x1D5FD8, dark: 0x2F7CF0)]
	static var brand: LinearGradient {
		LinearGradient(colors: brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
	}
	/// Darker variant that carries white glyphs (step badges, tiles): 4.7:1 / 7.4:1.
	static var badge: LinearGradient {
		LinearGradient(colors: [Color(hex: 0x1E6FE3), Color(hex: 0x1648CE)], startPoint: .topLeading, endPoint: .bottomTrailing)
	}

	static func hairline(_ contrast: ColorSchemeContrast) -> Color { contrast == .increased ? strokeHighContrast : hairline }
	static func cardStroke(_ contrast: ColorSchemeContrast) -> Color { contrast == .increased ? strokeHighContrast : cardStroke }
}

/// `base`, or `selected` on an emphasized (accent) list selection. Resolved where the shape is drawn, so it follows the
/// selection highlight like the hierarchical styles do (a view-level environment read does not see it in list rows).
struct OnSelection: ShapeStyle {
	let base: AnyShapeStyle
	let selected: AnyShapeStyle

	init(_ base: some ShapeStyle, selected: some ShapeStyle) {
		self.base = AnyShapeStyle(base)
		self.selected = AnyShapeStyle(selected)
	}

	func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
		environment.backgroundProminence == .increased ? selected : base
	}
}

/// Per-preset color (dot, folder icon, tag). Stable across launches: FNV-1a of the UUID bytes picks a preferred slot
/// (`hashValue` changes every run); presets are visited oldest first and, while fewer than eight exist, a taken slot
/// moves to the next free one. A rename never changes a color; an import is always the newest preset.
enum PresetTint {
	static let colors: [Color] = [
		Color(light: 0x2F7CF6, dark: 0x5AA2FF),   // blue
		Color(light: 0x9445EB, dark: 0xB785FF),   // purple
		Color(light: 0x23945A, dark: 0x4FD18B),   // green
		Color(light: 0xE06A12, dark: 0xFFA052),   // orange
		Color(light: 0x11899B, dark: 0x4CC9D9),   // teal
		Color(light: 0xD9437A, dark: 0xFF7FAE),   // pink
		Color(light: 0x5B5FEF, dark: 0x8E92FF),   // indigo
		Color(light: 0xB98900, dark: 0xF2C94C)    // yellow
	]

	static func map(for presets: [Preset]) -> [UUID: Color] {
		slots(for: presets.map { ($0.id, $0.createdAt) }).mapValues { colors[$0] }
	}

	static func slots(for presets: [(id: UUID, createdAt: Date)]) -> [UUID: Int] {
		var result: [UUID: Int] = [:]
		var used = Set<Int>()
		for p in presets.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
			var slot = preferredSlot(p.id)
			if used.count < colors.count { while used.contains(slot) { slot = (slot + 1) % colors.count } }
			used.insert(slot)
			result[p.id] = slot
		}
		return result
	}

	static func preferredSlot(_ id: UUID) -> Int {
		let hash = withUnsafeBytes(of: id.uuid) { bytes in
			bytes.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
		}
		return Int(hash % UInt32(colors.count))
	}
}

#if DEBUG
/// Development aid for screenshots, debug builds only: `FINDER_PRESETS_APPEARANCE=light|dark` forces this process's appearance.
/// Nothing is written to the system settings or to the defaults; any other value is ignored and the system appearance is used.
@MainActor
enum AppearanceOverride {
	static func applyFromEnvironment() {
		switch ProcessInfo.processInfo.environment["FINDER_PRESETS_APPEARANCE"] {
		case "light"?: NSApp.appearance = NSAppearance(named: .aqua)
		case "dark"?: NSApp.appearance = NSAppearance(named: .darkAqua)
		default: break
		}
	}
}
#endif

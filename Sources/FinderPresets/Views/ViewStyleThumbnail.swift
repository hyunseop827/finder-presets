import SwiftUI
import FinderPresetsCore

/// A miniature Finder window drawn from a preset's values only (never from the disk). Decorative: hidden from
/// accessibility, the row's summary line carries the same information as text.
///
/// - icon: cell size from icon.iconSize (16…128 → 6…16pt), gap from icon.gridSpacing, label under the cell or to its
///   right (labelOnBottom == false), label thickness from icon.textSize, an extra accent line for showItemInfo,
///   gradient "image" cells for showIconPreview.
/// - list: header with the sort column tinted (▲/▼ from sortAscending), row height from list.textSize, row icon from
///   list.iconSize (16 / 32).
/// - column: three panes with a selection chain. gallery: large preview and a strip of five thumbnails.
/// - no view style: what the preset's options imply (icon options → icon, list options → list), or — `neutralWhenKept`,
///   the preset editor while its view is "유지" — no view at all (an empty window: each folder keeps its own view); dimmed,
///   with a dashed frame and a "유지" chip ("값 없음" when the preset holds nothing).
struct ViewStyleThumbnail: View {
	let settings: ViewSettings
	var size: CGSize = UILayout.thumbnail
	/// Draws no view (only the empty, dimmed window) when the preset leaves the view style alone.
	var neutralWhenKept = false
	@Environment(\.colorSchemeContrast) private var contrast

	/// The view drawn: the preset's, or what its options imply (nil: none).
	private var style: ViewStyle? {
		settings.viewStyle ?? (neutralWhenKept ? nil : (!settings.icon.isEmpty ? .icon : (!settings.list.isEmpty ? .list : nil)))
	}

	var body: some View {
		let style = self.style
		let settings = self.settings
		let kept = settings.viewStyle == nil
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Theme.card)
			Rectangle().fill(Theme.hairline).frame(height: 5.5)
			HStack(spacing: 1.5) {
				ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.grip).frame(width: 2, height: 2) }
			}
			.padding(.leading, 3.5)
			.padding(.top, 1.75)
			Canvas { ctx, canvasSize in
				let area = CGRect(x: 3.5, y: 8, width: canvasSize.width - 7, height: canvasSize.height - 10.5)
				switch style {
				case .icon?: Self.drawIcons(&ctx, area, settings)
				case .list?: Self.drawList(&ctx, area, settings)
				case .column?: Self.drawColumns(&ctx, area)
				case .gallery?: Self.drawGallery(&ctx, area)
				case nil: break
				}
			}
			.opacity(kept ? 0.45 : 1)
			if kept {
				// "값 없음" only when the preset holds nothing at all (one with only a grouping keeps the view style).
				Text(settings.isEmpty ? "값 없음" : "유지")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(Self.chipText)
					.padding(.horizontal, 3)
					.background(Theme.well, in: Capsule())
					.overlay(Capsule().strokeBorder(Theme.cardStroke(contrast)))
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
					.padding(2)
			}
		}
		.frame(width: size.width, height: size.height)
		.clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
				.strokeBorder(OnSelection(Theme.cardStroke(contrast), selected: Color.white.opacity(0.6)),
				              style: StrokeStyle(lineWidth: 1, dash: kept ? [3, 2] : []))
		}
		.accessibilityHidden(true)
	}

	private static let radius: CGFloat = 5

	// MARK: Drawing

	/// Fixed pairs, not `.secondary`: the mini window is always `Theme.card`, while a hierarchical style turns white on
	/// the accent selection and would vanish there (labels, list columns, column rows).
	private static let ink = Color(light: 0xA9ADBC, dark: 0x6E717D)
	private static let chipText = Color(light: 0x5F6475, dark: 0xA3A6B2)
	private static let folderBlue = Color(light: 0x7FB2FF, dark: 0x4F8FE8)
	private static let imageGradient = Gradient(colors: Theme.brandColors)

	private static func drawIcons(_ ctx: inout GraphicsContext, _ area: CGRect, _ s: ViewSettings) {
		let iconSize = CGFloat(s.icon.iconSize ?? 64)
		let cell = min(16, max(6, 6 + (iconSize - 16) / (128 - 16) * 10))
		let gap = min(8, max(2, CGFloat(s.icon.gridSpacing ?? 54) / 54 * 4))
		let labelRight = s.icon.labelOnBottom == false
		let label: CGFloat = (s.icon.textSize ?? 12) >= 14 ? 2.5 : 1.8
		let info = s.icon.showItemInfo == true
		let itemW = labelRight ? cell + 2 + cell * 1.3 : cell
		let itemH = labelRight ? cell : cell + 2 + label + (info ? 1 + label : 0)
		let cols = max(1, Int((area.width + gap) / (itemW + gap)))
		let rows = max(1, Int((area.height + gap) / (itemH + gap)))
		for r in 0..<rows {
			for c in 0..<cols {
				let x = area.minX + CGFloat(c) * (itemW + gap)
				let y = area.minY + CGFloat(r) * (itemH + gap)
				let icon = CGRect(x: x, y: y, width: cell, height: cell)
				if s.icon.showIconPreview == true {
					ctx.fill(Path(roundedRect: icon, cornerRadius: cell * 0.18),
					         with: .linearGradient(imageGradient, startPoint: icon.origin, endPoint: CGPoint(x: icon.maxX, y: icon.maxY)))
				} else {
					var folder = Path(roundedRect: icon.insetBy(dx: 0, dy: cell * 0.12).offsetBy(dx: 0, dy: cell * 0.06), cornerRadius: cell * 0.12)
					folder.addRoundedRect(in: CGRect(x: icon.minX, y: icon.minY, width: cell * 0.45, height: cell * 0.3), cornerSize: CGSize(width: 1, height: 1))
					ctx.fill(folder, with: .color(folderBlue))
				}
				if labelRight {
					ctx.fill(Path(roundedRect: CGRect(x: icon.maxX + 2, y: icon.midY - label / 2, width: cell * 1.3, height: label), cornerRadius: label / 2),
					         with: .color(ink))
				} else {
					ctx.fill(Path(roundedRect: CGRect(x: x + cell * 0.08, y: icon.maxY + 2, width: cell * 0.84, height: label), cornerRadius: label / 2),
					         with: .color(ink))
					if info {
						ctx.fill(Path(roundedRect: CGRect(x: x + cell * 0.2, y: icon.maxY + 3 + label, width: cell * 0.6, height: label), cornerRadius: label / 2),
						         with: .color(Theme.accentText.opacity(0.8)))
					}
				}
			}
		}
	}

	private static func sortColumnIndex(_ c: ListColumn?) -> Int? {
		switch c {
		case .name?: 0
		case .dateModified?, .dateCreated?, .dateAdded?, .dateLastOpened?: 1
		case nil: nil
		default: 2
		}
	}

	private static func drawList(_ ctx: inout GraphicsContext, _ area: CGRect, _ s: ViewSettings) {
		let header: CGFloat = 5
		let columns: [(CGFloat, CGFloat)] = [(0, 0.5), (0.5, 0.8), (0.8, 1)]   // name | dates | the rest
		let sorted = sortColumnIndex(s.list.sortColumn)
		for (i, col) in columns.enumerated() {
			let rect = CGRect(x: area.minX + area.width * col.0, y: area.minY, width: area.width * (col.1 - col.0) - 1, height: header)
			ctx.fill(Path(rect), with: .color(i == sorted ? Theme.accentText.opacity(0.35) : Theme.hairline))
			if i == sorted {
				var tri = Path()
				let cx = rect.maxX - 3, cy = rect.midY
				if s.list.sortAscending == false {
					tri.move(to: CGPoint(x: cx - 1.6, y: cy - 1)); tri.addLine(to: CGPoint(x: cx + 1.6, y: cy - 1)); tri.addLine(to: CGPoint(x: cx, y: cy + 1.2))
				} else {
					tri.move(to: CGPoint(x: cx - 1.6, y: cy + 1)); tri.addLine(to: CGPoint(x: cx + 1.6, y: cy + 1)); tri.addLine(to: CGPoint(x: cx, y: cy - 1.2))
				}
				ctx.fill(tri, with: .color(Theme.accentText))
			}
		}
		let rowH = max(4.5, CGFloat(s.list.textSize ?? 12) / 2)
		let iconSide: CGFloat = (s.list.iconSize ?? 16) >= 32 ? 4.5 : 3
		var y = area.minY + header + 1.5
		var index = 0
		while y + rowH <= area.maxY {
			if index % 2 == 1 { ctx.fill(Path(CGRect(x: area.minX, y: y, width: area.width, height: rowH)), with: .color(Theme.well)) }
			let icon = CGRect(x: area.minX + 1.5, y: y + (rowH - iconSide) / 2, width: iconSide, height: iconSide)
			ctx.fill(Path(roundedRect: icon, cornerRadius: 0.8), with: s.list.showIconPreview == true
				? .linearGradient(imageGradient, startPoint: icon.origin, endPoint: CGPoint(x: icon.maxX, y: icon.maxY))
				: .color(folderBlue))
			let bar = min(1.8, rowH * 0.35)
			let widths: [CGFloat] = [0.34 - CGFloat(index % 3) * 0.05, 0.22, 0.1]
			let starts: [CGFloat] = [0, 0.5, 0.8]
			for k in 0..<3 {
				let x = k == 0 ? icon.maxX + 2 : area.minX + area.width * starts[k] + 1
				ctx.fill(Path(roundedRect: CGRect(x: x, y: y + (rowH - bar) / 2, width: area.width * widths[k], height: bar), cornerRadius: bar / 2),
				         with: .color(k == sorted ? Theme.accentText.opacity(0.7) : ink))
			}
			y += rowH
			index += 1
		}
	}

	private static func drawColumns(_ ctx: inout GraphicsContext, _ area: CGRect) {
		let paneW = area.width / 3
		for p in 0..<3 {
			let x = area.minX + CGFloat(p) * paneW
			if p > 0 { ctx.fill(Path(CGRect(x: x - 0.5, y: area.minY, width: 1, height: area.height)), with: .color(Theme.hairline)) }
			var y = area.minY + 1
			var row = 0
			while y + 5 <= area.maxY && row < (p == 2 ? 3 : 7) {
				let selected = (p == 0 && row == 1) || (p == 1 && row == 3)
				if selected {
					ctx.fill(Path(roundedRect: CGRect(x: x + 1, y: y, width: paneW - 2, height: 5), cornerRadius: 1.2), with: .color(Theme.accentText.opacity(0.85)))
				}
				ctx.fill(Path(roundedRect: CGRect(x: x + 3, y: y + 1.6, width: paneW * (0.55 - CGFloat(row % 3) * 0.08), height: 1.8), cornerRadius: 0.9),
				         with: .color(selected ? .white : ink))
				if p < 2 { ctx.fill(Path(CGRect(x: x + paneW - 4, y: y + 1.8, width: 1.4, height: 1.4)), with: .color(selected ? .white : ink)) }
				y += 5.5
				row += 1
			}
		}
	}

	private static func drawGallery(_ ctx: inout GraphicsContext, _ area: CGRect) {
		let stripH = min(9, area.height * 0.26)
		let preview = CGRect(x: area.minX + area.width * 0.18, y: area.minY, width: area.width * 0.64, height: area.height - stripH - 3)
		ctx.fill(Path(roundedRect: preview, cornerRadius: 2),
		         with: .linearGradient(imageGradient, startPoint: preview.origin, endPoint: CGPoint(x: preview.maxX, y: preview.maxY)))
		let count = 5
		let gap: CGFloat = 2
		let w = (area.width - gap * CGFloat(count - 1)) / CGFloat(count)
		for i in 0..<count {
			let r = CGRect(x: area.minX + CGFloat(i) * (w + gap), y: area.maxY - stripH, width: w, height: stripH)
			ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(i == 1 ? Theme.accentText.opacity(0.35) : Theme.hairline))
			if i == 1 { ctx.stroke(Path(roundedRect: r, cornerRadius: 1.5), with: .color(Theme.accentText), lineWidth: 1) }
		}
	}
}

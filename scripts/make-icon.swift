#!/usr/bin/env swift
// Draws the app icon with CoreGraphics (no Xcode, no asset catalog) and writes an Apple .iconset folder.
//
//   (source scripts/toolchain.sh && swift scripts/make-icon.swift <output.iconset>)
//   build-app.sh runs this when Resources/AppIcon.icns is missing.
//
// Then: iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
//
// Design ("two-tone split + folder"): a macOS squircle split down the middle into a bright sky-blue half and a
// deeper royal-blue half. Centred across the split sits one bold white folder silhouette (tab top-left) with a
// 2×2 grid of rounded squares cut out of its front — the icon-view glyph — so the two blues show through the
// grid. Nothing else. No text.
// Everything is laid out on a 1024-unit grid and scaled; at 64 px and below the folder and grid are snapped to
// whole device pixels so the holes stay crisp.

import AppKit
import CoreGraphics

// MARK: - Sizes required by iconutil (file name → pixel size)

let iconsetEntries: [(name: String, pixels: Int)] = [
	("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
	("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
	("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
	("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
	("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// 0–255 components, easier to read next to a colour picker.
func rgb8(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
	CGColor(colorSpace: sRGB, components: [r / 255, g / 255, b / 255, a])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
	CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

/// Continuous-corner rounded rectangle (the macOS "squircle"). Each corner is a superellipse quadrant that
/// starts 1.528·r from the corner, which blends curvature into the straight edges the way Apple's continuous
/// corners do; the 45° point lands where a circular corner of radius r would put it.
func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
	let e = min(r * 1.528, rect.width / 2, rect.height / 2)
	let n: CGFloat = 3.27
	let steps = 64
	let centers: [(x: CGFloat, y: CGFloat, start: CGFloat)] = [
		(rect.maxX - e, rect.maxY - e, 0),
		(rect.minX + e, rect.maxY - e, .pi / 2),
		(rect.minX + e, rect.minY + e, .pi),
		(rect.maxX - e, rect.minY + e, .pi * 1.5)
	]
	let path = CGMutablePath()
	for (i, c) in centers.enumerated() {
		for j in 0...steps {
			let t = c.start + CGFloat(j) / CGFloat(steps) * .pi / 2
			let ct = cos(t), st = sin(t)
			let p = CGPoint(x: c.x + e * copysign(pow(abs(ct), 2 / n), ct), y: c.y + e * copysign(pow(abs(st), 2 / n), st))
			if i == 0 && j == 0 { path.move(to: p) } else { path.addLine(to: p) }
		}
	}
	path.closeSubpath()
	return path
}

/// Closed polygon whose corners are rounded with the given radii (one per point; concave corners work too).
func roundedPolygon(_ pts: [CGPoint], radii: [CGFloat]) -> CGPath {
	let path = CGMutablePath()
	let count = pts.count
	let last = pts[count - 1], first = pts[0]
	path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
	for i in 0..<count {
		path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % count], radius: radii[i])
	}
	path.closeSubpath()
	return path
}

/// Fills `path` with a vertical gradient running from the top (maxY) to the bottom (minY) of `rect`.
func fillVertical(_ ctx: CGContext, _ path: CGPath, _ rect: CGRect, _ g: CGGradient) {
	ctx.saveGState()
	ctx.addPath(path)
	ctx.clip()
	ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
	                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	ctx.restoreGState()
}

// MARK: - Palette

enum Palette {
	// Left half: bright sky blue.
	static let lightTop = rgb8(104, 204, 255)
	static let lightBottom = rgb8(38, 150, 242)
	// Right half: deeper royal blue.
	static let deepTop = rgb8(40, 118, 240)
	static let deepBottom = rgb8(22, 72, 206)
	// Symbol.
	static let white = rgb8(255, 255, 255)
	static let whiteBottom = rgb8(240, 246, 255)
	static let symbolShadow = rgb8(8, 36, 120, 0.22)
	static let bodyShadow = rgb8(0, 0, 0, 0.30)
}

// MARK: - Icon

func drawIcon(in ctx: CGContext, size s: CGFloat) {
	ctx.setAllowsAntialiasing(true)
	ctx.setShouldAntialias(true)
	ctx.interpolationQuality = .high
	let k = s / 1024          // device pixels per design unit (shadow offsets and blurs are in device pixels)
	let small = s <= 32
	let snap = s <= 64
	/// Rounds a design-unit coordinate to a whole device pixel at small sizes (64 px and below).
	func px(_ v: CGFloat) -> CGFloat { snap ? (v * k).rounded() / k : v }
	ctx.scaleBy(x: k, y: k)

	// Background squircle on Apple's icon grid: 824×824 centred, continuous corners r ≈ 185.
	let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
	let bgPath = continuousRect(bgRect, radius: 185)

	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 26 * k, color: Palette.bodyShadow)
	ctx.addPath(bgPath)
	ctx.setFillColor(Palette.deepBottom)
	ctx.fillPath()
	ctx.restoreGState()

	// The two tones, split by one straight vertical line through the centre.
	let splitX: CGFloat = 512
	ctx.saveGState()
	ctx.addPath(bgPath)
	ctx.clip()
	let leftRect = CGRect(x: bgRect.minX, y: bgRect.minY, width: splitX - bgRect.minX, height: bgRect.height)
	let rightRect = CGRect(x: splitX, y: bgRect.minY, width: bgRect.maxX - splitX, height: bgRect.height)
	fillVertical(ctx, CGPath(rect: leftRect, transform: nil), bgRect, gradient([Palette.lightTop, Palette.lightBottom], [0, 1]))
	fillVertical(ctx, CGPath(rect: rightRect, transform: nil), bgRect, gradient([Palette.deepTop, Palette.deepBottom], [0, 1]))
	ctx.restoreGState()

	// Folder silhouette. Small sizes get a slightly larger folder (relative to the squircle) so the grid survives.
	let scale: CGFloat = s <= 16 ? 1.16 : (s <= 32 ? 1.06 : 1)
	let folderW = 528 * scale
	let bodyH = 368 * scale
	let tabH = 56 * scale
	let tabW = 150 * scale           // flat top of the tab
	let slopeW = 46 * scale          // horizontal run of the tab's sloped shoulder
	let totalH = bodyH + tabH
	let x0 = px(512 - folderW / 2)
	let x1 = px(512 + folderW / 2)
	let y0 = px(512 - totalH / 2 + 4)
	let yb = px(y0 + bodyH)          // top edge of the body (tab sits above this)
	let yt = px(yb + tabH)           // top of the tab
	let bodyR = 56 * scale
	let folderPath = roundedPolygon([
		CGPoint(x: x0, y: y0),
		CGPoint(x: x1, y: y0),
		CGPoint(x: x1, y: yb),
		CGPoint(x: x0 + tabW + slopeW, y: yb),
		CGPoint(x: x0 + tabW, y: yt),
		CGPoint(x: x0, y: yt)
	], radii: [bodyR, bodyR, bodyR * 0.8, 22 * scale, 20 * scale, bodyR * 0.8])

	// 2×2 grid of rounded squares, centred on the body (below the tab), straddling the split.
	// At 64 px and below the grid is set in whole device pixels (3-px cells at 32, 2-px cells at 16, 1-px gaps).
	var gap = 32 * scale
	var cell = 108 * scale
	if small {
		gap = 1 / k
		cell = (s <= 16 ? 2 : 3) / k
	} else if snap {
		gap = (gap * k).rounded() / k
		cell = (cell * k).rounded() / k
	}
	let gridW = 2 * cell + gap
	let gridX = px(512 - gridW / 2)
	let gridY = px((y0 + yb) / 2 - gridW / 2)
	let cellR = small ? 0 : 28 * scale
	var cells: [CGRect] = []
	for row in 0..<2 {
		for col in 0..<2 {
			cells.append(CGRect(x: gridX + CGFloat(col) * (cell + gap), y: gridY + CGFloat(row) * (cell + gap), width: cell, height: cell))
		}
	}

	// Folder as one transparency layer so its shadow hugs the silhouette and the holes show the blues behind.
	ctx.saveGState()
	if !small {
		ctx.setShadow(offset: CGSize(width: 0, height: -8 * k), blur: 28 * k, color: Palette.symbolShadow)
	}
	ctx.beginTransparencyLayer(auxiliaryInfo: nil)
	fillVertical(ctx, folderPath, CGRect(x: x0, y: y0, width: x1 - x0, height: yt - y0), gradient([Palette.white, Palette.whiteBottom], [0, 1]))
	ctx.setBlendMode(.destinationOut)
	ctx.setFillColor(rgb8(0, 0, 0))
	for c in cells {
		ctx.addPath(continuousRect(c, radius: cellR))
		ctx.fillPath()
	}
	ctx.setBlendMode(.normal)
	ctx.endTransparencyLayer()
	ctx.restoreGState()
}

func renderPNG(pixels: Int) throws -> Data {
	guard let ctx = CGContext(
		data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
		space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	) else { throw IconError.context(pixels) }
	ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
	drawIcon(in: ctx, size: CGFloat(pixels))
	guard let image = ctx.makeImage() else { throw IconError.image(pixels) }
	let rep = NSBitmapImageRep(cgImage: image)
	guard let png = rep.representation(using: .png, properties: [:]) else { throw IconError.encode(pixels) }
	return png
}

enum IconError: Error, CustomStringConvertible {
	case usage, context(Int), image(Int), encode(Int)
	var description: String {
		switch self {
		case .usage: return "usage: swift scripts/make-icon.swift <output.iconset>"
		case .context(let n): return "could not create a \(n)px bitmap context"
		case .image(let n): return "could not rasterize the \(n)px icon"
		case .encode(let n): return "could not encode the \(n)px icon as PNG"
		}
	}
}

// MARK: - Main

do {
	let args = CommandLine.arguments
	guard args.count == 2 else { throw IconError.usage }
	let outDir = URL(fileURLWithPath: args[1])
	try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
	for entry in iconsetEntries {
		let data = try renderPNG(pixels: entry.pixels)
		try data.write(to: outDir.appendingPathComponent(entry.name), options: .atomic)
	}
	print("wrote \(iconsetEntries.count) images to \(outDir.path)")
} catch {
	FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
	exit(1)
}

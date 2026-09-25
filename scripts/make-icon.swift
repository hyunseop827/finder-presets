#!/usr/bin/env swift
// Draws the app icon with CoreGraphics (no Xcode, no asset catalog) and writes an Apple .iconset folder.
//
//   (source scripts/toolchain.sh && swift scripts/make-icon.swift <output.iconset>)
//   build-app.sh runs this when Resources/AppIcon.icns is missing.
//
// Then: iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
//
// Design: macOS-style rounded square with a blue→purple gradient, a white folder silhouette on top,
// and a 2×2 grid punched out of the folder's front panel (the "icon view" metaphor). No text.
// Every length is a fraction of the canvas size, so line weights and margins scale with the icon.

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

// MARK: - Drawing

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
	CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

/// Snaps a rect to whole pixels for tiny sizes so edges stay crisp instead of smearing across two pixels.
func snapped(_ rect: CGRect, canvas: CGFloat) -> CGRect {
	guard canvas <= 64 else { return rect }
	let x = rect.minX.rounded(), y = rect.minY.rounded()
	return CGRect(x: x, y: y, width: max(1, rect.maxX.rounded() - x), height: max(1, rect.maxY.rounded() - y))
}

func drawIcon(in ctx: CGContext, size s: CGFloat) {
	ctx.setAllowsAntialiasing(true)
	ctx.setShouldAntialias(true)
	ctx.interpolationQuality = .high

	// Background: Apple's icon grid — the rounded square is ~82% of the canvas, corner radius ~22.5% of its side.
	let bgInset = s * 0.0977
	let bgRect = CGRect(x: bgInset, y: bgInset, width: s - 2 * bgInset, height: s - 2 * bgInset)
	let bgRadius = bgRect.width * 0.225
	let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

	// Soft drop shadow under the square (the macOS template ships one in the artwork).
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: rgba(0, 0, 0, 0.35))
	ctx.addPath(bgPath)
	ctx.setFillColor(rgba(0.30, 0.45, 0.95))
	ctx.fillPath()
	ctx.restoreGState()

	// Blue → purple gradient, top-left to bottom-right.
	ctx.saveGState()
	ctx.addPath(bgPath)
	ctx.clip()
	let gradient = CGGradient(
		colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
		colors: [rgba(0.22, 0.56, 1.00), rgba(0.40, 0.40, 0.98), rgba(0.58, 0.27, 0.92)] as CFArray,
		locations: [0, 0.55, 1]
	)!
	ctx.drawLinearGradient(gradient, start: CGPoint(x: bgRect.minX, y: bgRect.maxY), end: CGPoint(x: bgRect.maxX, y: bgRect.minY), options: [])
	// Faint sheen on the upper part for a bit of depth without going glossy.
	let sheen = CGGradient(
		colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
		colors: [rgba(1, 1, 1, 0.16), rgba(1, 1, 1, 0)] as CFArray,
		locations: [0, 1]
	)!
	ctx.drawLinearGradient(sheen, start: CGPoint(x: bgRect.midX, y: bgRect.maxY), end: CGPoint(x: bgRect.midX, y: bgRect.midY), options: [])
	ctx.restoreGState()

	// Folder geometry (fractions of the canvas), centered on the square.
	let folderWidth = s * 0.56
	let bodyHeight = s * 0.36
	let tabHeight = s * 0.07
	let tabWidth = s * 0.24
	let bodyRadius = s * 0.045
	let tabRadius = s * 0.028
	let lipHeight = s * 0.04          // strip of the back plate visible above the front panel
	let totalHeight = bodyHeight + tabHeight
	let x0 = (s - folderWidth) / 2
	let y0 = (s - totalHeight) / 2 - s * 0.01
	let bodyRect = snapped(CGRect(x: x0, y: y0, width: folderWidth, height: bodyHeight), canvas: s)
	let tabRect = snapped(CGRect(x: x0, y: bodyRect.maxY - bodyRadius, width: tabWidth, height: tabHeight + bodyRadius), canvas: s)
	let frontRect = snapped(CGRect(x: x0, y: y0, width: folderWidth, height: bodyHeight - lipHeight), canvas: s)

	// 2×2 grid inside the front panel: square cells with a proportional gap. At ≤64px the layout is done in whole
	// pixels (gap ≥ 1px, uniform cell size, integer origin) so the four cells stay identical and crisp.
	let smallCanvas = s <= 64
	let gridPad = s * 0.045
	var gap = s * 0.03
	var cell = (frontRect.height - 2 * gridPad - gap) / 2
	if smallCanvas {
		gap = max(1, gap.rounded())
		cell = max(1, ((frontRect.height - 2 * gridPad - gap) / 2).rounded(.down))
	}
	let gridWidth = 2 * cell + gap
	var gridX = frontRect.midX - gridWidth / 2
	var gridY = frontRect.midY - gridWidth / 2
	if smallCanvas { gridX = gridX.rounded(); gridY = gridY.rounded() }
	let cellRadius = smallCanvas ? 0 : s * 0.014
	var cells: [CGRect] = []
	for row in 0..<2 {
		for col in 0..<2 {
			cells.append(CGRect(x: gridX + CGFloat(col) * (cell + gap), y: gridY + CGFloat(row) * (cell + gap), width: cell, height: cell))
		}
	}

	// Folder as one transparency layer so the shadow wraps the whole silhouette and the grid holes show the gradient.
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgba(0.05, 0.05, 0.25, 0.30))
	ctx.beginTransparencyLayer(auxiliaryInfo: nil)

	ctx.setFillColor(rgba(1, 1, 1, 0.82))
	ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: tabRadius, cornerHeight: tabRadius, transform: nil))
	ctx.fillPath()
	ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
	ctx.fillPath()

	ctx.setFillColor(rgba(1, 1, 1, 1))
	ctx.addPath(CGPath(roundedRect: frontRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
	ctx.fillPath()

	ctx.setBlendMode(.destinationOut)
	ctx.setFillColor(rgba(0, 0, 0, 1))
	for c in cells {
		ctx.addPath(CGPath(roundedRect: c, cornerWidth: min(cellRadius, c.width / 2), cornerHeight: min(cellRadius, c.height / 2), transform: nil))
		ctx.fillPath()
	}
	ctx.setBlendMode(.normal)

	ctx.endTransparencyLayer()
	ctx.restoreGState()
}

func renderPNG(pixels: Int) throws -> Data {
	let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
	guard let ctx = CGContext(
		data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
		space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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

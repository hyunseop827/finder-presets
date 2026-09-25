import Foundation

public struct Preset: Codable, Identifiable, Equatable, Sendable, Hashable {
	public static let currentSchemaVersion = 1

	public var id: UUID
	public var name: String
	public var settings: ViewSettings
	public var createdAt: Date
	public var updatedAt: Date
	public var schemaVersion: Int

	public init(id: UUID = UUID(), name: String, settings: ViewSettings, createdAt: Date = Date(), updatedAt: Date = Date(), schemaVersion: Int = Preset.currentSchemaVersion) {
		self.id = id
		self.name = name
		self.settings = settings.normalized()   // never store a value that cannot be applied (see ListViewSettings.init(from:))
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.schemaVersion = schemaVersion
	}
}

public enum JSONCoding {
	public static func encoder() -> JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .custom { date, enc in
			var c = enc.singleValueContainer()
			try c.encode(String(format: "%.6f", date.timeIntervalSince1970))
		}
		return encoder
	}

	public static func decoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .custom { dec in
			let c = try dec.singleValueContainer()
			if let s = try? c.decode(String.self), let t = Double(s) { return Date(timeIntervalSince1970: t) }
			return try Date(timeIntervalSince1970: c.decode(Double.self))
		}
		return decoder
	}
}

/// The values a preset's numbers may take when they are typed: what Finder itself offers (icon size 16–512,
/// text size 10–16 in whole points, list icons small or large; grid spacing has no verified range, so Finder's slider
/// 1–100). The app's editor and `finder-presets preset-set` check typed values against them. A value read from a folder that
/// Finder wrote is kept as it is, even outside them.
public enum PresetLimits {
	public static let iconSize: ClosedRange<Double> = 16...512
	public static let textSize: ClosedRange<Double> = 10...16
	public static let gridSpacing: ClosedRange<Double> = 1...100
	public static let listIconSizes: [Double] = [16, 32]
}

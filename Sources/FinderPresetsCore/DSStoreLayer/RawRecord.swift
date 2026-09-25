import Foundation
import DSStore

/// A Codable snapshot of one .DS_Store record value, limited to the value kinds
/// Finder uses for view-settings records (long / type / blob, and ustr for the grouping `GRP0`).
public struct RawRecord: Codable, Sendable {
	/// `string` (a `ustr`, e.g. `GRP0`) is newer than the others: manifests written before it never hold it.
	public enum Kind: String, Codable, Sendable { case uint32, fourCC, data, string, unsupported }

	public let type: String       // four-char record code, e.g. "icvp"
	public let kind: Kind
	public let uint32Value: UInt32?
	public let fourCCValue: String?
	public let dataValue: Data?
	public let stringValue: String?

	public init(type: String, kind: Kind, uint32Value: UInt32? = nil, fourCCValue: String? = nil, dataValue: Data? = nil, stringValue: String? = nil) {
		self.type = type
		self.kind = kind
		self.uint32Value = uint32Value
		self.fourCCValue = fourCCValue
		self.dataValue = dataValue
		self.stringValue = stringValue
	}

	public init(record: DSStore.Record) {
		let type = record.type.fourCC.description
		switch record.value {
		case .uint32(let v): self.init(type: type, kind: .uint32, uint32Value: v)
		case .fourCC(let v): self.init(type: type, kind: .fourCC, fourCCValue: v.description)
		case .data(let d): self.init(type: type, kind: .data, dataValue: d)
		case .propertyList(let p): self.init(type: type, kind: .data, dataValue: (try? p.serialized()) ?? Data())
		case .string(let v): self.init(type: type, kind: .string, stringValue: v)
		default: self.init(type: type, kind: .unsupported)
		}
	}

	/// Parsed plist payload (for `.data` records that hold a property list).
	public var plistObject: NSDictionary? {
		guard kind == .data, let dataValue else { return nil }
		return (try? PropertyListSerialization.propertyList(from: dataValue, options: [], format: nil)) as? NSDictionary
	}

	public func toRecord(filename: String) -> DSStore.Record? {
		guard let code = DSStore.FourCC(type) else { return nil }
		let recordType = DSStore.RecordType(fourCC: code)
		switch kind {
		case .uint32: return uint32Value.map { DSStore.Record(filename: filename, type: recordType, value: .uint32($0)) }
		case .fourCC: return fourCCValue.flatMap { DSStore.FourCC($0) }.map { DSStore.Record(filename: filename, type: recordType, value: .fourCC($0)) }
		case .data: return dataValue.map { DSStore.Record(filename: filename, type: recordType, value: .data($0)) }
		case .string: return stringValue.map { DSStore.Record(filename: filename, type: recordType, value: .string($0)) }
		case .unsupported: return nil
		}
	}
}

/// The records this app manages for one child folder, keyed by record code.
public struct ManagedRecordSet: Codable, Equatable, Sendable, Hashable {
	/// What an apply reads, writes and records (`FinderPresetsOperation.recordCodes`): the view records and the grouping `GRP0`.
	public static let managedCodes: [String] = ["vSrn", "vstl", "icvp", "lsvC", "lsvp", "lsvP", "GRP0"]
	/// What operations recorded before the grouping was managed cover (their manifests have no `recordCodes`). Their undo
	/// reads, compares and restores only these, so a `GRP0` Finder wrote is never removed or counted as a conflict.
	public static let legacyCodes: [String] = ["vSrn", "vstl", "icvp", "lsvC", "lsvp", "lsvP"]

	public var records: [RawRecord]

	public init(records: [RawRecord] = []) {
		self.records = records.sorted { $0.type < $1.type }
	}

	public subscript(code: String) -> RawRecord? { records.first { $0.type == code } }
	public var isEmpty: Bool { records.isEmpty }
}

/// Equality is semantic for plist payloads: Finder and this app may serialize the same dictionary with different key order.
extension RawRecord: Equatable, Hashable {
	public static func == (lhs: RawRecord, rhs: RawRecord) -> Bool {
		guard lhs.type == rhs.type, lhs.kind == rhs.kind else { return false }
		switch lhs.kind {
		case .uint32: return lhs.uint32Value == rhs.uint32Value
		case .fourCC: return lhs.fourCCValue == rhs.fourCCValue
		case .string: return lhs.stringValue == rhs.stringValue
		case .data:
			if let a = lhs.plistObject, let b = rhs.plistObject { return a.isEqual(b) }
			return lhs.dataValue == rhs.dataValue
		case .unsupported: return true
		}
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(type)
		hasher.combine(kind)
	}
}

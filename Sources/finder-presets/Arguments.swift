import Foundation
import FinderPresetsCore

// The argument parsing of `analyze`/`apply` and `preset-set`, apart from main.swift so FinderPresetsCLITests can call it
// without running a command. Nothing here reads the data folder or touches Finder.

/// What `analyze` and `apply` take after the preset name (`--relaunch` is read by `apply` itself).
struct PlanArguments: Equatable {
	var roots: [String] = []
	var depth: Int?
	var pinDefaults = false
}

enum PlanArgumentError: Error, Equatable {
	case badDepth
	case unknown(String)

	var message: String {
		switch self {
		case .badDepth: "--depth 뒤에 0 이상의 정수를 주세요."
		case .unknown(let a): "알 수 없는 인자: \(a)"
		}
	}
}

/// A bad or missing `--depth` value is an error, not "no limit" (nil would write every nested folder), and an unknown
/// `--flag` is an error, not a target folder named after it.
func parsePlanArguments(_ args: [String]) throws(PlanArgumentError) -> PlanArguments {
	var parsed = PlanArguments()
	var it = args.makeIterator()
	while let a = it.next() {
		switch a {
		case "--depth":
			guard let v = it.next().flatMap({ Int($0) }), v >= 0 else { throw .badDepth }
			parsed.depth = v
		case "--pin-defaults": parsed.pinDefaults = true
		case "--relaunch": break
		case _ where a.hasPrefix("--"): throw .unknown(a)
		default: parsed.roots.append(a)
		}
	}
	return parsed
}

/// A `preset-set` argument that is refused; the command then saves nothing.
enum PresetFieldError: Error, Equatable {
	case notAPair(String)
	case unknownKey(String)
	/// `allowed` says what the key takes.
	case badValue(key: String, value: String, allowed: String)

	var message: String {
		switch self {
		case .notAPair(let a): "\(a) 은(는) key=value 형식이 아닙니다"
		case .unknownKey(let k): "알 수 없는 키: \(k)"
		case .badValue(let k, let v, let allowed): "\(k)=\(v) 은(는) 쓸 수 없습니다 (\(allowed))"
		}
	}
}

/// Sets one field from a `preset-set` "key=value". "-" or nothing clears the field (the editor's "유지"); any other value
/// must be one the key takes, so a typo ("viewStyle=Icon", "list.sortAscending=yes") is an error instead of a cleared field.
func setPresetField(_ pair: String, in settings: inout ViewSettings) throws(PresetFieldError) {
	guard let eq = pair.firstIndex(of: "=") else { throw .notAPair(pair) }
	let (k, v) = (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
	let clear = v.isEmpty || v == "-"
	// The case name ("dateModified") or the stored string (Finder's "Date Modified", "icnv").
	func choice<T: CaseIterable & RawRepresentable>(_: T.Type) throws(PresetFieldError) -> T? where T.RawValue == String {
		if clear { return nil }
		guard let c = T.allCases.first(where: { "\($0)" == v }) ?? T(rawValue: v) else {
			throw .badValue(key: k, value: v, allowed: T.allCases.map { "\($0)" }.joined(separator: ", "))
		}
		return c
	}
	func flag() throws(PresetFieldError) -> Bool? {
		if clear { return nil }
		guard let b = Bool(v) else { throw .badValue(key: k, value: v, allowed: "true, false") }
		return b
	}
	// Checked against the app editor's ranges (PresetLimits), but refused rather than clamped as the editor does: a
	// script gets an error instead of a value it did not ask for.
	func measure(in range: ClosedRange<Double>? = nil, of sizes: [Double]? = nil, whole: Bool = false) throws(PresetFieldError) -> Double? {
		if clear { return nil }
		guard let n = Double(v), n.isFinite, range.map({ $0.contains(n) }) ?? true, sizes.map({ $0.contains(n) }) ?? true,
		      !whole || n == n.rounded() else {
			let allowed = range.map { "\(number($0.lowerBound))–\(number($0.upperBound))" }
				?? (sizes ?? []).map { number($0) }.joined(separator: " 또는 ")
			throw .badValue(key: k, value: v, allowed: allowed + (whole ? " 사이의 정수" : ""))
		}
		return n
	}
	switch k {
	case "viewStyle": settings.viewStyle = try choice(ViewStyle.self)
	case "groupBy": settings.groupBy = try choice(GroupBy.self)
	case "icon.iconSize": settings.icon.iconSize = try measure(in: PresetLimits.iconSize)
	case "icon.textSize": settings.icon.textSize = try measure(in: PresetLimits.textSize, whole: true)
	case "icon.gridSpacing": settings.icon.gridSpacing = try measure(in: PresetLimits.gridSpacing)
	case "icon.labelOnBottom": settings.icon.labelOnBottom = try flag()
	case "icon.showItemInfo": settings.icon.showItemInfo = try flag()
	case "icon.showIconPreview": settings.icon.showIconPreview = try flag()
	case "icon.arrangeBy": settings.icon.arrangeBy = try choice(SortKey.self)
	case "list.textSize": settings.list.textSize = try measure(in: PresetLimits.textSize, whole: true)
	case "list.iconSize": settings.list.iconSize = try measure(of: PresetLimits.listIconSizes)
	case "list.sortColumn": settings.list.sortColumn = try choice(ListColumn.self)
	case "list.sortAscending": settings.list.sortAscending = try flag()
	case "list.showIconPreview": settings.list.showIconPreview = try flag()
	case "list.useRelativeDates": settings.list.useRelativeDates = try flag()
	case "list.calculateAllSizes": settings.list.calculateAllSizes = try flag()
	default: throw .unknownKey(k)
	}
}

/// "48", "48.5": only small whole numbers are printed as integers (Int(d) traps beyond Int's range); `fraction` prints
/// the rest.
func number(_ d: Double, fraction: (Double) -> String = { String($0) }) -> String {
	d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : fraction(d)
}

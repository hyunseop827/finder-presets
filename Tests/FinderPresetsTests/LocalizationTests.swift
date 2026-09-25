import Foundation
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// The app's two languages: Resources/ko.lproj and Resources/en.lproj (Localizable.strings keyed by the Korean text, the
/// English plurals in Localizable.stringsdict, InfoPlist.strings, ServicesMenu.strings; Views/Language.swift).
///
/// (a) Every text the Swift compiler extracts from the app's sources — the extraction Xcode runs for a string catalog
///     (`-emit-localized-strings`), so the keys carry the exact format specifiers of their interpolations — has a Korean
///     and an English entry, and every entry is still used. Every Hangul literal in the app is one of those extracted
///     texts, so no Korean text reaches the screen untranslated (a literal that is not a UI text says so with
///     `l10n-exempt` on its line; the debug-only self-test and layout probe log in Korean and are left out).
/// (b) No English text contains Hangul.
/// (c) The format specifiers match between the key, the Korean and the English text (plural rules included), and so do
///     leading and trailing spaces; every English plural formats for one and for many.
/// Also: the status line's tone words agree in both languages for every text, and Info.plist's localizations.
@MainActor @Suite struct LocalizationTests {
	private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
	private static let resources = repository.appendingPathComponent("Resources")
	private static let appSources = repository.appendingPathComponent("Sources/FinderPresets")

	// MARK: Tables

	static func strings(_ lang: String, _ table: String) throws -> [String: String] {
		let data = try Data(contentsOf: resources.appendingPathComponent("\(lang).lproj/\(table).strings"))
		return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
	}

	static func plurals() throws -> [String: [String: Any]] {
		let data = try Data(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.stringsdict"))
		return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]])
	}

	static func hasHangul(_ s: String) -> Bool {
		s.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
	}

	// MARK: Format specifiers

	private static let specifier = try! NSRegularExpression(
		pattern: #"%#@([A-Za-z0-9_]+)@|%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaAF%])"#)

	/// The arguments a format takes, by position: "%@ %lld개" → [1: "@", 2: "lld"]. `variables`: the types of the
	/// stringsdict variables a `%#@name@` stands for. Nil when a position is used with two types.
	static func arguments(_ format: String, variables: [String: String] = [:]) -> [Int: String]? {
		var result: [Int: String] = [:]
		var next = 1
		let ns = format as NSString
		for m in specifier.matches(in: format, range: NSRange(location: 0, length: ns.length)) {
			func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
			let type: String
			let position: Int
			if let variable = group(1) {
				guard let t = variables[variable] else { return nil }
				type = t
				position = next
				next += 1
			} else {
				guard let conversion = group(4), conversion != "%" else { continue }
				type = (group(3) ?? "") + conversion
				if let explicit = group(2).flatMap(Int.init) { position = explicit } else { position = next; next += 1 }
			}
			if let known = result[position], known != type { return nil }
			result[position] = type
		}
		return result
	}

	/// A stringsdict entry's format with every variable replaced by its text for `category` ("one", "other", …).
	static func render(_ entry: [String: Any], _ category: String) -> String {
		var format = entry["NSStringLocalizedFormatKey"] as? String ?? ""
		for (name, value) in entry where name != "NSStringLocalizedFormatKey" {
			guard let rule = value as? [String: String] else { continue }
			format = format.replacingOccurrences(of: "%#@\(name)@", with: rule[category] ?? rule["other"] ?? "")
		}
		return format
	}

	// MARK: (b), (c): the tables themselves

	@Test func tablesHaveTheSameTextsInBothLanguages() throws {
		let ko = try Self.strings("ko", "Localizable"), en = try Self.strings("en", "Localizable"), plural = try Self.plurals()
		#expect(!ko.isEmpty)
		#expect(Set(en.keys).isDisjoint(with: plural.keys), "a text is both in Localizable.strings and in the stringsdict")
		let english = Set(en.keys).union(plural.keys)
		#expect(Set(ko.keys) == english, "only Korean: \(Set(ko.keys).subtracting(english).sorted().prefix(5)); only English: \(english.subtracting(ko.keys).sorted().prefix(5))")
	}

	@Test func englishHasNoHangulAndKeepsTheSpecifiers() throws {
		let ko = try Self.strings("ko", "Localizable"), en = try Self.strings("en", "Localizable")
		for (key, value) in en {
			#expect(!Self.hasHangul(value), "Hangul in English: \(key) = \(value)")
			#expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty English: \(key)")
			let expected = Self.arguments(key)
			#expect(expected != nil && Self.arguments(value) == expected, "specifiers: \(key) → \(value)")
			#expect(key.first?.isWhitespace == value.first?.isWhitespace && key.last?.isWhitespace == value.last?.isWhitespace,
			        "leading/trailing space: \(key) → \(value)")
		}
		for (key, value) in ko {
			#expect(Self.arguments(value) == Self.arguments(key), "specifiers (ko): \(key) → \(value)")
			#expect(!value.isEmpty && key.first?.isWhitespace == value.first?.isWhitespace && key.last?.isWhitespace == value.last?.isWhitespace,
			        "leading/trailing space (ko): \(key) → \(value)")
		}
	}

	@Test func englishPluralsAreWellFormedAndFormat() throws {
		let plural = try Self.plurals()
		let bundle = try #require(Bundle(url: Self.resources.appendingPathComponent("en.lproj")))
		#expect(!plural.isEmpty)
		for (key, entry) in plural {
			let format = try #require(entry["NSStringLocalizedFormatKey"] as? String, "\(key): no NSStringLocalizedFormatKey")
			var types: [String: String] = [:]
			for (name, value) in entry where name != "NSStringLocalizedFormatKey" {
				let rule = try #require(value as? [String: String], "\(key): \(name) is not a rule")
				#expect(rule["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType" && rule["other"] != nil && rule["one"] != nil, "\(key): \(name)")
				let type = try #require(rule["NSStringFormatValueTypeKey"], "\(key): \(name) has no value type")
				types[name] = type
				// A variant names its own number at most once, with the variable's type (or leaves it out, like "the folder").
				for (category, text) in rule where !category.hasPrefix("NSString") {
					let own = Self.arguments(text) ?? [:]
					#expect(own.count <= 1 && own.values.allSatisfy { $0 == type }, "\(key): \(name).\(category) = \(text)")
					#expect(!Self.hasHangul(text), "Hangul in English: \(key): \(text)")
				}
				#expect(format.contains("%#@\(name)@"), "\(key): \(name) is not used")
			}
			#expect(!Self.hasHangul(format), "Hangul in English: \(key)")
			let expected = try #require(Self.arguments(key))
			#expect(Self.arguments(format, variables: types) == expected, "specifiers: \(key) → \(format)")
			for category in ["one", "other"] {
				let text = Self.render(entry, category)
				#expect(key.first?.isWhitespace == text.first?.isWhitespace && key.last?.isWhitespace == text.last?.isWhitespace, "spaces: \(key)")
			}
			// Formatted the way the app does it (the bundle's format, then the arguments): one and many read differently.
			let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
			func formatted(_ count: Int) -> String {
				let args: [CVarArg] = expected.keys.sorted().map { expected[$0] == "@" ? ("X" as NSString) as CVarArg : count as CVarArg }
				return String(format: localized, locale: Locale(identifier: "en"), arguments: args)
			}
			let one = formatted(1), many = formatted(2)
			#expect(one != many && !one.contains("%") && !many.contains("%") && !Self.hasHangul(one + many), "\(key): \(one) / \(many)")
		}
		#expect(String(format: bundle.localizedString(forKey: "폴더 %lld개", value: nil, table: nil), locale: Locale(identifier: "en"), 1) == "1 folder")
		#expect(String(format: bundle.localizedString(forKey: "폴더 %lld개", value: nil, table: nil), locale: Locale(identifier: "en"), 3) == "3 folders")
	}

	/// The status line's icon (StatusBar.tone) comes from words in the text: every translated text must give the same
	/// tone as its Korean text, so a line composed of them does too.
	@Test func statusToneIsTheSameInBothLanguages() throws {
		let ko = try Self.strings("ko", "Localizable"), en = try Self.strings("en", "Localizable"), plural = try Self.plurals()
		func tone(_ s: String) -> StatusBar.Tone { StatusBar.tone(status: s, working: false) }
		for (key, korean) in ko {
			let english = en[key].map { [$0] } ?? plural[key].map { entry in ["one", "other"].map { Self.render(entry, $0) } } ?? []
			for text in english {
				#expect(tone(korean) == tone(text), "tone: \(korean) (\(tone(korean))) → \(text) (\(tone(text)))")
			}
		}
	}

	@Test func infoPlistIsLocalized() throws {
		let data = try Data(contentsOf: Self.resources.appendingPathComponent("Info.plist"))
		let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		#expect(plist["CFBundleDevelopmentRegion"] as? String == "ko")
		#expect(plist["CFBundleLocalizations"] as? [String] == ["ko", "en"])
		let usage = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
		#expect(usage.count >= 7)
		let ko = try Self.strings("ko", "InfoPlist"), en = try Self.strings("en", "InfoPlist")
		#expect(Set(ko.keys) == Set(usage) && Set(en.keys) == Set(usage))
		for key in usage {
			#expect(ko[key] == plist[key] as? String, "ko \(key)")
			#expect(en[key].map { !$0.isEmpty && !Self.hasHangul($0) } == true, "en \(key)")
		}
	}

	@Test func wordsAroundAnArgument() {
		#expect(AppLanguage.around(AppLanguage.slot + "의 지정을 따릅니다") == ("", "의 지정을 따릅니다"))
		#expect(AppLanguage.around("Follows " + AppLanguage.slot) == ("Follows ", ""))
		#expect(AppLanguage.around("no slot") == ("no slot", ""))
		// Outside the app bundle every text is its Korean key, formatted.
		#expect(String(localized: "\(AppLanguage.slot)의 지정을 따릅니다") == AppLanguage.slot + "의 지정을 따릅니다")
		#expect(ErrorText.describe(LocatorError.rootFolder) == "루트 디렉터리에는 적용할 수 없습니다.")
		#expect(ErrorText.describe(StoreEditorError.writeFailed("x")) == "설정 파일 쓰기 실패: x")
		let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
		#expect(ErrorText.describe(other) == other.localizedDescription)
	}

	/// The core's errors and values the app shows carry no display text of their own (the core's texts are Korean, for
	/// `finder-presets`): what a verification that failed read back, why a parent `.DS_Store` could not be read, a backup that did
	/// not match — only names, values, paths and system messages, worded by the app (`ErrorText`, `HistoryText`).
	@Test func coreValuesTheAppShowsHoldNoKoreanText() throws {
		let diffs = ViewSettings().differences(to: ViewSettings(viewStyle: .list, icon: IconViewSettings(iconSize: 64, arrangeBy: .kind),
		                                                        list: ListViewSettings(sortColumn: .name, sortAscending: false, useRelativeDates: true)))
		#expect(diffs.count == 6 && diffs.allSatisfy { $0.current == nil })
		for d in diffs { #expect(!Self.hasHangul(d.field + (d.current ?? "") + d.target), "\(d)") }
		// In the app, "not set" is the app's own word (Korean here, outside the app bundle; English in en.lproj).
		#expect(ErrorText.differences(diffs).contains(String(localized: "미설정")))
		#expect(ErrorText.differences([]) == String(localized: "기록한 값과 다릅니다"))
		let verification = ErrorText.describe(GlobalApplyError.verificationFailed(operationID: UUID(), diffs: diffs))
		#expect(verification.contains("icon.iconSize") && !verification.contains("적용 후 되읽은 값이 다릅니다 (작업"))

		// A parent .DS_Store that cannot be read: the reason is the library's, never a Korean sentence of the core.
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-l10n-store-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let store = folder.appendingPathComponent(".DS_Store")
		try Data("not a .DS_Store".utf8).write(to: store)
		do {
			_ = try StoreEditor.managedRecords(at: store, key: "X")
			Issue.record("a damaged .DS_Store was read")
		} catch StoreEditorError.unreadable(let detail) {
			#expect(!detail.isEmpty && !Self.hasHangul(detail), "\(detail)")
		}
		let entry = OperationEntry(folderPath: folder.appendingPathComponent("X").path, storePath: store.path, key: "X",
		                           before: nil, after: ManagedRecordSet(), status: .changed)
		let appData = folder.appendingPathComponent("data")
		let preview = UndoService(operations: OperationStore(dirs: AppDirectories(root: appData)))
			.preview(FinderPresetsOperation(kind: .apply, roots: [folder.path], entries: [entry]))
		#expect(preview.unreadable.count == 1 && !Self.hasHangul(preview.unreadable.first?.unreadable ?? "한"))
		#expect(ErrorText.describe(StoreEditorError.backupMismatch("/x/.DS_Store")).hasSuffix("/x/.DS_Store"))
	}

	// MARK: (a): what the compiler extracts from the sources

	struct Extracted {
		struct Entry { var key: String; var line: Int?; var column: Int? }
		/// By the source file's last path component.
		var entries: [String: [Entry]] = [:]
		var keys: Set<String> { Set(entries.values.flatMap { $0.map(\.key) }) }
	}

	/// Compiles the app's sources once more (debug, like `swift test`) with `-emit-localized-strings` into a temporary
	/// folder, against the modules this test was built with, and reads the `.stringsdata` files.
	static func extract() throws -> Extracted {
		final class Marker {}
		let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
		let fm = FileManager.default
		guard let modules = [products, products.appendingPathComponent("Modules")].first(where: {
			fm.fileExists(atPath: $0.appendingPathComponent("FinderPresetsCore.swiftmodule").path)
		}) else {
			throw Failure("FinderPresetsCore.swiftmodule not found next to the test bundle (\(products.path))")
		}
		let out = fm.temporaryDirectory.appendingPathComponent("finder-presets-l10n-\(UUID().uuidString)")
		try fm.createDirectory(at: out, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: out) }
		let sources = try swiftFiles(in: appSources).map(\.path)
		#if arch(arm64)
		let arch = "arm64"
		#else
		let arch = "x86_64"
		#endif
		var arguments = ["swiftc", "-c", "-parse-as-library", "-D", "DEBUG", "-swift-version", "6", "-module-name", "FinderPresets",
		                 "-target", "\(arch)-apple-macosx14.0", "-sdk", try run(["--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines),
		                 "-I", modules.path, "-wmo", "-Onone", "-o", out.appendingPathComponent("app.o").path,
		                 "-emit-localized-strings", "-emit-localized-strings-path", out.path]
		// Command Line Tools only (scripts/toolchain.sh): SwiftUI's macro plugin comes from Xcode.
		let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
		if developer.hasPrefix("/Library/Developer/CommandLineTools") {
			for plugins in ["/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins",
			                developer + "/usr/lib/swift/host/plugins/testing"] where fm.fileExists(atPath: plugins) {
				arguments += ["-plugin-path", plugins]
			}
		}
		_ = try run(arguments + sources)
		var extracted = Extracted()
		for file in try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil) where file.pathExtension == "stringsdata" {
			let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
			let source = URL(fileURLWithPath: json["source"] as? String ?? file.deletingPathExtension().lastPathComponent + ".swift").lastPathComponent
			let tables = json["tables"] as? [String: [[String: Any]]] ?? [:]
			#expect(Set(tables.keys).isSubset(of: ["Localizable"]), "\(source): other tables \(tables.keys.sorted())")
			for item in tables["Localizable"] ?? [] {
				let location = item["location"] as? [String: Int]
				extracted.entries[source, default: []].append(.init(key: item["key"] as? String ?? "", line: location?["startingLine"],
				                                                    column: location?["startingColumn"]))
			}
		}
		#expect(!extracted.entries.isEmpty)
		return extracted
	}

	struct Failure: Error, CustomStringConvertible {
		var description: String
		init(_ description: String) { self.description = description }
	}

	/// Runs `xcrun <arguments>` (the toolchain scripts/test.sh chose, through DEVELOPER_DIR) and returns its output.
	static func run(_ arguments: [String]) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
		process.arguments = arguments
		let output = Pipe(), errors = Pipe()
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		let out = output.fileHandleForReading.readDataToEndOfFile()
		let err = errors.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw Failure("xcrun \(arguments.prefix(3).joined(separator: " ")) … failed (\(process.terminationStatus)): "
				+ String(decoding: err, as: UTF8.self).split(separator: "\n").filter { $0.contains("error") }.prefix(10).joined(separator: "\n"))
		}
		return String(decoding: out, as: UTF8.self)
	}

	static func swiftFiles(in folder: URL) throws -> [URL] {
		let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
		return items.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
	}

	@Test func everyExtractedTextIsTranslatedAndEveryKoreanLiteralIsLocalized() throws {
		let extracted = try Self.extract()
		let ko = try Self.strings("ko", "Localizable"), en = try Self.strings("en", "Localizable"), plural = try Self.plurals()
		let korean = extracted.keys.filter(Self.hasHangul)
		#expect(korean.count > 100)
		for key in korean.sorted() {
			#expect(ko[key] != nil, "no Korean entry: \(key)")
			#expect(en[key] != nil || plural[key] != nil, "no English entry: \(key)")
		}
		// Every entry is still used by the app.
		for key in Set(ko.keys).subtracting(extracted.keys).sorted() {
			Issue.record("unused text in ko.lproj/Localizable.strings: \(key)")
		}
		// Every Hangul literal of the app is one of the extracted (localized) texts.
		let skipped: Set<String> = ["SelfTest.swift", "LayoutProbe.swift"]   // debug-only hooks; they log in Korean
		var checked = 0
		for file in try Self.swiftFiles(in: Self.appSources) where !skipped.contains(file.lastPathComponent) {
			let source = try String(contentsOf: file, encoding: .utf8)
			let entries = extracted.entries[file.lastPathComponent] ?? []
			let located = Set(entries.compactMap { e in e.line.flatMap { l in e.column.map { "\(l):\($0)" } } })
			let unlocated = Set(entries.filter { $0.line == nil }.map(\.key))
			for literal in SwiftLiterals.scan(source) where Self.hasHangul(literal.text) && !literal.exempt {
				checked += 1
				let found = located.contains("\(literal.line):\(literal.column)") || (!literal.interpolated && unlocated.contains(literal.text))
				#expect(found, "\(file.lastPathComponent):\(literal.line):\(literal.column): Korean text that is not localized: \(literal.text)")
			}
		}
		#expect(checked > 100)
	}

	/// The lexer below on the forms the app uses.
	@Test func literalScanner() {
		let source = """
		// "주석" is skipped
		let a = "가나 \\(n)개 \\("내부") 끝" /* "블록" */ ; let b = "x\\"y"
		let c = "다"   // l10n-exempt
		"""
		let found = SwiftLiterals.scan(source)
		#expect(found.map(\.text) == ["가나 \u{FFFC}개 \u{FFFC} 끝", "내부", "x\"y", "다"])
		#expect(found[0].interpolated && !found[2].interpolated && found[3].exempt && !found[0].exempt)
		#expect(found[0].line == 2 && found[0].column == 9 && found[3].line == 3)
	}
}

/// String literals of Swift source (outside comments), with their line and UTF-8 column (1-based, the compiler's
/// convention in `.stringsdata`). An interpolation stands as U+FFFC in `text`; literals inside it are listed as well.
enum SwiftLiterals {
	struct Literal {
		var text: String
		var interpolated: Bool
		var line: Int
		var column: Int
		/// Its line carries `l10n-exempt`: not a text for the screen (e.g. the status line's tone words).
		var exempt: Bool
	}

	static func scan(_ source: String) -> [Literal] {
		let s = Array(source.utf8)
		var result: [Literal] = []
		var i = 0, line = 1, lineStart = 0
		func lineText(_ start: Int) -> String {
			var end = start
			while end < s.count && s[end] != 0x0A { end += 1 }
			return String(decoding: s[start..<end], as: UTF8.self)
		}
		/// Parses the literal at `i` (a `"` or the `#`s of a raw string); returns the index after it.
		func literal(at start: Int) -> Int {
			let startLine = line, column = start - lineStart + 1, currentLineStart = lineStart
			var j = start, hashes = 0
			while s[j] == UInt8(ascii: "#") { hashes += 1; j += 1 }
			let triple = j + 2 < s.count && s[j + 1] == UInt8(ascii: "\"") && s[j + 2] == UInt8(ascii: "\"")
			j += triple ? 3 : 1
			var bytes: [UInt8] = []
			var interpolated = false
			func closes(_ k: Int) -> Bool {
				let quotes = triple ? 3 : 1
				guard k + quotes + hashes <= s.count else { return false }
				for q in 0..<quotes where s[k + q] != UInt8(ascii: "\"") { return false }
				for h in 0..<hashes where s[k + quotes + h] != UInt8(ascii: "#") { return false }
				return true
			}
			while j < s.count {
				if closes(j) { j += (triple ? 3 : 1) + hashes; break }
				if s[j] == UInt8(ascii: "\\") && (0..<hashes).allSatisfy({ j + 1 + $0 < s.count && s[j + 1 + $0] == UInt8(ascii: "#") }) {
					var k = j + 1 + hashes
					let c = s[k]
					if c == UInt8(ascii: "(") {
						interpolated = true
						bytes += Array("\u{FFFC}".utf8)
						var depth = 1
						k += 1
						while k < s.count && depth > 0 {
							let d = s[k]
							if d == UInt8(ascii: "\"") || (d == UInt8(ascii: "#") && k + 1 < s.count && (s[k + 1] == UInt8(ascii: "\"") || s[k + 1] == UInt8(ascii: "#"))) {
								k = literal(at: k)
								continue
							}
							if d == UInt8(ascii: "(") { depth += 1 } else if d == UInt8(ascii: ")") { depth -= 1 }
							if d == 0x0A { line += 1; lineStart = k + 1 }
							k += 1
						}
						j = k
						continue
					}
					switch c {
					case UInt8(ascii: "n"): bytes.append(0x0A)
					case UInt8(ascii: "t"): bytes.append(0x09)
					case UInt8(ascii: "r"): bytes.append(0x0D)
					case UInt8(ascii: "0"): bytes.append(0x00)
					case UInt8(ascii: "u"):
						var end = k + 2
						while end < s.count && s[end] != UInt8(ascii: "}") { end += 1 }
						let hex = String(decoding: s[(k + 2)..<end], as: UTF8.self)
						if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { bytes += Array(String(scalar).utf8) }
						k = end
					default: bytes.append(c)   // \" \\ \'
					}
					j = k + 1
					continue
				}
				if s[j] == 0x0A { line += 1; lineStart = j + 1 }
				bytes.append(s[j])
				j += 1
			}
			result.append(Literal(text: String(decoding: bytes, as: UTF8.self), interpolated: interpolated, line: startLine, column: column,
			                      exempt: lineText(currentLineStart).contains("l10n-exempt")))
			return j
		}
		while i < s.count {
			let c = s[i]
			if c == 0x0A { line += 1; lineStart = i + 1; i += 1; continue }
			if c == UInt8(ascii: "/") && i + 1 < s.count && s[i + 1] == UInt8(ascii: "/") {
				while i < s.count && s[i] != 0x0A { i += 1 }
				continue
			}
			if c == UInt8(ascii: "/") && i + 1 < s.count && s[i + 1] == UInt8(ascii: "*") {
				var depth = 1
				i += 2
				while i < s.count && depth > 0 {
					if s[i] == UInt8(ascii: "/") && i + 1 < s.count && s[i + 1] == UInt8(ascii: "*") { depth += 1; i += 2; continue }
					if s[i] == UInt8(ascii: "*") && i + 1 < s.count && s[i + 1] == UInt8(ascii: "/") { depth -= 1; i += 2; continue }
					if s[i] == 0x0A { line += 1; lineStart = i + 1 }
					i += 1
				}
				continue
			}
			if c == UInt8(ascii: "\"") || (c == UInt8(ascii: "#") && i + 1 < s.count && (s[i + 1] == UInt8(ascii: "\"") || s[i + 1] == UInt8(ascii: "#"))) {
				i = literal(at: i)
				continue
			}
			i += 1
		}
		return result.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
	}
}

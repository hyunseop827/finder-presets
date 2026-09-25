import Foundation
import AppKit
import Testing
import FinderPresetsCore
@testable import FinderPresets

/// The Finder services outside the app: what a request's items count as (folders once, in order; everything else
/// ignored), how folders join the list, when the apply service opens its confirmation, and that Info.plist, the provider
/// and the translations (Resources/<lang>.lproj/ServicesMenu.strings) name the same four services (the quick preset's
/// decisions: QuickPresetTests). Temporary folders
/// only; a private pasteboard that is released again. No AppModel is created here (it would open the default data folder).
@MainActor @Suite struct FinderServicesTests {
	/// A temporary tree: folders A, B and 가나다 (named in NFC), the file f.txt; removed by the caller.
	private static func makeTree() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("finder-presets-services-\(UUID().uuidString)")
		for name in ["A", "B", "가나다"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		try Data("hi".utf8).write(to: root.appendingPathComponent("f.txt"))
		return root
	}

	/// Folders stay in their order and count once — also spelled with a trailing slash, "/./", in NFD or with a
	/// "localhost" host. Files, missing items and web links are ignored by name; text items are counted.
	@Test func sortsFoldersFromEverythingElse() throws {
		let root = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
		let hangul = root.appendingPathComponent("가나다")
		let nfd = URL(fileURLWithPath: root.path + "/" + "가나다".decomposedStringWithCanonicalMapping)
		let urls: [URL] = [
			a,
			root.appendingPathComponent("f.txt"),
			URL(fileURLWithPath: a.path + "/"),
			root.appendingPathComponent("missing"),
			URL(string: "https://example.com/Applications")!,
			hangul,
			b,
			URL(fileURLWithPath: root.path + "/./A"),
			nfd,
			try #require(URL(string: "file://localhost" + b.path))
		]
		let items = ServiceItems.sort(urls, textItems: 2)
		#expect(items.folders.map(\.path) == [a.path, hangul.path, b.path].map(FolderRule.normalize))
		#expect(items.ignored == ["f.txt", "missing", "https://example.com/Applications", "텍스트 2개"])
		#expect(items.duplicates == 4)
		// Nothing at all, or nothing but text.
		#expect(ServiceItems.sort([]) == ServiceItems())
		#expect(ServiceItems.sort([], textItems: 1).folders.isEmpty && ServiceItems.sort([], textItems: 1).ignored.count == 1)
	}

	/// A file reference URL (file:///.file/id=…, what some senders write) counts as its folder's path: the same folder
	/// sent both ways counts once, and a reference to a file is ignored by the file's name.
	@Test func fileReferenceURLsCountAsTheirPaths() throws {
		let tree = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: tree) }
		// The reference resolves to the real path (/private/var/…, not the /var/… symlink the temporary folder is named by).
		let root = URL(fileURLWithPath: try #require(realpath(tree.path, nil).map { p in defer { free(p) }; return String(cString: p) }))
		let a = root.appendingPathComponent("A"), file = root.appendingPathComponent("f.txt")
		func reference(_ url: URL) throws -> URL {
			let ref = try #require(CFURLCreateFileReferenceURL(nil, url as CFURL, nil)?.takeRetainedValue())
			let string = CFURLGetString(ref) as String
			#expect(string.hasPrefix("file:///.file/id="), "\(string)")
			return try #require(URL(string: string))
		}
		let items = ServiceItems.sort([try reference(a), a, try reference(file)])
		#expect(items.folders.map(\.path) == [FolderRule.normalize(a.path)])
		#expect(items.duplicates == 1 && items.ignored == ["f.txt"])
	}

	/// What Finder puts on a service's pasteboard: one item per selected folder carrying its file URL and its path as text.
	/// Such an item is a folder, not a text item; an item that holds only text is counted as text.
	@Test func finderStyleItemsAreNotCountedAsText() throws {
		let root = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
		let pb = NSPasteboard(name: NSPasteboard.Name("com.hyunseop.FinderPresets.tests-\(UUID().uuidString)"))
		defer { pb.releaseGlobally() }
		pb.clearContents()
		let items = [a, b].map { url -> NSPasteboardItem in
			let item = NSPasteboardItem()
			item.setString(url.absoluteString, forType: .fileURL)
			item.setString(url.path, forType: .string)
			return item
		}
		let text = NSPasteboardItem()
		text.setString("notes", forType: .string)
		#expect(pb.writeObjects(items + [text]))
		let read = ServiceItems.read(pb)
		#expect(read.folders.map(\.path) == [a.path, b.path].map(FolderRule.normalize))
		#expect(read.ignored == ["텍스트 1개"] && read.duplicates == 0)
	}

	/// What Finder (and other senders) put on the service's pasteboard: file URLs, web links and text items, or the older
	/// list of paths.
	@Test func readsTheServicePasteboard() throws {
		let root = try Self.makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
		let pb = NSPasteboard(name: NSPasteboard.Name("com.hyunseop.FinderPresets.tests-\(UUID().uuidString)"))
		defer { pb.releaseGlobally() }

		pb.clearContents()
		let objects: [NSPasteboardWriting] = [a as NSURL, root.appendingPathComponent("f.txt") as NSURL, URL(string: "https://example.com/x")! as NSURL,
		                                      "plain text" as NSString, b as NSURL, a as NSURL]
		#expect(pb.writeObjects(objects))
		let items = ServiceItems.read(pb)
		#expect(items.folders.map(\.path) == [a.path, b.path].map(FolderRule.normalize))
		#expect(items.ignored == ["f.txt", "https://example.com/x", "텍스트 1개"])
		#expect(items.duplicates == 1)

		// Only text: nothing to act on.
		pb.clearContents()
		#expect(pb.writeObjects(["/Users" as NSString]))
		let text = ServiceItems.read(pb)
		#expect(text.folders.isEmpty && text.ignored == ["텍스트 1개"])

		// The older list of paths (NSFilenamesPboardType).
		pb.clearContents()
		pb.declareTypes([ServiceItems.filenamesType], owner: nil)
		#expect(pb.setPropertyList([b.path, a.path, root.appendingPathComponent("f.txt").path], forType: ServiceItems.filenamesType))
		let legacy = ServiceItems.read(pb)
		#expect(legacy.folders.map(\.path) == [b.path, a.path].map(FolderRule.normalize))
		#expect(legacy.ignored == ["f.txt"])
	}

	/// A drop, "폴더 추가…" and the services add each folder once, keep the ones already listed, refuse the home folder
	/// and the folders above it, and name what is not a folder.
	@Test func folderAdditionAddsEachFolderOnce() {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let listed = ["/tmp/finder-presets/X"]
		let folders: Set<String> = ["/tmp/finder-presets/A", "/tmp/finder-presets/X", "/tmp/finder-presets/C", home.path, "/", home.deletingLastPathComponent().path]
		let urls = [
			URL(fileURLWithPath: "/tmp/finder-presets/A"), URL(fileURLWithPath: "/tmp/finder-presets/X/"), URL(fileURLWithPath: "/tmp/finder-presets/./A"),
			home, URL(fileURLWithPath: "/"), home.deletingLastPathComponent(),
			URL(fileURLWithPath: "/tmp/finder-presets/file.txt"), URL(string: "https://example.com/tmp/finder-presets/A")!, URL(fileURLWithPath: "/tmp/finder-presets/C")
		]
		let r = AppModel.folderAddition(urls, listed: listed) { $0.isFileURL && folders.contains(FolderRule.normalize($0.path)) }
		#expect(r.added == ["/tmp/finder-presets/A", "/tmp/finder-presets/C"])
		#expect(r.alreadyListed == ["/tmp/finder-presets/X"])
		#expect(r.inList == ["/tmp/finder-presets/A", "/tmp/finder-presets/X", "/tmp/finder-presets/C"])
		#expect(r.refused == ["~", "/", Fmt.abbreviate(home.deletingLastPathComponent().path)])
		#expect(r.notFolders == ["file.txt", "https://example.com/tmp/finder-presets/A"])
		// Nothing new: everything already listed.
		let again = AppModel.folderAddition([URL(fileURLWithPath: "/tmp/finder-presets/X")], listed: listed) { _ in true }
		#expect(again.added.isEmpty && again.alreadyListed == ["/tmp/finder-presets/X"] && again.inList == ["/tmp/finder-presets/X"])
	}

	/// The status line after "…에 폴더 추가": added, already listed, refused.
	@Test func additionNote() {
		// The names are set apart (Fmt.name) so they never decide the status line's tone.
		let (new, old, home) = (Fmt.name("New"), Fmt.name("Old"), Fmt.name("~"))
		var r = FolderAddition(added: ["/a/New"], alreadyListed: ["/a/Old"], inList: ["/a/New", "/a/Old"], refused: ["~"])
		#expect(AppModel.additionNote(r) == "Finder에서 폴더 1개를 목록에 추가했습니다: \(new) · 이미 목록에 있음: \(old) · 홈 폴더나 그 상위 폴더라 넣지 않음: \(home)")
		r = FolderAddition(alreadyListed: ["/a/Old"], inList: ["/a/Old"])
		#expect(AppModel.additionNote(r) == "이미 목록에 있는 폴더입니다: \(old)")
		r = FolderAddition(refused: ["~"])
		#expect(AppModel.additionNote(r) == "폴더를 목록에 추가하지 않았습니다. · 홈 폴더나 그 상위 폴더라 넣지 않음: \(home)")
		#expect(StatusBar.withoutNames(AppModel.additionNote(FolderAddition(added: ["/a/실패"], inList: ["/a/실패"]))) == "Finder에서 폴더 1개를 목록에 추가했습니다: ")
	}

	/// The apply service opens its confirmation only while nothing else runs or asks.
	@Test func applyServiceWaitsForOtherTasksAndDialogs() {
		#expect(AppModel.applyServiceBlocker(isWorking: false, dialogOpen: false) == nil)
		#expect(AppModel.applyServiceBlocker(isWorking: true, dialogOpen: false) != nil)
		#expect(AppModel.applyServiceBlocker(isWorking: false, dialogOpen: true) != nil)
		#expect(AppModel.applyServiceBlocker(isWorking: true, dialogOpen: true) == AppModel.applyServiceBlocker(isWorking: true, dialogOpen: false))
	}

	private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

	/// Info.plist declares exactly the four services, enabled by default (an empty NSRequiredContext), with the English
	/// default titles: the three of the right-click menu for folders only, the quick preset with no send types at all (so
	/// it is offered in every app and its shortcut works anywhere) and no key equivalent of its own. The provider answers
	/// each NSMessage.
	@Test func infoPlistDeclaresTheServices() throws {
		let data = try Data(contentsOf: Self.repository.appendingPathComponent("Resources/Info.plist"))
		let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		let services = try #require(plist["NSServices"] as? [[String: Any]])
		#expect(services.count == FinderService.allCases.count)
		for (entry, service) in zip(services, FinderService.allCases) {
			#expect(entry["NSMessage"] as? String == service.message)
			#expect((entry["NSMenuItem"] as? [String: String]) == ["default": service.englishTitle])
			#expect(entry["NSSendFileTypes"] as? [String] == service.sendFileTypes)
			#expect((service == .quickApply) == (service.sendFileTypes == nil))
			#expect((entry["NSMenuItem"] as? [String: String])?["keyEquivalent"] == nil && entry["NSKeyEquivalent"] == nil)
			#expect((entry["NSRequiredContext"] as? [String: Any])?.isEmpty == true)
			#expect(entry["NSSendTypes"] == nil && entry["NSReturnTypes"] == nil && entry["NSPortName"] == nil)
			#expect(FinderServiceProvider.instancesRespond(to: NSSelectorFromString("\(service.message):userData:error:")), "\(service.message)")
		}
		#expect(Set(FinderService.allCases.map(\.message)).count == 4 && Set(FinderService.allCases.map(\.englishTitle)).count == 4)
		#expect(FinderService.quickApply.message == "applyQuickPreset" && FinderService.quickApply.englishTitle == "Apply Quick Preset to Front Finder Window")
	}

	/// Both languages translate every title (ServicesMenu.strings in Resources/en.lproj and ko.lproj, which build-app.sh
	/// copies into the bundle): English keeps the default title, Korean has its own, and the apply service ends with "…"
	/// in both (it opens a confirmation). Outside the app bundle the title Finder shows is the English default.
	@Test func everyTitleIsTranslated() throws {
		func table(_ lang: String) throws -> [String: String] {
			let data = try Data(contentsOf: Self.repository.appendingPathComponent("Resources/\(lang).lproj/ServicesMenu.strings"))
			return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
		}
		let en = try table("en"), ko = try table("ko")
		#expect(Set(en.keys) == Set(FinderService.allCases.map(\.englishTitle)) && Set(ko.keys) == Set(en.keys))
		for service in FinderService.allCases {
			#expect(en[service.englishTitle] == service.englishTitle, "en: \(service.englishTitle)")
			let korean = try #require(ko[service.englishTitle])
			#expect(korean != service.englishTitle && korean.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "ko: \(korean)")
			#expect(service.localizedTitle == service.englishTitle)
		}
		#expect(ko[FinderService.apply.englishTitle]?.hasSuffix("…") == true && FinderService.apply.englishTitle.hasSuffix("…"))
		// The quick preset asks nothing before it applies: no "…". The Korean title is the one the guide and the Settings
		// window tell the user to look for in System Settings.
		#expect(ko[FinderService.quickApply.englishTitle] == "빠른 프리셋을 앞 Finder 창에 적용" && !FinderService.quickApply.englishTitle.hasSuffix("…"))
	}
}

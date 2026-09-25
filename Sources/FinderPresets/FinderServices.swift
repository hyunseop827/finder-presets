import Foundation
import AppKit
import FinderPresetsCore

// Finder's right-click menu for folders (서비스 ▸): three macOS services (Info.plist `NSServices`, answered by
// `FinderServiceProvider`; no Finder Sync extension, nothing runs in the background). Finder puts the selected folders on
// a pasteboard and macOS hands it to the running app, or launches the app first when it is not running. A fourth service,
// the quick preset (QuickPreset.swift), takes nothing from the pasteboard: it is there for its keyboard shortcut.
//
// 1. "Finder Presets에 폴더 추가": the folders join "2. 적용할 폴더" (like a drop on the list).
// 2. "Finder Presets로 프리셋 만들기": one preset per folder from its current view settings (like a drop on the
//    preset list); the last one is selected.
// 3. "Finder Presets로 적용…": the folders join the list, exactly their rows are selected, and the apply
//    confirmation opens for them ("선택한 폴더에 적용…": each folder's own preset, else the one selected on the left).
//    Nothing is written before "적용" there.
// 4. "빠른 프리셋을 앞 Finder 창에 적용": the starred preset on the front Finder window's folder, at once (QuickPreset.swift).
//
// The first three bring the window to the front (opening it again when it was closed) and report on the status line.
// Items that are not folders (files, web links, text, missing items) are ignored and reported; a folder sent twice counts
// once; a folder already in the list is not added again (the apply service selects it). The home folder and the folders
// above it are refused like a drop. A service acts on the data folder of the instance that receives it: an app started
// with FINDER_PRESETS_DATA_DIR (a development run) keeps everything in that folder, and an app macOS starts for a service uses the
// default data folder. The development hooks (--selftest, --layout-probe) refuse every service.

/// The four services. Info.plist declares them (`NSMessage`, `NSMenuItem`), Resources/en.lproj and ko.lproj
/// (ServicesMenu.strings, copied into the bundle by build-app.sh) translate their titles, and a unit test keeps them in step.
enum FinderService: String, CaseIterable, Sendable {
	case addFolders, makePresets, apply, quickApply

	/// `NSMessage`: AppKit calls `<message>:userData:error:` on `FinderServiceProvider`.
	var message: String {
		switch self {
		case .addFolders: "addFoldersFromFinder"
		case .makePresets: "makePresetsFromFinder"
		case .apply: "applyFromFinder"
		case .quickApply: "applyQuickPreset"
		}
	}

	/// `NSMenuItem` `default` (English); en.lproj and ko.lproj ServicesMenu.strings map it to each language.
	var englishTitle: String {
		switch self {
		case .addFolders: "Add Folder to Finder Presets"
		case .makePresets: "Make Preset with Finder Presets"
		case .apply: "Apply with Finder Presets…"
		case .quickApply: "Apply Quick Preset to Front Finder Window"
		}
	}

	/// The title Finder shows, in the app's language (the bundle's ServicesMenu.strings; the English default outside
	/// the app bundle). The guide names the menu items with it.
	var localizedTitle: String { Bundle.main.localizedString(forKey: englishTitle, value: englishTitle, table: "ServicesMenu") }

	/// The only file type Finder offers them for (`NSSendFileTypes`): folders, not packages or files. None for the quick
	/// preset: a service without send types is offered in every app with or without a selection, so its shortcut works
	/// wherever the user presses it.
	var sendFileTypes: [String]? { self == .quickApply ? nil : ["public.folder"] }
}

/// A service request's items, sorted out before anything is done: the folders in the order they came, each once, and
/// what is ignored.
struct ServiceItems: Equatable, Sendable {
	/// Existing local folders (standardized paths), each once.
	var folders: [URL] = []
	/// Files, missing items and web links by name (a file's name, a link's address), and a count of text items.
	var ignored: [String] = []
	/// How many folders came more than once (they count once in `folders`).
	var duplicates = 0

	/// `textItems`: pasteboard items that hold no URL at all.
	nonisolated static func sort(_ urls: [URL], textItems: Int = 0, isFolder: (URL) -> Bool = FinderWindows.isFolder) -> ServiceItems {
		var items = ServiceItems()
		var seen = Set<String>()
		for raw in urls {
			// A file reference URL (file:///.file/id=…) that arrives unconverted becomes a path URL; any other URL stays as it is.
			let url = raw.isFileURL ? ((raw as NSURL).filePathURL ?? raw) : raw
			guard url.isFileURL, isFolder(url) else {
				items.ignored.append(url.isFileURL ? url.lastPathComponent : url.absoluteString)
				continue
			}
			let path = FolderRule.normalize(url.path)
			guard seen.insert(path).inserted else {
				items.duplicates += 1
				continue
			}
			items.folders.append(URL(fileURLWithPath: path))
		}
		if textItems > 0 { items.ignored.append(String(localized: "텍스트 \(textItems)개")) }
		return items
	}

	/// The legacy list of paths some senders still write instead of file URLs.
	static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

	/// Reads a service's pasteboard: file URLs (`public.file-url`, else the older list of paths), web links, and the items
	/// that hold no URL (text).
	static func read(_ pboard: NSPasteboard) -> ServiceItems {
		var urls = (pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
		if urls.isEmpty, let paths = pboard.propertyList(forType: filenamesType) as? [String] {
			urls = paths.map { URL(fileURLWithPath: $0) }
		}
		let urlTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, filenamesType]
		let textItems = (pboard.pasteboardItems ?? []).filter { Set($0.types).isDisjoint(with: urlTypes) }.count
		return sort(urls, textItems: textItems)
	}
}

/// Receives the services (`NSApp.servicesProvider`, set by the AppDelegate before launching finishes, so a request that
/// made macOS launch the app finds it). AppKit calls the methods on the main thread with the pasteboard Finder filled;
/// the pasteboard is read at once, while it is valid.
@MainActor
final class FinderServiceProvider: NSObject {
	static let shared = FinderServiceProvider()

	/// The model the services act on (FinderPresetsApp).
	private(set) weak var model: AppModel?
	/// The main window (FixedWindow), to bring it back when it is minimized.
	weak var mainWindow: NSWindow?
	/// Opens the main window again after it was closed (MainView, from its `openWindow`).
	var openMainWindow: (() -> Void)?
	/// Requests that arrived before the model was attached.
	private var waiting: [(FinderService, ServiceItems)] = []

	func attach(_ model: AppModel) {
		self.model = model
		let queued = waiting
		waiting = []
		for (service, items) in queued { run(service, items, model: model) }
	}

	// `<NSMessage>:userData:error:`, one per service (Info.plist).

	@objc func addFoldersFromFinder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		receive(.addFolders, pboard, error)
	}

	@objc func makePresetsFromFinder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		receive(.makePresets, pboard, error)
	}

	@objc func applyFromFinder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		receive(.apply, pboard, error)
	}

	@objc func applyQuickPreset(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		receive(.quickApply, pboard, error)
	}

	/// The reply (`error`) says why nothing was done; the requesting app may show it.
	private func receive(_ service: FinderService, _ pboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		#if DEBUG
		// The self-test and the layout probe check exact states; a request from Finder meanwhile would change them.
		if SelfTest.isRequested || LayoutProbe.isRequested {
			error.pointee = String(localized: "셀프테스트와 레이아웃 점검 중에는 Finder 서비스를 받지 않습니다.") as NSString
			return
		}
		#endif
		// The quick preset's pasteboard holds nothing it uses (whatever the app it was pressed in put there).
		let items = service == .quickApply ? ServiceItems() : ServiceItems.read(pboard)
		guard let model else {
			waiting.append((service, items))
			return
		}
		if let reply = run(service, items, model: model) { error.pointee = reply as NSString }
	}

	@discardableResult
	private func run(_ service: FinderService, _ items: ServiceItems, model: AppModel) -> String? {
		// The quick preset leaves the user in Finder: the window comes forward only with something to read. Its refusal
		// alert does not stop the next press (`AppModel.quickApplyGate`), so the sheet of the error alert is left out here.
		guard service == .quickApply else {
			showWindow()
			return model.perform(service, items, dialogOpen: Self.windowShowsDialog())
		}
		return model.perform(service, items, dialogOpen: Self.windowShowsDialog(besidesErrorAlert: model.errorMessage != nil))
	}

	/// The app to the front with its window: restored when minimized, opened again when it was closed (also the menu bar's
	/// "사용법" and "작업 기록").
	func showWindow() {
		NSApp.activate()
		if let window = mainWindow, window.isVisible || window.isMiniaturized {
			if window.isMiniaturized { window.deminiaturize(nil) }
			window.makeKeyAndOrderFront(nil)
		} else {
			openMainWindow?()
		}
	}

	/// A sheet, alert or confirmation on a window (the rename alert has no model state), or a modal panel.
	static func windowShowsDialog() -> Bool {
		NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
	}

	/// `windowShowsDialog` as the quick preset weighs it (`AppModel.quickApplyGate`). While the model's error alert is up
	/// (`errorAlertUp`), the main window's sheet is taken to be that alert and is not counted — the model knows its other
	/// sheets (`AppModel.hasOpenSheetOrConfirmation`) — so what is left is a sheet on another window (a Settings sheet) or
	/// a modal panel. Should the main window show a sheet the model does not know about instead (the rename alert), it is
	/// still there once the alert is closed, and the press is refused then (`waitUntilNoDialog`).
	static func windowShowsDialog(besidesErrorAlert errorAlertUp: Bool) -> Bool {
		guard errorAlertUp else { return windowShowsDialog() }
		let main = shared.mainWindow
		return NSApp.modalWindow != nil || NSApp.windows.contains { $0 !== main && $0.attachedSheet != nil }
	}

	/// How long `waitUntilNoDialog` waits at most for a closed alert's sheet to go: about a second.
	nonisolated static let dialogWait: Duration = .seconds(1)

	/// Waits until no window shows a sheet or a modal panel (`windowShowsDialog`): AppKit keeps a sheet attached until it
	/// has finished taking it away, a moment after SwiftUI was told to close it. Polled on the main actor without blocking
	/// it, for `dialogWait` at most. True when none is left.
	static func waitUntilNoDialog() async -> Bool {
		await waitUntil(timeout: dialogWait) { !windowShowsDialog() }
	}

	/// Checks `condition` at once, then every `interval` until it holds or `timeout` has passed, sleeping in between so
	/// the main actor stays free for AppKit and SwiftUI. True when it held.
	static func waitUntil(timeout: Duration, interval: Duration = .milliseconds(50), _ condition: () -> Bool) async -> Bool {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while !condition() {
			guard clock.now < deadline else { return false }
			do { try await Task.sleep(for: interval) } catch { return condition() }
		}
		return true
	}
}

/// How folders join "2. 적용할 폴더" (a drop, "폴더 추가…", the Finder services): in their order, each once.
struct FolderAddition: Equatable, Sendable {
	/// Paths appended to the list.
	var added: [String] = []
	/// Paths that were already in the list (left as they are).
	var alreadyListed: [String] = []
	/// Every folder of the request that is in the list afterwards, in the request's order (added and already listed).
	var inList: [String] = []
	/// The home folder and the folders above it, abbreviated (never added).
	var refused: [String] = []
	/// Files, missing items and web links, by name or address.
	var notFolders: [String] = []
}

extension AppModel {
	// MARK: Finder services

	/// What `addFolders` does with `urls` for a list that holds `listed`.
	nonisolated static func folderAddition(_ urls: [URL], listed: [String], isFolder: (URL) -> Bool = FinderWindows.isFolder) -> FolderAddition {
		var result = FolderAddition()
		var known = Set(listed)
		var seen = Set<String>()
		for url in urls {
			guard isFolder(url) else {
				result.notFolders.append(url.isFileURL ? url.lastPathComponent : url.absoluteString)
				continue
			}
			let path = FolderRule.normalize(url.path)
			if HomeFolders.isHomeOrAncestor(path) {
				result.refused.append(Fmt.abbreviate(path))
				continue
			}
			guard seen.insert(path).inserted else { continue }
			result.inList.append(path)
			if known.insert(path).inserted { result.added.append(path) } else { result.alreadyListed.append(path) }
		}
		return result
	}

	/// True while a sheet, an alert or a confirmation of the model is up (the apply service does not open its
	/// confirmation behind or over it).
	var hasOpenDialog: Bool { hasOpenSheetOrConfirmation || errorMessage != nil }

	/// `hasOpenDialog` but for the error alert, which the quick preset weighs separately (`quickApplyGate`): the guide, the
	/// history, the preset editor, the apply and system-wide confirmations, a preset deletion, the restart question.
	var hasOpenSheetOrConfirmation: Bool {
		showHelp || showHistory || presetEditor != nil || pendingApply != nil || pendingGlobalApply != nil
			|| pendingPresetDelete != nil || askRelaunch
	}

	/// Why the apply service does not open the confirmation now, or nil when it does.
	nonisolated static func applyServiceBlocker(isWorking: Bool, dialogOpen: Bool) -> String? {
		if isWorking { return String(localized: "다른 작업이 진행 중이라 적용 확인을 열지 않았습니다.") }
		if dialogOpen { return String(localized: "다른 창이나 알림이 열려 있어 적용 확인을 열지 않았습니다.") }
		return nil
	}

	/// Runs a service with the items it received (FinderServiceProvider; the self-test calls it directly). `dialogOpen`: a
	/// sheet or alert the model does not know about is up (for the quick preset, not counting the error alert's own sheet:
	/// `FinderServiceProvider.windowShowsDialog(besidesErrorAlert:)`). Returns the reply for the requesting app: nil when
	/// something was done, else why nothing was (the status line says the same).
	@discardableResult
	func perform(_ service: FinderService, _ items: ServiceItems, dialogOpen: Bool = false) -> String? {
		// The quick preset weighs the model's dialogs itself: its refusal alert does not stop it (`quickApplyGate`).
		if service == .quickApply { return quickApplyFromFinder(windowDialog: dialogOpen) }
		// Before anything changes: an alert raised below must not count as a dialog that was already open.
		let dialogOpen = dialogOpen || hasOpenDialog
		let blocker = Self.applyServiceBlocker(isWorking: isWorking, dialogOpen: dialogOpen)
		if !items.ignored.isEmpty {
			report(String(localized: "폴더만 받을 수 있습니다. 무시한 항목: \(items.ignored.joined(separator: ", "))"))
		}
		guard !items.folders.isEmpty else {
			status = String(localized: "Finder에서 받은 항목 중에 폴더가 없어 아무것도 하지 않았습니다.")
			return status
		}
		switch service {
		case .addFolders:
			let result = addFolders(items.folders)
			status = Self.additionNote(result)
			return result.inList.isEmpty ? status : nil
		case .makePresets:
			return makePresetsFromFinder(items.folders)
		case .apply:
			return applyFromFinder(items.folders, blocker: blocker)
		case .quickApply:
			return nil   // answered above
		}
	}

	/// The status line after the add service: what was added, what was already there, what was refused.
	nonisolated static func additionNote(_ r: FolderAddition) -> String {
		var parts: [String] = []
		if !r.added.isEmpty {
			parts.append(String(localized: "Finder에서 폴더 \(r.added.count)개를 목록에 추가했습니다: \(Fmt.folderNames(r.added))"))
		}
		if !r.alreadyListed.isEmpty {
			parts.append(r.added.isEmpty ? String(localized: "이미 목록에 있는 폴더입니다: \(Fmt.folderNames(r.alreadyListed))")
			                             : String(localized: "이미 목록에 있음: \(Fmt.folderNames(r.alreadyListed))"))
		}
		if r.inList.isEmpty { parts.append(String(localized: "폴더를 목록에 추가하지 않았습니다.")) }
		if !r.refused.isEmpty { parts.append(String(localized: "홈 폴더나 그 상위 폴더라 넣지 않음: \(Fmt.name(r.refused.joined(separator: ", ")))")) }
		return parts.joined(separator: " · ")
	}

	/// Service 2: one preset per folder, exactly like a drop on the preset list; the last one is selected. Folders that
	/// cannot be read are reported together, the others still become presets.
	private func makePresetsFromFinder(_ folders: [URL]) -> String? {
		var made: [Preset] = []
		var defaultsOnly: [String] = []
		var failures: [String] = []
		for folder in folders {
			do {
				let result = try makePreset(from: folder)
				made.append(result.preset)
				if !result.ownSettings { defaultsOnly.append(folder.lastPathComponent) }
			} catch {
				failures.append("\(folder.lastPathComponent): \(ErrorText.describe(error))")
			}
		}
		if !failures.isEmpty {
			report(String(localized: "프리셋을 만들지 못한 폴더:") + "\n" + failures.joined(separator: "\n"))
		}
		guard !made.isEmpty else {
			status = String(localized: "Finder의 폴더로 프리셋을 만들지 못했습니다.")
			return status
		}
		status = String(localized: "Finder의 폴더로 프리셋 \(made.count)개를 만들었습니다: \(Fmt.name(made.map(\.name).joined(separator: ", ")))")
			+ (defaultsOnly.isEmpty ? "" : " · " + String(localized: "고유 설정이 없어 Finder 기본값을 저장: \(Fmt.name(defaultsOnly.joined(separator: ", ")))"))
		return nil
	}

	/// Service 3: the folders join the list and exactly their rows are selected; then "선택한 폴더에 적용…" for them, which
	/// checks the folders (nothing written) and asks. With a task running or a dialog open (`blocker`) the rows are only
	/// selected, and the status line says how to go on.
	private func applyFromFinder(_ folders: [URL], blocker: String?) -> String? {
		let result = addFolders(folders)
		guard !result.inList.isEmpty else {
			status = Self.additionNote(result)
			return status
		}
		selectedTargets = Set(result.inList)
		// An alert this request raised (ignored items, refused folders) is shown first; the confirmation would compete with it.
		let reason = blocker ?? (errorMessage != nil ? String(localized: "알림을 먼저 확인하세요.") : nil)
		if let reason {
			let names = Fmt.folderNames(result.inList)
			status = String(localized: "\(names)을(를) 목록에서 선택했습니다. \(reason) 준비되면 \"선택한 폴더에 적용…\"을 누르세요.")
			return nil
		}
		prepareApply(to: result.inList.map { URL(fileURLWithPath: $0) })
		return nil
	}
}

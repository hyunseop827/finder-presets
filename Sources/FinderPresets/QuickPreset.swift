import Foundation
import AppKit
import FinderPresetsCore

// "빠른 적용": one preset the user stars is applied to the folder of the front Finder window by a keyboard shortcut, with
// no process in the background. The shortcut belongs to a macOS service without send types (Info.plist NSServices,
// `FinderService.quickApply`), so it works in any app and needs no selection; the user sets it in System Settings >
// Keyboard > Keyboard Shortcuts > Services (Info.plist can only give ⌘ or ⌘⇧ combinations, which Finder and other apps
// already use). The service asks Finder for its front window's folder with an Apple Event (the Automation permission the
// app already has for restarting Finder), then plans and writes that ONE folder, no subfolders, without a confirmation:
// the user asked for exactly this folder with a key press, and the operation is recorded and undoable like any apply.
// Finder shows a folder's new look only after a restart, so when something changes Finder is restarted and the folder
// opened again, in front of Finder's other windows, which are opened again too (`FinderWindows`: Finder does not reopen
// them after an Apple Event quit; that is said in the guide, the tooltips and the Settings window). The folder is
// written while Finder is down — quit, write, launch — because a Finder that quits writes what it holds in memory for
// the folders it shows into their parent `.DS_Store`, over anything written while it ran, and the front window's folder
// is shown by definition (a folder without settings of its own lost the first press that way).
//
// Finder also writes a view the user changes in a window lazily: not at once, not even when the window closes.
// A folder whose file already matches the quick preset can therefore still show another view, which Finder
// writes later. So the same script that asks for the folder reads the window's view (`FinderWindowView`), and "already
// the same" — nothing written, Finder left alone — needs the file AND the window to match the preset; otherwise Finder
// is quit (it writes what it holds), the folder planned again on the store as it left it, written when that differs,
// and Finder launched and the folder opened again (`quickApplyRecheck`). A window read in the first second or two after
// it opened can still report Finder's defaults rather than the folder's view; that is
// not guarded against, so when those defaults match the preset such an early press can still end as "already the same"
// (a guard would restart Finder on every true "already the same" press of a user whose defaults are the preset, which
// costs more).
//
// The decisions (no quick preset, a folder that is refused, already the same, a window that shows another view) are
// made by `quickApplyDecision` and `FinderWindowView.compared(with:)`, which need neither Finder nor the Apple Event; the
// writes with the restart are `quickApplyWrite` and `quickApplyRecheck`, which take Finder as a `FinderLifecycle`; the
// Apple Event (`FrontFinderWindow`) is a thin wrapper around a parser that tests feed with descriptors. What is open in
// the app when the shortcut is pressed is weighed by `quickApplyGate`, which needs no AppKit either: a refusal is shown
// in the error alert too, but an alert that holds only refusals does not stop the next press, which closes it and goes
// on (`ErrorAlert`, `closeQuickRefusalAlert`).

/// Where the quick preset's ID is kept: `quickPresetID` in the app's own defaults domain (`standard`). The tests and the
/// development hooks pass a store in memory, so they never write the domain the user's copy of the app shares.
struct QuickPresetSetting: Sendable {
	static let key = "quickPresetID"
	var read: @Sendable () -> String?
	var write: @Sendable (String?) -> Void

	var id: UUID? { read().flatMap(UUID.init(uuidString:)) }

	func set(_ id: UUID?) { write(id?.uuidString) }

	/// The stored ID, or nil when its preset is not among `presets` (deleted here, or its file removed elsewhere); the
	/// stored value is removed then. Only called with the complete list: a preset file that could not be read is not a
	/// deleted preset.
	func validID(among presets: [Preset]) -> UUID? {
		guard let id else {
			if read() != nil { set(nil) }   // not an ID at all
			return nil
		}
		guard presets.contains(where: { $0.id == id }) else {
			set(nil)
			return nil
		}
		return id
	}

	static let standard = QuickPresetSetting(
		read: { UserDefaults.standard.string(forKey: key) },
		write: { value in
			if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
		})

	/// A store that lives as long as the process.
	static func inMemory(_ initial: String? = nil) -> QuickPresetSetting {
		final class Box: @unchecked Sendable {
			let lock = NSLock()
			var value: String?
			init(_ value: String?) { self.value = value }
		}
		let box = Box(initial)
		return QuickPresetSetting(read: { box.lock.withLock { box.value } }, write: { new in box.lock.withLock { box.value = new } })
	}

	/// The self-test and the layout probe keep the star in memory (they check states; the defaults are the user's).
	@MainActor static var forThisLaunch: QuickPresetSetting {
		#if DEBUG
		if SelfTest.isRequested || LayoutProbe.isRequested { return inMemory() }
		#endif
		return standard
	}
}

/// Why the quick preset was not applied. Nothing was written, and Finder was not restarted.
enum QuickApplyRefusal: Error, Equatable, Sendable {
	case working, dialogOpen
	case noQuickPreset
	/// The stored quick preset is not in the list (its file could not be read).
	case presetMissing
	/// No Finder window, or the front one shows no folder (a search, Recents).
	case noFolderWindow
	/// The Automation permission for Finder was denied.
	case notAllowed
	case finderError(String)
	/// Paths (abbreviated in the message).
	case missingFolder(String)
	case aboveHome(String)
	/// `ParentStoreLocator` refused the folder (the root, a volume root, a parent that cannot be written): its reason.
	case unsupported(String, reason: String)
	/// The plan did not plan it (`PlanCategory`: an excluded location, no permission, a store that cannot be read).
	case skipped(String, PlanCategory)
	/// Finder was asked to quit and did not (a copy in progress, a dialog of its own): the folder is written only while
	/// Finder is down, so nothing was written or recorded.
	case finderDidNotQuit

	var message: String {
		func shown(_ path: String) -> String { Fmt.name(Fmt.abbreviate(path)) }
		switch self {
		case .working: return String(localized: "다른 작업이 진행 중이라 빠른 적용을 하지 않았습니다.")
		case .dialogOpen: return String(localized: "다른 창이나 알림이 열려 있어 빠른 적용을 하지 않았습니다.")
		case .noQuickPreset: return String(localized: "빠른 적용 프리셋이 없습니다. 프리셋 목록에서 쓸 프리셋의 별표를 누르세요.")
		case .presetMissing: return String(localized: "빠른 적용 프리셋을 찾지 못했습니다. 프리셋 목록에서 다시 별표로 지정하세요.")
		case .noFolderWindow: return String(localized: "앞 Finder 창이 폴더를 보여 주지 않습니다. 폴더를 연 Finder 창에서 다시 누르세요(검색·최근 항목 창은 안 됩니다).")
		case .notAllowed: return String(localized: "Finder에 앞 창의 폴더를 물을 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Finder Presets의 Finder를 켜세요.")
		case .finderError(let reason): return String(localized: "Finder에 앞 창의 폴더를 묻지 못했습니다: \(reason)")
		case .missingFolder(let path): return String(localized: "앞 Finder 창의 폴더를 찾지 못했습니다: \(shown(path))")
		case .aboveHome(let path): return String(localized: "홈 폴더보다 위의 폴더에는 적용하지 않습니다: \(shown(path))")
		case .unsupported(let path, let reason): return String(localized: "이 폴더에는 적용할 수 없습니다: \(shown(path)) — \(reason)")
		case .skipped(let path, .excluded):
			return String(localized: "이 위치는 적용할 때 항상 건너뜁니다(~/Library, /Applications, /Volumes 등): \(shown(path))")
		case .skipped(let path, .permissionDenied): return String(localized: "이 폴더를 읽을 권한이 없어 적용하지 않았습니다: \(shown(path))")
		case .skipped(let path, _): return String(localized: "이 폴더의 보기 설정 파일(.DS_Store)을 읽지 못해 적용하지 않았습니다: \(shown(path))")
		case .finderDidNotQuit: return String(localized: "Finder가 종료되지 않아 빠른 적용을 하지 않았습니다(아무것도 바꾸지 않음). Finder의 복사나 대화상자가 끝난 뒤 다시 누르세요.")
		}
	}
}

/// What the quick preset does with one folder, decided before anything is written.
enum QuickApplyDecision: Equatable, Sendable {
	/// The folder changes: quit Finder, write the plan (one folder), launch Finder and open the folder again.
	case apply(Preset, Plan)
	/// Nothing to write; Finder is left alone. The file matches the preset and so does the front window's view (or no
	/// window was compared: the development hooks).
	case alreadyMatching(Preset)
	/// The file matches the preset, but the front window may show the folder otherwise: it positively shows another view
	/// (`known`), or its view could not be read or compared (not `known`). Finder writes a view changed in a window
	/// lazily, so it is quit (and writes what it holds), the folder planned again on the store as Finder left it and
	/// written when that differs, and Finder launched and the folder opened again (`AppModel.quickApplyRecheck`).
	case windowDiffers(Preset, known: Bool)
	case refused(QuickApplyRefusal)
}

/// What is open in the app when the quick preset's shortcut is pressed (`AppModel.quickApplyGate`).
struct QuickApplyOpenDialogs: Equatable, Sendable {
	/// A sheet or confirmation of the model other than the error alert: the guide, the history, the preset editor, an
	/// apply or system-wide confirmation, a preset deletion, the restart question (`AppModel.hasOpenSheetOrConfirmation`).
	var sheetOrConfirmation = false
	/// What the error alert holds.
	var errorAlert: ErrorAlert.Content = .none
	/// A sheet, alert or modal panel the model does not know about (a Settings sheet, the rename alert, an open panel),
	/// not counting the error alert's own sheet (`FinderServiceProvider.windowShowsDialog(besidesErrorAlert:)`).
	var windowDialog = false
}

/// What a press of the quick preset's shortcut does about what is open, before anything else (`AppModel.quickApplyGate`).
enum QuickApplyGate: Equatable, Sendable {
	/// Nothing is in the way: the press goes on.
	case go
	/// The only thing open is the error alert, and it holds only quick-preset refusals (an earlier press's reason): it is
	/// closed as if "확인" were pressed, and the press goes on once its sheet is gone.
	case closeRefusalAlertThenGo
	/// A task runs (`.working`) or something else is open (`.dialogOpen`): refused, and nothing is closed.
	case refused(QuickApplyRefusal)
}

/// Finder's scripting codes (Finder.sdef, macOS 26) the quick preset reads, and the Apple Event descriptor types of the
/// answer.
enum FinderCode {
	static func make(_ code: String) -> FourCharCode { code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

	// Descriptor types.
	static let list = make("list"), enumerated = make("enum"), type = make("type"), keyword = make("keyw")
	static let texts: Set<FourCharCode> = Set(["utxt", "utf8", "TEXT", "itxt", "intl", "styl"].map(make))
	static let numbers: Set<FourCharCode> = Set(["shor", "long", "comp", "ushr", "magn", "ucom", "sing", "doub"].map(make))
	static let boolean = make("bool"), yes = make("true"), no = make("fals")

	/// `current view` (ecvw): icon 'icnv', list 'lsvw', column 'clvw', and 'flvw' for both "group view" and "flow view",
	/// which is how Finder reports a gallery.
	static let iconView = make("icnv"), listView = make("lsvw"), columnView = make("clvw"), flowView = make("flvw")
	static let views: [FourCharCode: ViewStyle] = [iconView: .icon, listView: .list, columnView: .column, flowView: .gallery]
	/// `arrangement` of the icon view options (earr). Finder's dictionary has no code for "date added" and "date last
	/// opened", so a preset arranged by them is never confirmed by the window (`FinderWindowView.compared`).
	static let arrangements: [FourCharCode: SortKey] = [
		make("narr"): .none, make("grda"): .grid, make("nama"): .name, make("mdta"): .dateModified, make("cdta"): .dateCreated,
		make("siza"): .size, make("kina"): .kind, make("laba"): .label,
	]
	/// `label position` (epos): bottom 'lbot', right 'lrgt' → `IconViewSettings.labelOnBottom`.
	static let labelPositions: [FourCharCode: Bool] = [make("lbot"): true, make("lrgt"): false]
	/// `icon size` of the list view options (lvic): small 'smic', large 'lgic' → the points `ListViewSettings.iconSize` holds.
	static let listIconSizes: [FourCharCode: Double] = [make("smic"): 16, make("lgic"): 32]
	/// `name` of the list view's `sort column` (elsv). The dictionary has no code for the "date added" and "date last
	/// opened" columns, so a preset sorted by them is not compared.
	static let listColumns: [FourCharCode: ListColumn] = [
		make("elsn"): .name, make("elsm"): .dateModified, make("elsc"): .dateCreated, make("elss"): .size, make("elsk"): .kind,
		make("elsl"): .label, make("elsv"): .version, make("elsC"): .comments,
	]
}

/// What the front Finder window shows, read in the same script as its folder (`FrontFinderWindow`): its view and, for an
/// icon or a list view, the options of that view which Finder's dictionary offers and a preset holds (all but the list's
/// sort direction) — as Finder's four-char codes, numbers and booleans, never as text. Nil: not read (not answered, or
/// not an option of the view the window shows). Read only; the options are never set (setting them changes Finder's
/// global defaults).
struct FinderWindowView: Equatable, Sendable {
	/// `current view` ('pvew').
	var view: FourCharCode?
	/// Icon view options ('icop'), read for an icon view: `icon size` ('lvis', points), `arrangement` ('iarr'), `text size`
	/// ('fsiz'), `label position` ('lpos'), `shows item info` ('mnfo'), `shows icon preview` ('prvw').
	var iconSize: Double?
	var arrangement: FourCharCode?
	var textSize: Double?
	var labelPosition: FourCharCode?
	var showsItemInfo: Bool?
	var showsIconPreview: Bool?
	/// List view options ('lvop'), read for a list view: `icon size` ('lvis', small/large icon as 16/32 points), `text size`,
	/// `shows icon preview` ('prvw'), `uses relative dates` ('urdt'), `calculates folder sizes` ('sfsz') and the `name` of
	/// the `sort column` ('srtc', an elsv code). Not its sort direction: whether the dictionary's "normal" is the file's
	/// ascending for every column was never checked.
	var listIconSize: Double?
	var listTextSize: Double?
	var listShowsIconPreview: Bool?
	var listUsesRelativeDates: Bool?
	var listCalculatesFolderSizes: Bool?
	var listSortColumn: FourCharCode?

	/// Nothing read.
	static let unread = FinderWindowView()

	/// The view style, or nil when the view was not read or is not one this app knows.
	var style: ViewStyle? { view.flatMap { FinderCode.views[$0] } }
	var arrangeBy: SortKey? { arrangement.flatMap { FinderCode.arrangements[$0] } }
	var labelOnBottom: Bool? { labelPosition.flatMap { FinderCode.labelPositions[$0] } }
	var sortColumn: ListColumn? { listSortColumn.flatMap { FinderCode.listColumns[$0] } }

	enum Comparison: Equatable, Sendable {
		/// Every value the preset sets that the window's view shows was read and is the same.
		case same
		/// A value the preset sets positively differs.
		case differs
		/// Nothing differs, but the view, the icon size or the arrangement could not be read or is not known, or the
		/// preset's arrangement has no code in Finder's dictionary (date added, date last opened).
		case unknown
	}

	/// The window's view against `preset`: the view style, and the options of the view the window shows — for an icon
	/// view the icon size and the arrangement (both must have been read), the text size, the label position, item info
	/// and icon preview (when read); for a list view the icon size, the text size, icon preview, relative dates,
	/// calculated sizes and the sort column (when read). Numbers are compared as whole points (Finder answers integers).
	/// Whatever the preset leaves as "유지" is not compared, nor are the options of a view the window does not show, nor
	/// what Finder's dictionary has no property for (grid spacing, the grouping), nor the list's sort direction (in the
	/// dictionary, but not read: see `listSortColumn`). An arrangement without a code in the dictionary (date added, date
	/// last opened) can never be confirmed: `unknown`, whatever Finder answers. A sort column without one is not compared
	/// (like one not read).
	func compared(with preset: ViewSettings) -> Comparison {
		guard let style else { return .unknown }
		var differs = false, unknown = false
		func check<T: Equatable>(_ shown: T?, _ wanted: T?, mustBeRead: Bool) {
			guard let wanted else { return }
			guard let shown else {
				if mustBeRead { unknown = true }
				return
			}
			if shown != wanted { differs = true }
		}
		func points(_ value: Double?) -> Double? { value?.rounded() }
		check(style, preset.viewStyle, mustBeRead: true)
		switch style {
		case .icon:
			check(points(iconSize), points(preset.icon.iconSize), mustBeRead: true)
			if let wanted = preset.icon.arrangeBy, !FinderCode.arrangements.values.contains(wanted) {
				// Whatever code Finder answers for such a window, it cannot say that it shows this arrangement.
				unknown = true
			} else {
				// A code Finder answered that this app does not know leaves the arrangement unknown, like one not answered.
				check(arrangeBy, preset.icon.arrangeBy, mustBeRead: true)
			}
			check(points(textSize), points(preset.icon.textSize), mustBeRead: false)
			check(labelOnBottom, preset.icon.labelOnBottom, mustBeRead: false)
			check(showsItemInfo, preset.icon.showItemInfo, mustBeRead: false)
			check(showsIconPreview, preset.icon.showIconPreview, mustBeRead: false)
		case .list:
			check(points(listIconSize), points(preset.list.iconSize), mustBeRead: false)
			check(points(listTextSize), points(preset.list.textSize), mustBeRead: false)
			check(listShowsIconPreview, preset.list.showIconPreview, mustBeRead: false)
			check(listUsesRelativeDates, preset.list.useRelativeDates, mustBeRead: false)
			check(listCalculatesFolderSizes, preset.list.calculateAllSizes, mustBeRead: false)
			if let wanted = preset.list.sortColumn, FinderCode.listColumns.values.contains(wanted) {
				check(sortColumn, wanted, mustBeRead: false)
			}
		case .column, .gallery:
			break
		}
		return differs ? .differs : unknown ? .unknown : .same
	}
}

/// What the quick preset's write did (`AppModel.quickApplyWrite`).
struct QuickApplyWrite: Sendable {
	enum FinderState: Equatable, Sendable {
		/// Never asked to quit: the development hooks only write.
		case leftAlone
		/// Asked to quit and still running: nothing was written or recorded.
		case didNotQuit
		/// Quit before the write and launched after it; `back`: whether it runs again.
		case restarted(back: Bool)
	}

	/// Why Finder was restarted although the file already matched (`QuickApplyDecision.windowDiffers`), and what planning
	/// the folder again once Finder had quit found (`AppModel.quickApplyRecheck`). Nil for a planned write.
	enum Recheck: Equatable, Sendable {
		/// The store as Finder left it differed from the preset: written and recorded like a planned write (`operation`).
		case changed
		/// It still matched: nothing written or recorded; the restart made the window show the file. `windowKnown`: the
		/// window positively showed another view (else its view could not be read or compared).
		case unchanged(windowKnown: Bool)
		/// Refused on the store as Finder left it (the folder gone, its store unreadable): nothing written.
		case refused(QuickApplyRefusal)
	}

	var finder: FinderState
	/// The operation the write recorded; nil when Finder did not quit or the write stopped.
	var operation: FinderPresetsOperation?
	/// Why the write stopped (a manifest that could not be saved: the folder may be written all the same).
	var error: String?
	/// Folders that did not hold what was written when they were read back, once Finder had been launched again and
	/// had a moment to settle (`FinderLifecycle.settle`).
	var overwritten: [String] = []
	var recheck: Recheck?
	/// How many of Finder's other windows were opened again once it was back (`FinderWindows`), before the folder.
	var windowsReopened = 0

	var changed: Bool { (operation?.summary.changed ?? 0) > 0 }

	/// Anything but a clean write — the folder written and still holding it, Finder back or never quit — brings the
	/// window forward. A restart that found the file already the same is clean too: the folder shows the preset again.
	var needsAttention: Bool {
		if error != nil || finder == .restarted(back: false) { return true }
		switch recheck {
		case .unchanged?: return false
		case .refused?: return true
		case .changed?, nil: return !changed || !overwritten.isEmpty
		}
	}

	/// The status line (not for `didNotQuit`, which is a refusal). `name`, `preset`: the folder's and the preset's shown names.
	///
	/// Whatever the write did, a Finder that was quit and launched again is named: its windows closed and were opened
	/// again, also when nothing could be written (the write comes after the quit) — only the sentence about a folder
	/// Finder overwrote says so by itself ("Finder가 다시 시작한 뒤…").
	func message(folder name: String, preset: String) -> String {
		let failedLaunch = String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")
		switch recheck {
		case .unchanged(let windowKnown)?:
			guard finder == .restarted(back: true) else {
				return String(localized: "빠른 적용: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같아 쓰지 않았습니다.") + " " + failedLaunch
			}
			return windowKnown
				? String(localized: "완료: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같았지만 Finder 창은 다른 보기를 보여 주고 있었습니다. Finder를 다시 시작하고 이 폴더를 다시 열었습니다. 파일은 그대로 두었습니다.")
				: String(localized: "완료: \(name)의 보기 설정 파일은 이미 \"\(preset)\"과 같았습니다. Finder 창의 보기를 확인하지 못해 Finder를 다시 시작하고 이 폴더를 다시 열었습니다. 파일은 그대로 두었습니다.")
		case .refused(let refusal)?:
			return refusal.message + " " + (finder == .restarted(back: true) ? String(localized: "Finder를 다시 시작했습니다.") : failedLaunch)
		case .changed?, nil:
			break
		}
		let note: String? = switch finder {
			case .restarted(back: true) where !changed || error != nil || overwritten.isEmpty:
				String(localized: "Finder를 다시 시작하고 이 폴더를 다시 열었습니다.")
			case .restarted(back: false): failedLaunch
			default: nil
		}
		if let error {
			// Segments joined with " · " (the one before the note ends in a parenthesis, not a period).
			return AppModel.stoppedWriteNote(error) + (note.map { " · " + $0 } ?? "")
		}
		let finderNote = note.map { " " + $0 } ?? ""
		guard changed else {
			return String(localized: "빠른 적용: \(name)에 쓰지 못했습니다(실패). 툴바의 \"기록\"에서 이 작업을 확인하세요.") + finderNote
		}
		guard overwritten.isEmpty else {
			return String(localized: "빠른 적용: Finder가 다시 시작한 뒤 \(name)의 보기 설정을 덮어썼습니다. 단축키를 한 번 더 누르세요(이 작업은 툴바의 \"기록\"에 있습니다).") + finderNote
		}
		return String(localized: "완료: \(name)에 \"\(preset)\"을(를) 적용했습니다.") + finderNote
	}
}

/// The Apple Events that ask Finder for its front window's folder and view.
enum FrontFinderWindow {
	/// The front window's folder and what it shows.
	struct Answer: Equatable, Sendable {
		var path: String
		var view: FinderWindowView
	}

	/// One script, run once: `target of` the front Finder window is the folder it shows (`as alias` fails for a window
	/// that shows none, before anything else is asked, so the errors mean what they meant before), then its `current view`
	/// and, for an icon or a list view, that view's options. The view is read inside `try`: a view or an option Finder does
	/// not answer leaves the folder and only makes the view unknown (`FinderWindowView.compared`). The options come in
	/// steps, each appended to the answer (`r & {…}`) in a fixed order — first those the comparison needs (icon size,
	/// arrangement), then text size and label position, then the booleans, then the list's sort column — so a step Finder
	/// does not answer ends the `try` and drops only itself and the steps after it, never the ones before. The window is held as the reference Finder returns, so every value comes from the same
	/// window. AppleScript sends Finder one `get` per value within the run. Only reads: nothing is set.
	static let source = """
	tell application "Finder"
		set w to front Finder window
		set p to POSIX path of (target of w as alias)
		try
			set v to current view of w
		on error
			return {p}
		end try
		set r to {p, v}
		if v is icon view then
			try
				set o to icon view options of w
				set r to r & {icon size of o, arrangement of o}
				set r to r & {text size of o, label position of o}
				set r to r & {shows item info of o, shows icon preview of o}
			end try
		else if v is list view then
			try
				set o to list view options of w
				set r to r & {icon size of o, text size of o}
				set r to r & {shows icon preview of o, uses relative dates of o, calculates folder sizes of o}
				set r to r & {name of sort column of o}
			end try
		end if
		return r
	end tell
	"""

	/// The folder's path and the window's view, or why there is none. Off the main thread: Finder may take a moment to
	/// answer. Finder is never launched for it (`tell` would launch a Finder that is not running).
	nonisolated static func read() -> Result<Answer, QuickApplyRefusal> {
		guard FinderController.isRunning else { return .failure(.noFolderWindow) }
		guard let script = NSAppleScript(source: source) else { return .failure(.finderError("NSAppleScript")) }
		var error: NSDictionary?
		let result = script.executeAndReturnError(&error)
		if let error {
			return .failure(refusal(errorNumber: error[NSAppleScript.errorNumber] as? Int, message: error[NSAppleScript.errorMessage] as? String))
		}
		guard let answer = parse(result) else { return .failure(.noFolderWindow) }
		return .success(answer)
	}

	/// The script's answer, by descriptor type and four-char code (never by text): a list `{path, view, options…}` — for an
	/// icon view `{…, icon size, arrangement, text size, label position, shows item info, shows icon preview}`, for a list
	/// view `{…, icon size, text size, shows icon preview, uses relative dates, calculates folder sizes, sort column name}`,
	/// possibly cut short after any step — or `{path}` when the view was not answered. A lone text is a path without a
	/// view. Nil without a path.
	nonisolated static func parse(_ answer: NSAppleEventDescriptor) -> Answer? {
		let items: [NSAppleEventDescriptor?] = answer.descriptorType == FinderCode.list
			? (answer.numberOfItems > 0 ? (1...answer.numberOfItems).map { answer.atIndex($0) } : [])
			: [answer]
		func item(_ index: Int) -> NSAppleEventDescriptor? { index < items.count ? items[index] : nil }
		guard let first = item(0), FinderCode.texts.contains(first.descriptorType), let path = first.stringValue, !path.isEmpty else { return nil }
		var view = FinderWindowView(view: code(item(1)))
		switch view.view {
		case FinderCode.iconView?:
			view.iconSize = number(item(2))
			view.arrangement = code(item(3))
			view.textSize = number(item(4))
			view.labelPosition = code(item(5))
			view.showsItemInfo = bool(item(6))
			view.showsIconPreview = bool(item(7))
		case FinderCode.listView?:
			// `lvic` (small/large icon); a number is taken as points.
			view.listIconSize = code(item(2)).flatMap { FinderCode.listIconSizes[$0] } ?? number(item(2))
			view.listTextSize = number(item(3))
			view.listShowsIconPreview = bool(item(4))
			view.listUsesRelativeDates = bool(item(5))
			view.listCalculatesFolderSizes = bool(item(6))
			view.listSortColumn = code(item(7))
		default:
			break
		}
		return Answer(path: path, view: view)
	}

	/// A boolean: `true`/`fals`, or `bool` with its byte.
	nonisolated static func bool(_ descriptor: NSAppleEventDescriptor?) -> Bool? {
		guard let descriptor else { return nil }
		switch descriptor.descriptorType {
		case FinderCode.yes: return true
		case FinderCode.no: return false
		case FinderCode.boolean: return descriptor.booleanValue
		default: return nil
		}
	}

	/// An enumerator (or a type or keyword) as its four-char code.
	nonisolated static func code(_ descriptor: NSAppleEventDescriptor?) -> FourCharCode? {
		guard let descriptor else { return nil }
		switch descriptor.descriptorType {
		case FinderCode.enumerated: return descriptor.enumCodeValue
		case FinderCode.type, FinderCode.keyword: return descriptor.typeCodeValue
		default: return nil
		}
	}

	/// A number of any integer or floating-point descriptor type.
	nonisolated static func number(_ descriptor: NSAppleEventDescriptor?) -> Double? {
		guard let descriptor, FinderCode.numbers.contains(descriptor.descriptorType) else { return nil }
		return descriptor.doubleValue
	}

	/// -1743: the user denied the Automation permission (or it was never asked for). -1728 (no such object): no Finder
	/// window. -1700 (cannot coerce): the front window shows no folder. Anything else is Finder's own message.
	nonisolated static func refusal(errorNumber: Int?, message: String?) -> QuickApplyRefusal {
		switch errorNumber {
		case -1743: .notAllowed
		case -1728, -1700: .noFolderWindow
		default: .finderError(message ?? errorNumber.map(String.init) ?? "?")
		}
	}
}

extension AppModel {
	// MARK: Quick preset (빠른 적용)

	var quickPreset: Preset? { preset(quickPresetID) }

	/// The star of a row (its menu, the selected preset's box): makes the preset the quick preset, or clears it when it is.
	/// Only one preset is the quick preset.
	func toggleQuickPreset(_ id: UUID) {
		guard let p = preset(id) else { return }
		let new: UUID? = quickPresetID == id ? nil : id
		quickPresetSetting.set(new)
		quickPresetID = new
		status = new == nil ? String(localized: "\"\(Fmt.name(p.name))\"의 빠른 적용을 해제했습니다.")
			: String(localized: "\"\(Fmt.name(p.name))\"을(를) 빠른 적용 프리셋으로 정했습니다. 단축키를 누르면 앞 Finder 창의 폴더에만 적용합니다(단축키는 설정 창 참고).")
	}

	/// The quick preset's rule for what is open when its shortcut is pressed (the user's decision of 2026-09-25: a refusal
	/// stays in the alert, so that it is seen even when the user is not looking at the app, but it must not stop the next
	/// press). A task running refuses (`.working`). Any sheet, confirmation or dialog other than the error alert refuses
	/// (`.dialogOpen`), and so does an error alert that holds anything but quick-preset refusals (a preset file that could
	/// not be read, a failed write): a real error is never closed unseen. An error alert that holds only quick-preset
	/// refusals is closed, and the press goes on.
	nonisolated static func quickApplyGate(isWorking: Bool, open: QuickApplyOpenDialogs) -> QuickApplyGate {
		if isWorking { return .refused(.working) }
		if open.sheetOrConfirmation || open.windowDialog { return .refused(.dialogOpen) }
		switch open.errorAlert {
		case .none: return .go
		case .quickRefusals: return .closeRefusalAlertThenGo
		case .other: return .refused(.dialogOpen)
		}
	}

	/// Why the quick preset cannot be applied now, before Finder is asked: no preset starred, or the starred one is not in
	/// the list. A task running and an open dialog are weighed first, by `quickApplyGate`.
	nonisolated static func quickApplyBlocker(presets: [Preset], quickPresetID: UUID?) -> QuickApplyRefusal? {
		guard let id = quickPresetID else { return .noQuickPreset }
		return presets.contains { $0.id == id } ? nil : .presetMissing
	}

	/// The quick preset on `path` (the front Finder window's folder): the folder alone (depth 0, no subfolders), refused like
	/// a folder of "2. 적용할 폴더" — the folders above the home folder, what `ParentStoreLocator` refuses (the root, a
	/// volume root, a parent that cannot be written) and what an apply always skips (~/Library, /Applications, /Volumes, …).
	/// The home folder itself is allowed: only its own view is written (its "." record), not the folders in it. Reads the
	/// folder's parent `.DS_Store`; writes nothing. `home`: a test passes a folder of its own.
	///
	/// A file that already matches is "already the same" only when `window` — what the front Finder window shows, read with
	/// its folder — matches the preset too (`FinderWindowView.compared`); a window that shows another view, or one whose
	/// view could not be read or compared, is `windowDiffers`. Nil: no window to compare (the development hooks, which
	/// never ask Finder or restart it; the plan after the quit in `quickApplyRecheck`).
	nonisolated static func quickApplyDecision(folder path: String, presets: [Preset], quickPresetID: UUID?, globals: GlobalDefaults,
	                                           window: FinderWindowView? = nil,
	                                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
	                                           isFolder: (URL) -> Bool = FinderWindows.isFolder) -> QuickApplyDecision {
		guard let id = quickPresetID else { return .refused(.noQuickPreset) }
		guard let preset = presets.first(where: { $0.id == id }) else { return .refused(.presetMissing) }
		let normalized = FolderRule.normalize(path)
		let url = URL(fileURLWithPath: normalized)
		guard isFolder(url) else { return .refused(.missingFolder(normalized)) }
		if HomeFolders.isHomeOrAncestor(normalized, home: home), !HomeFolders.isHome(normalized, home: home) {
			return .refused(.aboveHome(normalized))
		}
		do { _ = try ParentStoreLocator.locate(url) } catch { return .refused(.unsupported(normalized, reason: ErrorText.describe(error))) }
		let scanned = FolderScanner(options: ScanOptions(maxDepth: 0, excludedPaths: ScanOptions.defaultExclusions(home: home))).scan(roots: [url])
		let plan = Planner(presets: [preset], resolver: RuleResolver(rules: [], defaultPresetID: preset.id), globals: globals, home: home)
			.plan(scanned: scanned, roots: [url])
		switch plan.entries.first?.category {
		case .willChange?: return .apply(preset, plan)
		case .alreadyMatching?:
			switch window?.compared(with: preset.settings) {
			case nil, .same?: return .alreadyMatching(preset)
			case .differs?: return .windowDiffers(preset, known: true)
			case .unknown?: return .windowDiffers(preset, known: false)
			}
		case let category?: return .refused(.skipped(normalized, category))
		case nil: return .refused(.missingFolder(normalized))
		}
	}

	/// The service (FinderServices.swift): asks Finder for its front window's folder and view, then `quickApply`. Nothing is
	/// asked while a task runs, a dialog is open or no preset is starred (`quickApplyGate`, `quickApplyBlocker`); an error
	/// alert that holds only quick-preset refusals is closed first, and the press goes on once it is gone
	/// (`closeQuickRefusalAlert`). `windowDialog`: a sheet or modal panel the model does not know about, not counting the
	/// error alert's own sheet (`FinderServiceProvider.windowShowsDialog(besidesErrorAlert:)`). Returns the reply for the
	/// requesting app.
	func quickApplyFromFinder(windowDialog: Bool) -> String? {
		switch Self.quickApplyGate(isWorking: isWorking, open: quickApplyOpenDialogs(windowDialog: windowDialog)) {
		case .refused(let refusal):
			return refuseQuickApply(refusal)
		case .closeRefusalAlertThenGo:
			// The alert is closed by then, so every sheet counts again.
			closeQuickRefusalAlert { _ = self.quickApplyFromFinder(windowDialog: FinderServiceProvider.windowShowsDialog()) }
			return nil
		case .go:
			break
		}
		if let refusal = Self.quickApplyBlocker(presets: presets, quickPresetID: quickPresetID) {
			return refuseQuickApply(refusal)
		}
		isWorking = true
		status = String(localized: "앞 Finder 창의 폴더를 확인하는 중…")
		Task {
			let answer = await Task.detached(priority: .userInitiated) { FrontFinderWindow.read() }.value
			self.isWorking = false
			switch answer {
			case .success(let front): self.quickApply(to: front.path, window: front.view, checksDialogs: true)
			case .failure(let refusal): self.refuseQuickApply(refusal)
			}
		}
		return nil
	}

	/// Plans `path` with the quick preset and writes it at once (no confirmation), recorded like any apply: "되돌리기…" on
	/// the status line, the history, icon positions reset by the usual rule. When the folder changes, Finder is quit, the
	/// folder written while it is down, Finder launched and the folder opened again (`quickApplyWrite`), so the user sees
	/// its new look. When the file already matches, Finder is left alone only if `window` (what the front Finder window
	/// showed, read with its folder) matches too; a window that shows another view — which Finder writes to the file
	/// lazily — or whose view could not be read restarts Finder, and the folder is planned again once Finder has quit
	/// (`quickApplyRecheck`). The app's window stays behind Finder unless there is something to read (a refusal, Finder
	/// that did not quit or come back, already the same, nothing written, a folder Finder overwrote anyway, a failure). The
	/// development hooks never quit Finder and compare no window (they pass none). `checksDialogs`: the service checks
	/// again what is open here and once more before Finder is quit (`quickApplyGate`), since Finder's answer (the
	/// Automation prompt the first time) and the planning can take long, and meanwhile the editor, the guide or the history
	/// can be opened (they do not wait for `isWorking`). An error alert that holds only quick-preset refusals is closed at
	/// either point, and the press starts here again once it is gone (`closeQuickRefusalAlert`).
	func quickApply(to path: String, window: FinderWindowView? = nil, relaunchFinder: Bool = true, checksDialogs: Bool = false) {
		// The press again from the start, after a refusal alert was closed.
		let again: @MainActor () -> Void = { self.quickApply(to: path, window: window, relaunchFinder: relaunchFinder, checksDialogs: checksDialogs) }
		// Without `checksDialogs` (the development hooks) only a task running stops it.
		guard passesQuickApplyGate(checksDialogs ? quickApplyOpenDialogs() : QuickApplyOpenDialogs(), again: again) else { return }
		if let refusal = Self.quickApplyBlocker(presets: presets, quickPresetID: quickPresetID) {
			refuseQuickApply(refusal)
			return
		}
		var relaunch = relaunchFinder
		#if DEBUG
		// Like confirmUndo for Finder's defaults: the development hooks never quit Finder.
		if SelfTest.isRequested || LayoutProbe.isRequested { relaunch = false }
		#endif
		// Without a restart there is no window to compare; with one, a window that was not read counts as unknown.
		let shown: FinderWindowView? = relaunch ? (window ?? .unread) : nil
		let (presets, id, quick) = (self.presets, quickPresetID, quickPreset)
		let folder = URL(fileURLWithPath: FolderRule.normalize(path))
		let name = Fmt.name(folder.lastPathComponent)
		isWorking = true
		status = String(localized: "빠른 적용: \(name)을(를) 확인하는 중…")
		refreshGlobals()
		let globals = self.globals
		Task {
			let decision = await Task.detached(priority: .userInitiated) {
				Self.quickApplyDecision(folder: folder.path, presets: presets, quickPresetID: id, globals: globals, window: shown)
			}.value
			self.isWorking = false
			// The star or the starred preset changed while the folder was checked: the plan holds the values it had.
			guard self.quickPresetID == id, self.quickPreset == quick else {
				self.status = String(localized: "확인하는 동안 프리셋이 바뀌어 빠른 적용을 하지 않았습니다. 다시 누르세요.")
				FinderServiceProvider.shared.showWindow()
				return
			}
			// Once more before Finder is quit: false when refused, or when the press starts again once a refusal alert is gone.
			let mayQuitFinder = { !checksDialogs || self.passesQuickApplyGate(self.quickApplyOpenDialogs(), again: again) }
			switch decision {
			case .refused(let refusal):
				self.refuseQuickApply(refusal)
			case .alreadyMatching(let preset):
				self.status = String(localized: "\(name)은(는) 이미 \"\(Fmt.name(preset.name))\"과 같아 바꿀 것이 없습니다. Finder는 다시 시작하지 않았습니다.")
				FinderServiceProvider.shared.showWindow()
			case .apply(let preset, let plan):
				guard mayQuitFinder() else { return }
				self.writeQuickApply(preset, work: .write(plan), folder: folder, relaunch: relaunch)
			case .windowDiffers(let preset, let known):
				guard mayQuitFinder() else { return }
				// Planned again after the quit with the same presets, star and globals this decision used.
				self.writeQuickApply(preset, work: .recheck(windowKnown: known, planAgain: {
					Self.quickApplyDecision(folder: folder.path, presets: presets, quickPresetID: id, globals: globals)
				}), folder: folder, relaunch: relaunch)
			}
		}
	}

	/// The quick preset's write, off the main thread. With `restartsFinder`: the folders of Finder's windows are read and
	/// Finder is quit, and nothing is written or recorded when it does not quit; then the plan is written (`Applier` reads
	/// the parent store after Finder's own last write and merges only the managed records, so the recorded "before" is
	/// what Finder showed), Finder is launched again, its other windows opened again (`FinderWindows`, without `folder`)
	/// and then `folder` (`reopen`), so it is in front — both only when Finder is back —, Finder given a moment to settle
	/// (`FinderLifecycle.settleAndCheck`: `launch` returns as soon as the process exists and `reopen` does not wait; a
	/// Finder that went away meanwhile is launched once more) and the written records read back (`Applier.verify`). The
	/// read-back sees what Finder wrote by then, not what it writes later (a window closed, another quit). Without it (the
	/// development hooks) Finder is never asked anything: the plan is only written. `folder`: the front window's folder,
	/// the request's one root. `finder` and `reopen`: the real Finder and `NSWorkspace` in the app, fakes in the tests.
	nonisolated static func quickApplyWrite(_ request: ApplyRequest, folder: URL, applier: Applier, restartsFinder: Bool,
	                                        finder: any FinderLifecycle, reopen: () -> Void) -> QuickApplyWrite {
		func write() -> (FinderPresetsOperation?, String?) {
			do { return (try applier.apply(request), nil) } catch { return (nil, ErrorText.describe(error)) }
		}
		guard restartsFinder else {
			let (op, error) = write()
			return QuickApplyWrite(finder: .leftAlone, operation: op, error: error)
		}
		let windows = FinderWindows.remember(finder)
		guard finder.quit() else { return QuickApplyWrite(finder: .didNotQuit) }
		let (op, error) = write()
		return relaunched(QuickApplyWrite(finder: .leftAlone, operation: op, error: error), windows: windows, folder: folder,
		                  applier: applier, finder: finder, reopen: reopen)
	}

	/// The file already matched the preset but the front window did not (`QuickApplyDecision.windowDiffers`), off the main
	/// thread: Finder is quit — nothing is planned, written or recorded when it does not quit — and writes what it holds for
	/// the window as it quits; the folder is planned again on the store as Finder left it (`planAgain`: the same decision
	/// without a window). A change is written and recorded like a planned write (`Recheck.changed`: the recorded "before"
	/// is the view Finder wrote, so an undo brings it back); a store that still matches is left alone and nothing is
	/// recorded (`Recheck.unchanged`); a refusal writes nothing (`Recheck.refused`). Then, whatever was found, Finder is
	/// launched, its other windows and then the folder opened again, Finder given a moment to settle and a write read back,
	/// as in `quickApplyWrite` (Finder's windows are read right before the quit). `windowKnown`: the window positively
	/// showed another view (only the status line differs).
	nonisolated static func quickApplyRecheck(windowKnown: Bool, folder: URL, planAgain: () -> QuickApplyDecision, applier: Applier,
	                                          finder: any FinderLifecycle, reopen: () -> Void) -> QuickApplyWrite {
		let windows = FinderWindows.remember(finder)
		guard finder.quit() else { return QuickApplyWrite(finder: .didNotQuit) }
		var result = QuickApplyWrite(finder: .leftAlone)
		switch planAgain() {
		case .apply(let preset, let plan):
			result.recheck = .changed
			do {
				result.operation = try applier.apply(ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings))
			} catch {
				result.error = ErrorText.describe(error)
			}
		case .alreadyMatching, .windowDiffers:
			result.recheck = .unchanged(windowKnown: windowKnown)
		case .refused(let refusal):
			result.recheck = .refused(refusal)
		}
		return relaunched(result, windows: windows, folder: folder, applier: applier, finder: finder, reopen: reopen)
	}

	/// The end of both writes, once Finder has quit and the folder was written (or not): Finder launched and, when it is
	/// back, its other windows opened again (`windows` without `folder`), then the folder, so it is in front, and Finder
	/// given a moment to settle (launched once more when it went away meanwhile); then the write read back.
	private nonisolated static func relaunched(_ written: QuickApplyWrite, windows: FinderWindows, folder: URL, applier: Applier,
	                                           finder: any FinderLifecycle, reopen: () -> Void) -> QuickApplyWrite {
		var result = written
		var back = finder.launch()
		if back {
			result.windowsReopened = windows.reopen(in: finder, before: [folder]).count
			reopen()
			back = finder.settleAndCheck()
		}
		result.finder = .restarted(back: back)
		if let op = result.operation { result.overwritten = applier.verify(op).map(\.folderPath) }
		return result
	}

	/// What `writeQuickApply` does once Finder has quit: the plan made before, or planning the folder again.
	private enum QuickApplyWork {
		case write(Plan)
		case recheck(windowKnown: Bool, planAgain: @Sendable () -> QuickApplyDecision)
	}

	private func writeQuickApply(_ preset: Preset, work: QuickApplyWork, folder: URL, relaunch: Bool) {
		let name = Fmt.name(folder.lastPathComponent)
		// "종료" waits from the quit through the write to the launch (QuitGuard); the app launches a Finder that did not
		// come back when it quits (`relaunchFinderLeftQuit`).
		beginWriting(quitsFinder: relaunch)
		let applier = Applier(operations: operationStore, globals: globals)
		let run: @Sendable () -> QuickApplyWrite
		switch work {
		case .write(let plan):
			status = String(localized: "빠른 적용: \(name)에 \"\(Fmt.name(preset.name))\"을(를) 쓰는 중…")
			let request = ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings)
			run = {
				Self.quickApplyWrite(request, folder: folder, applier: applier, restartsFinder: relaunch, finder: RealFinderLifecycle()) {
					NSWorkspace.shared.open(folder)
				}
			}
		case .recheck(let known, let planAgain):
			status = String(localized: "빠른 적용: Finder를 다시 시작하고 \(name)을(를) 다시 확인하는 중…")
			run = {
				Self.quickApplyRecheck(windowKnown: known, folder: folder, planAgain: planAgain, applier: applier, finder: RealFinderLifecycle()) {
					NSWorkspace.shared.open(folder)
				}
			}
		}
		Task.detached(priority: .userInitiated) {
			let write = run()
			await MainActor.run {
				self.isWorking = false
				if write.finder == .didNotQuit {
					self.refuseQuickApply(.finderDidNotQuit)
					return
				}
				self.status = write.message(folder: name, preset: Fmt.name(preset.name))
				self.offerUndo(write.changed ? write.operation?.id : nil)
				if let error = write.error {
					// Like confirmApply: a manifest write failure; the folder may already be written.
					self.errorMessage = error
				} else if case .refused(let refusal)? = write.recheck {
					// Like a refusal before the quit, in the alert too (the status line adds that Finder was restarted),
					// and like one it does not stop the next press.
					self.reportQuickRefusal(refusal.message)
				} else if write.changed && !write.overwritten.isEmpty {
					// It asks for another press, so like a refusal it does not stop that press: the press closes it.
					self.reportQuickRefusal(self.status)
				}
				if write.needsAttention { FinderServiceProvider.shared.showWindow() }
				self.afterOperationRecorded()
			}
		}
	}

	/// The window comes forward with the reason on the status line; a reason other than a busy app or an open dialog is
	/// also shown in the alert (the user pressed a shortcut in Finder and looks at the window only now), as a quick-preset
	/// refusal: it replaces an earlier refusal there, and the next press closes it (`reportQuickRefusal`). Returns it.
	@discardableResult
	private func refuseQuickApply(_ refusal: QuickApplyRefusal) -> String {
		status = refusal.message
		if refusal != .working && refusal != .dialogOpen { reportQuickRefusal(refusal.message) }
		FinderServiceProvider.shared.showWindow()
		return refusal.message
	}

	/// What is open now, as the quick preset's service path weighs it (`quickApplyGate`). `windowDialog`: what the service
	/// found when the request arrived; nil asks now (`FinderServiceProvider.windowShowsDialog(besidesErrorAlert:)`).
	private func quickApplyOpenDialogs(windowDialog: Bool? = nil) -> QuickApplyOpenDialogs {
		QuickApplyOpenDialogs(sheetOrConfirmation: hasOpenSheetOrConfirmation, errorAlert: errorAlert.content,
		                      windowDialog: windowDialog ?? FinderServiceProvider.windowShowsDialog(besidesErrorAlert: errorMessage != nil))
	}

	/// `quickApplyGate` at one point of `quickApply(to:)`: true when the press goes on now. Otherwise it was refused, or a
	/// refusal alert is being closed and `again` — the press from the start — runs once it is gone.
	private func passesQuickApplyGate(_ open: QuickApplyOpenDialogs, again: @escaping @MainActor () -> Void) -> Bool {
		switch Self.quickApplyGate(isWorking: isWorking, open: open) {
		case .go:
			return true
		case .refused(let refusal):
			refuseQuickApply(refusal)
		case .closeRefusalAlertThenGo:
			closeQuickRefusalAlert(then: again)
		}
		return false
	}

	/// `QuickApplyGate.closeRefusalAlertThenGo`: the refusal alert is closed as if "확인" were pressed, and `next` — the
	/// press, checked again from the start — runs once AppKit has taken the alert's sheet away and nothing else opened
	/// meanwhile. `windowShowsDialog` sees the sheet until AppKit has finished closing it, so this waits for that without
	/// blocking the main thread (`FinderServiceProvider.waitUntilNoDialog`: polled on the main actor, about a second at
	/// most) and holds `isWorking` meanwhile, so another press is refused as busy. A sheet still there after the wait (the
	/// alert did not go, or the main window showed a sheet the model does not know about) is refused like any open dialog.
	private func closeQuickRefusalAlert(then next: @escaping @MainActor () -> Void) {
		errorMessage = nil
		isWorking = true
		Task {
			let gone = await FinderServiceProvider.waitUntilNoDialog()
			self.isWorking = false
			guard gone, Self.quickApplyGate(isWorking: false, open: self.quickApplyOpenDialogs()) == .go else {
				self.refuseQuickApply(.dialogOpen)
				return
			}
			next()
		}
	}
}

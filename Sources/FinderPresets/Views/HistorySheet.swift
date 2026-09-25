import SwiftUI
import FinderPresetsCore

/// The words of the history sheet and of the undo results, in the app's language (Language.swift). `OperationOverview`
/// holds no display text; everything shown about a record is worded here.
///
/// A row and the details lead with what the operation did, in plain words ("폴더 478개에 \"Developer\" 적용") — so the
/// first words tell the kind apart without the icon — and say where and when it ran and what can be done about it now in
/// sentences, not in a labelled table.
///
/// One wording per kind, and one word per meaning: an apply is worded as something **적용**한 (applied to folders or to
/// Finder's default view), an undo record says whose apply it **되돌림** (undid) — never the bare "되돌림" of the badge,
/// which says that an apply *was* undone ("이미 되돌림"). Nothing claims a change that may not have happened ("적용"
/// instead of "바꿈"), and a preset name never carries a Korean particle of its own.
enum HistoryText {
	static func symbol(_ kind: OperationKind) -> String {
		switch kind {
		case .apply: "folder.fill"
		case .undo: "arrow.uturn.backward"
		case .applyGlobal: "macwindow"
		case .undoGlobal: "arrow.uturn.backward.circle"
		}
	}

	/// The row's (and the details') first line: what the operation did — "폴더 478개에 \"Developer\" 적용",
	/// "Finder 기본 보기에 \"Developer\" 적용", "\"Developer\" 적용을 되돌림 · 폴더 27개". The preset (set apart with
	/// `Fmt.name`, as everywhere a user-chosen name sits inside a sentence) is every name of a mixed apply.
	static func title(_ o: OperationOverview) -> String {
		let preset = o.presetName.flatMap { $0.isEmpty ? nil : Fmt.name($0) }
		switch o.kind {
		case .apply:
			// No view changed: there is no folder count to name. Either nothing changed at all (the badge "변경 없음" and the
			// details say so), or only icon positions were reset (a system-wide apply's home record, undoable): name those.
			guard o.folderCount > 0 else {
				let what = preset.map { String(localized: "\"\($0)\" 적용") } ?? String(localized: "보기 설정 적용")
				return o.positionsOnlyCount > 0 ? what + " · " + positionsOnlyFolders(o.positionsOnlyCount, undo: false) : what
			}
			let count = folders(o.folderCount)
			return preset.map { String(localized: "\(count)에 \"\($0)\" 적용") } ?? String(localized: "\(count)에 보기 설정 적용")
		case .undo:
			// Which apply was undone, so the row is not just "되돌림" beside the badge of the same word.
			let what = o.folderCount > 0 ? folders(o.folderCount)
				: o.positionsOnlyCount > 0 ? positionsOnlyFolders(o.positionsOnlyCount, undo: true) : String(localized: "바꾼 폴더 없음")
			return preset.map { String(localized: "\"\($0)\" 적용을 되돌림 · \(what)") }
				?? String(localized: "폴더 적용을 되돌림 · \(what)")
		case .applyGlobal:
			return preset.map { String(localized: "Finder 기본 보기에 \"\($0)\" 적용") }
				?? String(localized: "Finder 기본 보기에 보기 설정 적용")
		case .undoGlobal:
			return preset.map { String(localized: "Finder 기본 보기의 \"\($0)\" 적용을 되돌림") }
				?? String(localized: "Finder 기본 보기 적용을 되돌림")
		}
	}

	private static func formatter(_ template: String) -> DateFormatter {
		let f = DateFormatter()
		f.locale = AppLanguage.locale
		f.setLocalizedDateFormatFromTemplate(template)
		return f
	}
	private static let shortFormatter = formatter("MMMdHHmm")
	private static let longFormatter = formatter("yyyyMMMdHHmm")

	/// "9월 18일 14:32" / "Sep 18, 14:32"
	static func time(_ date: Date) -> String { shortFormatter.string(from: date) }
	/// "2026년 9월 18일 14:32" / "Sep 18, 2026, 14:32" (no seconds: the sheet never needs them, and the sentences that
	/// carry this stay one line shorter).
	static func fullTime(_ date: Date) -> String { longFormatter.string(from: date) }

	static func folders(_ n: Int) -> String { String(localized: "폴더 \(n)개") }

	/// The folders whose icon positions alone an operation changed (`OperationOverview.positionsOnlyCount`: folders that
	/// follow Finder's default view, which a system-wide apply changed) — counted apart from the folders it changed.
	static func positionsOnlyFolders(_ n: Int, undo: Bool) -> String {
		undo ? String(localized: "아이콘 자리만 되돌린 폴더 \(n)개") : String(localized: "아이콘 자리만 새로 잡은 폴더 \(n)개")
	}

	/// Where a folder operation ran, for the row's second line: the first folder, abbreviated ("~/Developer/Projects"),
	/// and how many more there were. Nil for a global operation, whose title already says what it changed.
	static func place(_ o: OperationOverview) -> String? {
		guard !o.isGlobal, let first = o.roots.first else { return nil }
		let path = Fmt.abbreviate(first)
		return o.roots.count == 1 ? path : String(localized: "\(path) 외 \(o.roots.count - 1)개")
	}

	/// The names of the folders the operation was started on, for the details' sentence: their paths are long enough to
	/// fill the pane and be cut, while the row above already shows the path and the sentence's tooltip has all of them.
	static func placeNames(_ o: OperationOverview) -> String? {
		guard !o.isGlobal, !o.roots.isEmpty else { return nil }
		return Fmt.firstNames(o.roots.map { URL(fileURLWithPath: $0).lastPathComponent }, limit: 3)
	}

	/// Every folder the operation was started on, one per line (the tooltip of the details' sentence).
	static func placesHelp(_ o: OperationOverview) -> String? {
		o.roots.isEmpty ? nil : o.roots.map(Fmt.abbreviate).joined(separator: "\n")
	}

	/// The row's second line as one text (what VoiceOver reads of it): when and where. The row draws the "·" between
	/// them itself and hides it from VoiceOver, which would read the character out.
	static func subtitle(_ o: OperationOverview) -> String {
		[time(o.startedAt), place(o)].compactMap { $0 }.joined(separator: ", ")
	}

	/// The row's badge; nil for the usual case (an operation that can be undone, or an undo record). "이미 되돌림" says
	/// that this apply *was* undone — the undo record itself is worded by `title`, so the two never read the same.
	static func badge(_ o: OperationOverview) -> (text: String, warning: Bool)? {
		if o.inProgress { return (String(localized: "진행 중"), true) }
		if !o.isFinished { return (String(localized: "미완료"), true) }
		switch o.status {
		case .undone: return (String(localized: "이미 되돌림"), false)
		case .nothingToUndo: return (String(localized: "변경 없음"), false)
		case .undoable: return nil
		}
	}

	/// The details' sentence about when and where the operation ran: what it did there once it is over, when it started
	/// while it is still being written (or was left behind partway).
	static func summarySentence(_ o: OperationOverview) -> String {
		let when = fullTime(o.startedAt)
		let started = o.inProgress || !o.isFinished
		guard let places = placeNames(o) else {
			return started ? String(localized: "\(when)에 시작했습니다.") : String(localized: "\(when)에 실행했습니다.")
		}
		return started ? String(localized: "\(when)에 \(places)에서 시작했습니다.")
			: String(localized: "\(when)에 \(places)에서 실행했습니다.")
	}

	// MARK: The selected record's preset and folders (HistoryDetails)

	/// The heading over the preset preview: it draws the preset on the app's sample folder, never the folders the
	/// operation touched. Without a preset to draw (`noPreview`) the heading promises no sample.
	static func previewTitle(drawn: Bool) -> String {
		drawn ? String(localized: "프리셋 미리보기 · 예시 폴더") : String(localized: "프리셋 미리보기")
	}

	/// Why a record has no preset preview: an undo record put recorded values back instead of applying a preset, and an
	/// apply has no one preset to draw when it applied several at once or when its values were not recorded (an older
	/// record) — the line names both reasons, because the pane cannot tell a mixed apply's names from one long name.
	static func noPreview(_ o: OperationOverview) -> String {
		o.isUndo ? String(localized: "되돌리기 기록이라 프리셋 미리보기가 없습니다. 되돌린 작업을 고르면 보입니다.")
			: String(localized: "여러 프리셋을 함께 적용했거나 값이 기록되지 않아 미리보기를 그리지 않습니다.")
	}

	/// The same for an undo record whose target is listed: the sentence without "되돌린 작업을 고르면 보입니다", because a
	/// button beside it goes there (`showUndone`).
	static var noPreviewUndo: String { String(localized: "되돌리기 기록이라 프리셋 미리보기가 없습니다.") }

	/// The button that selects the operation an undo record undid.
	static var showUndone: String { String(localized: "되돌린 작업 보기") }

	/// The record's own file could not be read after all (removed or unreadable since the list was read): neither the
	/// preset nor the folders can be shown, and the pane says that instead of staying empty.
	static var detailsUnreadable: String {
		String(localized: "이 기록의 파일을 읽지 못해 프리셋과 바뀐 폴더를 보여줄 수 없습니다.")
	}

	/// The heading over the folders the operation changed — for a global operation, what it changed instead.
	static func foldersTitle(_ o: OperationOverview, count: Int) -> String {
		if o.isGlobal {
			return o.isUndo ? String(localized: "Finder 기본 보기를 되돌렸습니다.") : String(localized: "Finder 기본 보기를 바꿨습니다.")
		}
		// The list below holds the folders whose view changed; the ones whose icon positions alone changed are counted here.
		let positions = o.positionsOnlyCount > 0 ? positionsOnlyFolders(o.positionsOnlyCount, undo: o.isUndo) : nil
		if count == 0 { return positions ?? (o.isUndo ? String(localized: "되돌린 폴더 없음") : String(localized: "바꾼 폴더 없음")) }
		let changed = o.isUndo ? String(localized: "되돌린 폴더 \(count)개") : String(localized: "바뀐 폴더 \(count)개")
		return positions.map { changed + " · " + $0 } ?? changed
	}

	/// The folders the list does not show ("외 12개"), or nil when it shows them all.
	static func moreFolders(_ hidden: Int) -> String? {
		hidden > 0 ? String(localized: "외 \(hidden)개") : nil
	}

	/// A folder row: its own name, and where it sits **inside the root it is listed under** ("" for the root itself and for
	/// a folder directly in it, "sub/deep" further down) — the root is named once, by the heading over the group, so the
	/// rows do not repeat the same long path once per line. A folder under none of the roots keeps the abbreviated path of
	/// the folder above it. The whole path is the row's tooltip.
	static func folderRow(_ path: String, under root: String) -> (name: String, place: String) {
		let url = URL(fileURLWithPath: path)
		let parent = url.deletingLastPathComponent().path
		guard !root.isEmpty else { return (url.lastPathComponent, parent == "/" ? "" : Fmt.abbreviate(parent)) }
		let base = root.hasSuffix("/") ? root : root + "/"
		if path == root || parent == root || parent + "/" == base { return (url.lastPathComponent, "") }
		guard parent.hasPrefix(base) else { return (url.lastPathComponent, parent == "/" ? "" : Fmt.abbreviate(parent)) }
		return (url.lastPathComponent, String(parent.dropFirst(base.count)))
	}

	/// What the operation skipped or could not write, or nil when it skipped and failed nothing.
	static func countsLine(_ o: OperationOverview) -> String? {
		var parts: [String] = []
		if o.skippedCount > 0 { parts.append(String(localized: "건너뛴 폴더 \(o.skippedCount)개")) }
		if o.failedCount > 0 { parts.append(String(localized: "실패한 폴더 \(o.failedCount)개")) }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	/// The counts line's tooltip: those folders themselves, as far as the manifest was read (`HistoryDetails` keeps the
	/// first `problemLimit` of each), under the same words the line counts them with — and, like the folder list, "외 N개"
	/// for the ones it does not name, so the heading's count and the paths below it never disagree in silence.
	static func countsHelp(_ o: OperationOverview, _ details: HistoryDetails?) -> String? {
		guard let details else { return countsLine(o) }
		var lines: [String] = []
		func group(_ heading: String, _ count: Int, _ paths: [String]) {
			guard count > 0 else { return }
			lines.append(heading)
			lines += paths.map(Fmt.abbreviate)
			if let more = moreFolders(count - paths.count) { lines.append(more) }
		}
		group(String(localized: "건너뛴 폴더 \(o.skippedCount)개"), o.skippedCount, details.skipped)
		group(String(localized: "실패한 폴더 \(o.failedCount)개"), o.failedCount, details.failed)
		return lines.isEmpty ? nil : lines.joined(separator: "\n")
	}

	/// The details' sentence about what can be done with the operation now, with the symbol and the tone it is shown in.
	/// `undoneAt`: when the undo that undid it started.
	static func stateSentence(_ o: OperationOverview, undoneAt: Date?) -> (text: String, symbol: String, warning: Bool) {
		// Still being written, whatever its kind (an undo record too).
		if o.inProgress { return (String(localized: "아직 기록하는 중입니다. 끝난 뒤에 되돌릴 수 있습니다."), "clock", true) }
		let leftover = !o.isFinished ? [String(localized: "중간에 멈춘 작업입니다.")] : []
		if o.isUndo {
			var parts = leftover
			if o.foundAlreadyRestored { parts.append(String(localized: "이미 적용 전 상태여서 아무것도 쓰지 않았습니다.")) }
			switch o.status {
			case .undone: parts.append(String(localized: "이 되돌리기를 다시 되돌렸습니다."))
			default: parts.append(UndoRefusal.isUndoRecord.message)
			}
			return (parts.joined(separator: " "), leftover.isEmpty ? "arrow.uturn.backward.circle" : "exclamationmark.triangle.fill",
			        !leftover.isEmpty)
		}
		switch o.status {
		case .undoable:
			return o.isFinished ? (String(localized: "지금 되돌릴 수 있습니다."), "arrow.uturn.backward", false)
				: (String(localized: "중간에 멈춘 작업입니다. 지금 되돌릴 수 있습니다."), "exclamationmark.triangle.fill", true)
		case .undone:
			return (undoneAt.map { String(localized: "\(fullTime($0))에 되돌렸습니다.") } ?? UndoRefusal.alreadyUndone.message,
			        "checkmark.circle", false)
		case .nothingToUndo:
			return ((leftover + [nothingToUndoReason(o)]).joined(separator: " "),
			        leftover.isEmpty ? "minus.circle" : "exclamationmark.triangle.fill", !leftover.isEmpty)
		}
	}

	/// Why an operation has nothing to put back — the same words in the state sentence and in the tooltip of the disabled
	/// "되돌리기…" (`UndoRefusal.nothingToUndo` names both reasons at once, for a refusal that does not know the kind).
	static func nothingToUndoReason(_ o: OperationOverview) -> String {
		o.isGlobal ? String(localized: "되돌릴 것이 없습니다(기록한 값이 없습니다).")
			: String(localized: "되돌릴 것이 없습니다(바뀐 폴더가 없습니다).")
	}

	/// Why "되돌리기…" is disabled for `o`, or its help when it is not.
	static func undoHelp(_ o: OperationOverview, busy: Bool) -> String {
		if o.isUndo { return UndoRefusal.isUndoRecord.message }
		switch o.status {
		case .undone: return UndoRefusal.alreadyUndone.message
		case .nothingToUndo: return nothingToUndoReason(o)
		case .undoable: break
		}
		if o.inProgress { return UndoRefusal.inProgress.message }
		if busy { return String(localized: "다른 작업이 끝난 뒤에 되돌리세요.") }
		return o.isGlobal ? String(localized: "Finder 기본 보기를 이 작업 전의 값으로 되돌립니다(확인을 먼저 묻고, Finder가 다시 시작됩니다).")
			: String(localized: "폴더를 이 작업 전의 보기 설정으로 되돌립니다(확인을 먼저 묻습니다).")
	}

	/// The other record of the same "시스템 전체에 적용".
	static func relatedNote(_ related: OperationOverview) -> String {
		related.isGlobal
			? String(localized: "같은 시스템 전체 적용으로 Finder 기본 보기도 바뀌었습니다(\(time(related.startedAt)) 기록). 그 작업은 따로 되돌리세요.")
			// Only icon positions were written (a home record whose writes all failed has neither count: the folder sentence says 0).
			: related.folderCount == 0 && related.positionsOnlyCount > 0
				? String(localized: "같은 시스템 전체 적용으로 홈 폴더의 아이콘 자리도 새로 잡았습니다(\(time(related.startedAt)) 기록). 그 작업은 따로 되돌리세요.")
			: String(localized: "같은 시스템 전체 적용으로 홈 폴더 \(related.folderCount)개도 바뀌었습니다(\(time(related.startedAt)) 기록). 그 작업은 따로 되돌리세요.")
	}

	// MARK: Deleting records ("지우기")

	/// The confirmation's question: one record, the records chosen in the list, or every record in it.
	static func deleteTitle(_ d: HistoryDeletion) -> String {
		switch d.scope {
		case .one: String(localized: "이 기록을 지울까요?")
		case .chosen: String(localized: "고른 기록을 지울까요?")
		case .all: String(localized: "기록을 모두 지울까요?")
		}
	}

	/// What deleting removes and what it leaves: the backups go with the record, so the operation can no longer be
	/// undone — and nothing in Finder changes, the folders keep the view settings the operation wrote.
	static func deleteMessage(_ d: HistoryDeletion) -> String {
		var lines: [String] = []
		switch d.scope {
		case .one(let item):
			lines.append(title(item) + " · " + fullTime(item.startedAt))
			lines.append(String(localized: "이 기록과 백업 파일을 지웁니다. 지운 뒤에는 이 작업을 되돌릴 수 없습니다."))
		case .chosen:
			lines.append(String(localized: "고른 \(records(d.ids.count))를 백업 파일과 함께 지웁니다. 지운 뒤에는 이 작업들을 되돌릴 수 없습니다."))
		case .all:
			lines.append(String(localized: "목록의 \(records(d.ids.count))를 백업 파일과 함께 지웁니다. 지운 뒤에는 이 작업들을 되돌릴 수 없습니다."))
		}
		if d.inProgress > 0 { lines.append(String(localized: "기록하는 중인 작업은 남겨 둡니다.")) }
		lines.append(String(localized: "폴더의 보기 설정은 그대로 둡니다(지금 모습이 그대로 남습니다)."))
		return lines.joined(separator: "\n")
	}

	/// The details' heading while several records are chosen, and what can be done with them.
	static func chosenTitle(_ n: Int) -> String { String(localized: "\(records(n))를 골랐습니다") }
	static var chosenHint: String {
		String(localized: "고른 기록은 한 번에 지울 수 있습니다(⌫ 키도 됩니다). 자세한 내용과 되돌리기는 하나만 고르면 보입니다.")
	}

	static func records(_ n: Int) -> String { String(localized: "기록 \(n)개") }

	/// Why "지우기…" is disabled, or what it does when it is not.
	static func deleteHelp(_ o: OperationOverview?) -> String {
		guard let o else { return String(localized: "지울 기록을 고르세요.") }
		if o.inProgress { return String(localized: "기록하는 중인 작업은 지울 수 없습니다.") }
		return String(localized: "이 기록과 백업을 지웁니다. 폴더의 보기 설정은 그대로 두고, 이 작업은 되돌릴 수 없게 됩니다.")
	}

	/// The automatic cleanup in one line (`RetentionPolicy.standard`), and its rules for the tooltip.
	static var retentionLine: String {
		let p = RetentionPolicy.standard
		return String(localized: "최근 \(p.maxCount)개 · \(days(p.maxAge))일 · \(megabytes(p.maxBytes))MB를 넘는 오래된 작업은 자동으로 정리됩니다(고정한 작업 제외).")
	}

	static var retentionHelp: String {
		let p = RetentionPolicy.standard
		return String(localized: "앱을 시작할 때와 작업을 기록한 뒤, 최근 \(p.maxCount)개 · \(days(p.maxAge))일 · \(megabytes(p.maxBytes))MB를 넘는 작업과 그 백업을 지웁니다. 고정한 작업, 진행 중인 작업, 가장 최근의 되돌릴 수 있는 폴더 작업과 Finder 기본 보기 작업, 남는 작업을 되돌린 기록은 지우지 않습니다. 지운 작업은 되돌릴 수 없습니다.")
	}

	static func days(_ interval: TimeInterval) -> String {
		let d = interval / 86400
		return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
	}

	static func megabytes(_ bytes: Int64) -> String { String(bytes / (1024 * 1024)) }

	/// The status line after an undo: what was done, behind the line's own "완료: " / "중단: " (its tone comes from those
	/// words). The result view in the sheet says "되돌렸습니다" in its heading already and shows `outcomeBody` alone.
	static func outcomeMessage(_ o: UndoOutcome) -> String {
		let body = outcomeBody(o)
		return o.error == nil ? String(localized: "완료: \(body)") : String(localized: "중단: \(body)")
	}

	/// What an undo did, without the status line's prefix. The folders are counted as everywhere else in the sheet
	/// ("폴더 4개를 되돌림", not "4개 폴더…").
	static func outcomeBody(_ o: UndoOutcome) -> String {
		if o.isGlobal {
			guard o.error == nil else {
				return String(localized: "Finder 기본 보기를 되돌리지 못했습니다: \(o.error ?? "")")
					+ (o.finderRelaunched == false ? " " + String(localized: "Finder가 실행되지 않았습니다. 직접 Finder를 실행해 주세요.") : "")
			}
			if o.recordedOnly {
				return String(localized: "Finder 기본 보기는 이미 이 작업 전의 값이라 Finder를 건드리지 않고 되돌린 것으로 기록했습니다.")
			}
			return String(localized: "Finder 기본 보기를 이 작업 전의 값으로 되돌렸습니다.")
				+ " " + (o.finderRelaunched == false ? String(localized: "Finder 재실행에 실패했습니다. 직접 Finder를 실행해 주세요.")
					: String(localized: "Finder를 다시 시작했습니다."))
		}
		if o.recordedOnly && o.error == nil {
			return String(localized: "폴더 \(o.alreadyRestored.count)개가 모두 이미 적용 전 상태라 아무것도 쓰지 않고 되돌린 것으로 기록했습니다.")
		}
		var parts: [String] = []
		if !o.restored.isEmpty || !o.failed.isEmpty {
			parts.append(String(localized: "\(folders(o.restored.count))를 되돌림")
				+ (o.failed.isEmpty ? "" : String(localized: ", \(o.failed.count)개 실패")))
		}
		if !o.conflicts.isEmpty { parts.append(String(localized: "충돌로 건너뜀 \(o.conflicts.count)개")) }
		if !o.alreadyRestored.isEmpty { parts.append(String(localized: "이미 적용 전 상태 \(o.alreadyRestored.count)개")) }
		if let error = o.error { return error + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")) }
		if o.restored.isEmpty && o.failed.isEmpty { parts.insert(String(localized: "되돌린 폴더 없음"), at: 0) }
		return parts.joined(separator: " · ")
	}

	/// The errors an undo or a pin can meet, worded for the history sheet; the others as everywhere in the app (`ErrorText`).
	static func describe(_ error: any Error) -> String {
		switch error {
		case let refusal as UndoRefusal:
			return refusal.message
		case let e as OperationStoreError:
			switch e {
			case .notFound: return UndoRefusal.notFound.message
			case .inProgress: return UndoRefusal.inProgress.message
			case .unreadable(_, let detail): return UndoRefusal.unreadable(detail).message
			}
		case let e as GlobalApplyError:
			switch e {
			case .finderDidNotQuit, .snapshotIncomplete:
				return ErrorText.describe(e)
			case .verificationFailed(_, let diffs):
				return String(localized: "되돌린 뒤 다시 읽은 값이 다릅니다: \(ErrorText.differences(diffs))")
			case .nothingToApply, .notUndoable:
				return UndoRefusal.nothingToUndo.message
			case .notAlreadyRestored:
				return UndoRefusal.globalChanged.message
			}
		case GlobalDefaultsError.corruptSnapshot:
			return String(localized: "기록한 Finder 기본 보기 값을 읽을 수 없어 되돌리지 않았습니다.")
		default:
			return ErrorText.describe(error)
		}
	}
}

/// "기록": the recorded operations (newest first) with what each did and whether it can be undone, and the undo itself
/// (confirmation with the conflicts, progress, result) in the same fixed-size sheet. Never pushes the window.
struct HistorySheet: View {
	@Environment(AppModel.self) private var model
	/// "자동 정리" in the ⓘ popover of the bottom row.
	@State private var showRetention = false
	/// Fixed size, never resizable: the list on the left, and on the right the details with the preset's preview beside
	/// the folders it changed. Wide enough for a row's plain sentence, for the details' sentences and for the preview
	/// (`PreviewPicture.size`) next to a folder list; short enough to stay on a laptop screen with the window behind it.
	static let size = CGSize(width: 880, height: 540)
	static let listWidth: CGFloat = 352
	/// The details' middle row (the preset's picture and the folders beside it): one fixed height, whatever either shows,
	/// so the sentences above it and "되돌리기…" below it never move. The folder list scrolls inside it when it is longer.
	/// The picture's heading (17) and the caption under it (`captionHeight`, two lines) are part of the row.
	static let previewRowHeight = PreviewPicture.size.height + 17 + 4 + captionHeight
	/// The words under the picture (which view, what was drawn with Finder's defaults): two lines of `.caption`.
	static let captionHeight: CGFloat = 30

	private var running: Bool {
		if case .running = model.undoPhase { return true }
		return false
	}

	private var browsing: Bool {
		switch model.undoPhase {
		case .idle, .preparing: true
		default: false
		}
	}

	var body: some View {
		@Bindable var model = model
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				GradientTile(systemImage: "clock.arrow.circlepath", size: 30)
				VStack(alignment: .leading, spacing: 1) {
					Text(String(localized: "작업 기록")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
					Text(String(localized: "적용하거나 되돌릴 때마다 바뀌기 전 상태가 백업됩니다. 작업을 골라 되돌릴 수 있습니다."))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.tail)
				}
				Spacer(minLength: 8)
				if model.historyLoading {
					ProgressView().controlSize(.small).accessibilityLabel(String(localized: "기록을 읽는 중"))
				}
			}
			Group {
				switch model.undoPhase {
				case .idle, .preparing: HistoryBrowser()
				case .confirm(let pending): UndoConfirmView(pending: pending)
				case .running(let pending): UndoRunningView(pending: pending)
				case .result(let outcome): UndoResultView(outcome: outcome)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			Divider()
			// The sheet's own row: what the automatic cleanup does (ⓘ), the selected operation's other actions (⋯) and
			// "닫기" — an ordinary button, so the only prominent action of the sheet is "되돌리기…" beside the details.
			HStack(spacing: 8) {
				if browsing || isResult {
					retentionInfo
					MoreMenu()
				}
				Spacer(minLength: 8)
				if browsing || isResult {
					Button(String(localized: "닫기")) { model.closeHistory() }
						.accessibilityIdentifier("historyClose")
				}
			}
			.controlSize(.small)
			.frame(height: UILayout.actionRowHeight)
			.probeFrame("historyBottomRow")
		}
		.padding(16)
		.frame(width: Self.size.width, height: Self.size.height)
		.probeFrame("historySheet")
		.sheetSurface()
		.interactiveDismissDisabled(running)
		.relaunchQuestion(isPresented: $model.askRelaunchAfterUndo, after: .undo) { model.relaunchFinder(inHistory: true) }
		// "지우기…" / "기록 모두 지우기…": nothing is removed before "지우기" here, and the dismissal only drops what is
		// still pending (`confirmDeleteHistory` clears it before it deletes).
		.confirmationDialog(Text(deleteQuestion), isPresented: Binding(
			get: { model.pendingHistoryDelete != nil },
			set: { if !$0 { model.pendingHistoryDelete = nil } }), titleVisibility: .visible) {
			Button(String(localized: "지우기"), role: .destructive) { model.confirmDeleteHistory() }
			Button(String(localized: "취소"), role: .cancel) { model.pendingHistoryDelete = nil }
		} message: {
			if let deletion = model.pendingHistoryDelete { Text(HistoryText.deleteMessage(deletion)) }
		}
	}

	/// The delete confirmation's question, while one is pending.
	private var deleteQuestion: String { model.pendingHistoryDelete.map(HistoryText.deleteTitle) ?? "" }

	/// The automatic cleanup, out of the way: a small ⓘ whose tooltip says it in one line and whose popover says what is
	/// removed and what is kept.
	@ViewBuilder private var retentionInfo: some View {
		Button { showRetention = true } label: { Image(systemName: "info.circle") }
			.buttonStyle(.borderless)
			.help(HistoryText.retentionLine)
			.accessibilityLabel(String(localized: "오래된 작업 자동 정리"))
			.accessibilityIdentifier("historyRetention")
			.popover(isPresented: $showRetention, arrowEdge: .top) {
				VStack(alignment: .leading, spacing: 6) {
					Label(String(localized: "오래된 작업 자동 정리"), systemImage: "archivebox")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Text(HistoryText.retentionLine)
						.fixedSize(horizontal: false, vertical: true)
					Text(HistoryText.retentionHelp)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					if model.retentionRemoved > 0 {
						Text(String(localized: "이번 실행에서 정리한 작업: \(model.retentionRemoved)개"))
							.foregroundStyle(.secondary)
					}
				}
				.font(.subheadline)
				.textSelection(.enabled)
				.padding(14)
				.frame(width: 340, alignment: .leading)
			}
	}

	private var isResult: Bool {
		if case .result = model.undoPhase { return true }
		return false
	}
}

/// "⋯": what is done now and then — pinning the selected operation against the automatic cleanup, its backup folder in
/// Finder, and deleting every record at once. Out of the way of "되돌리기…", with the same rules as before (nothing to
/// pin without a selection, no backup folder and nothing to delete without a record).
private struct MoreMenu: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		let selected = model.selectedHistoryItem
		let pinned = selected?.pinned == true
		Menu {
			Button {
				if let selected { Task { await model.setPinned(selected.id, pinned: !selected.pinned) } }
			} label: {
				// The label says what pinning is for: a tooltip on a menu item is rarely seen, and "고정" alone is the
				// word the preset editor uses for the fixed places of sort "없음".
				Label(pinned ? String(localized: "고정 해제") : String(localized: "고정(자동 정리 안 함)"),
				      systemImage: pinned ? "pin.slash" : "pin")
			}
			.disabled(selected == nil || selected?.inProgress == true)
			.help(String(localized: "고정한 작업은 자동 정리에서 지우지 않습니다."))
			.accessibilityIdentifier("historyPin")
			Button {
				model.revealBackups(model.historySelection)
			} label: {
				Label(String(localized: "백업 폴더 보기"), systemImage: "folder")
			}
			.disabled(model.historyItems.isEmpty)
			.help(model.historyItems.isEmpty ? String(localized: "기록된 작업이 없어 열 백업 폴더가 없습니다.")
				: String(localized: "선택한 작업의 백업 폴더(선택이 없으면 모든 작업의 폴더)를 Finder에서 엽니다."))
			.accessibilityIdentifier("historyReveal")
			Divider()
			// Every record at once; one record is deleted by the button beside "되돌리기…". Both ask first.
			Button {
				model.askDeleteAllHistory()
			} label: {
				Label(String(localized: "기록 모두 지우기…"), systemImage: "trash")
			}
			.disabled(model.historyItems.isEmpty)
			.help(String(localized: "목록의 기록과 백업을 모두 지웁니다. 폴더의 보기 설정은 바꾸지 않습니다."))
			.accessibilityIdentifier("historyDeleteAll")
		} label: {
			// Named, not a silent glyph: icon-only buttons were what the user could not find in the toolbar, and this
			// menu is the only way to the two actions. There is room for its name beside "닫기" at this width.
			Label(String(localized: "다른 동작"), systemImage: "ellipsis.circle")
		}
		.labelStyle(.titleAndIcon)
		.fixedSize()
		.help(String(localized: "고정 · 백업 폴더 보기 · 기록 모두 지우기"))
		.accessibilityIdentifier("historyMore")
	}
}

/// The list of records and the selected one's details.
private struct HistoryBrowser: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		HStack(alignment: .top, spacing: 10) {
			VStack(alignment: .leading, spacing: 4) {
				List(model.historyItems, selection: Binding(get: { model.historySelected }, set: {
					model.historySelected = $0
					model.historyNotice = nil
				})) { item in
					HistoryRow(item: item).tag(item.id)
				}
				.onDeleteCommand { model.askDeleteHistory(model.historySelected) }
				.listStyle(.inset)
				.alternatingRowBackgrounds(.disabled)
				.scrollContentBackground(.hidden)
				.scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
				.accessibilityIdentifier("historyList")
				.overlay {
					if model.historyItems.isEmpty && !model.historyLoading {
						EmptyListHint(systemImage: "clock", title: String(localized: "기록된 작업이 없습니다"),
						              message: String(localized: "폴더에 적용하면\n여기에 기록됩니다."))
					}
				}
				.well()
				if !model.historyUnreadable.isEmpty {
					Label(String(localized: "읽지 못한 기록 \(model.historyUnreadable.count)개는 그대로 둡니다"),
					      systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.foregroundStyle(Theme.warning)
						.lineLimit(1)
						.help(model.historyUnreadable.joined(separator: "\n"))
				}
			}
			.frame(width: HistorySheet.listWidth)
			HistoryDetail(item: model.selectedHistoryItem)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}
}

private struct HistoryRow: View {
	let item: OperationOverview

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: HistoryText.symbol(item.kind))
				.font(.system(size: 13))
				.foregroundStyle(OnSelection(tint, selected: Color.white))
				.frame(width: 18)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(HistoryText.title(item))
						.font(.callout.weight(.semibold))
						.lineLimit(1)
						.truncationMode(.middle)
					if item.pinned {
						Image(systemName: "pin.fill")
							.font(.system(size: 9))
							.foregroundStyle(OnSelection(Theme.accentText, selected: Color.white))
							.accessibilityLabel(String(localized: "고정함"))
					}
				}
				// When and where. The time stays whole; a long folder path is cut in the middle, so its last part stays.
				HStack(spacing: 4) {
					Text(HistoryText.time(item.startedAt)).fixedSize()
					if let place = HistoryText.place(item) {
						Text(verbatim: "·").accessibilityHidden(true)
						Text(place).lineLimit(1).truncationMode(.middle)
					}
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)
			}
			.layoutPriority(1)
			Spacer(minLength: 4)
			if let badge = HistoryText.badge(item) {
				Text(badge.text)
					.font(.caption.weight(.medium))
					.foregroundStyle(OnSelection(badge.warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary), selected: Color.white))
					.lineLimit(1)
					.padding(.horizontal, 6)
					.frame(height: 16)
					.overlay(Capsule().strokeBorder(OnSelection(badge.warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(Theme.cardStroke),
					                                            selected: Color.white.opacity(0.6))))
					.fixedSize()
			}
		}
		.padding(.vertical, 1)
		// One element first, then its label and help: a help set before the combine is repeated once per child text, and
		// the combined label would read the "·" of the second line out loud.
		.accessibilityElement(children: .combine)
		.accessibilityLabel(voiceOver)
		.help(HistoryText.title(item) + "\n" + HistoryText.fullTime(item.startedAt)
			+ (HistoryText.placesHelp(item).map { "\n" + $0 } ?? ""))
	}

	/// The row as one sentence for VoiceOver: what it did, when and where, its badge and whether it is pinned.
	private var voiceOver: String {
		[HistoryText.title(item), HistoryText.subtitle(item), HistoryText.badge(item)?.text,
		 item.pinned ? String(localized: "고정함") : nil].compactMap { $0 }.joined(separator: ", ")
	}

	private var tint: AnyShapeStyle {
		switch item.kind {
		case .apply: AnyShapeStyle(Theme.accentText)
		case .applyGlobal: AnyShapeStyle(Theme.warning)
		case .undo, .undoGlobal: AnyShapeStyle(.secondary)
		}
	}
}

/// The selected record: when, where, what it changed, whether it can be undone; "되돌리기…" and "고정".
private struct HistoryDetail: View {
	@Environment(AppModel.self) private var model
	let item: OperationOverview?

	var body: some View {
		Group {
			if let item {
				details(item)
			} else if model.historySelected.count > 1 {
				chosen
			} else {
				VStack(spacing: 8) {
					if model.historyItems.isEmpty {
						// Nothing recorded: say what will show here (the list on the left says there is nothing).
						EmptyListHint(systemImage: "arrow.uturn.backward", title: String(localized: "되돌릴 작업이 아직 없습니다"),
						              message: String(localized: "폴더에 적용하면 여기에\n자세한 내용과 되돌리기가 보입니다."))
					} else {
						EmptyListHint(systemImage: "clock", title: String(localized: "선택한 작업 없음"),
						              message: String(localized: "왼쪽에서 작업을 고르세요."))
					}
					notice
				}
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.well()
		.probeFrame("historyDetailWell")
		// The selected record's own manifest, read once per selection (the list holds overviews only).
		.task(id: model.historySelection) { await model.loadHistoryDetails(model.historySelection) }
	}

	/// Several records chosen (⇧/⌘-click): how many, and the one thing done with them together — deleting.
	@ViewBuilder private var chosen: some View {
		let deletion = HistoryDeletion.chosen(model.historySelected, in: model.historyItems)
		VStack(alignment: .leading, spacing: 8) {
			Label(HistoryText.chosenTitle(model.historySelected.count), systemImage: "checklist")
				.font(.headline)
				.accessibilityIdentifier("historyChosen")
			Text(HistoryText.chosenHint)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			notice
			Spacer(minLength: 0)
			HStack {
				Spacer(minLength: 4)
				Button { model.askDeleteHistory(model.historySelected) } label: { Label(String(localized: "지우기…"), systemImage: "trash") }
					.disabled(deletion == nil)
					.help(deletion == nil ? String(localized: "기록하는 중인 작업은 지울 수 없습니다.")
						: String(localized: "고른 기록과 백업을 지웁니다. 폴더의 보기 설정은 그대로 두고, 이 작업들은 되돌릴 수 없게 됩니다."))
					.accessibilityIdentifier("historyDeleteChosen")
			}
			.controlSize(.small)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.probeFrame("historyChosen")
	}

	/// The selected record's preset and folders, once they are read.
	private var details: HistoryDetails? {
		model.historyDetails.flatMap { $0.id == item?.id ? $0 : nil }
	}

	/// A refused undo or pin, or a folder that could not be opened (shown with or without a selected record).
	@ViewBuilder private var notice: some View {
		if let notice = model.historyNotice {
			Label(notice, systemImage: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundStyle(Theme.warning)
				.lineLimit(2)
				.help(notice)
				.accessibilityIdentifier("historyNotice")
		}
	}

	/// What the operation did, where and when it ran and what can be done about it now — sentences, not a labelled table.
	@ViewBuilder private func details(_ o: OperationOverview) -> some View {
		let inProgress = o.inProgress
		let preparing = model.undoPhase == .preparing(o.id)
		let state = HistoryText.stateSentence(o, undoneAt: undoneTime(o))
		// The picture, the folders and the buttons stay where they are whichever record is chosen: the sentences take
		// what is left above them and scroll in the rare case they need more. (They used to push everything below them
		// down by a line or two, and a record with a notice made the pane taller than the sheet, which moved the sheet's
		// header and bottom row as well.) A notice goes in the row of the buttons it is about.
		VStack(alignment: .leading, spacing: 8) {
			ScrollView {
				VStack(alignment: .leading, spacing: 6) {
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Image(systemName: HistoryText.symbol(o.kind))
							.font(.system(size: 12))
							.foregroundStyle(.secondary)
							.accessibilityHidden(true)
						Text(HistoryText.title(o))
							.font(.headline)
							.lineLimit(2)
							.truncationMode(.middle)
					}
					.help(HistoryText.title(o))
					Text(HistoryText.summarySentence(o))
						.font(.callout)
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)
						.help(HistoryText.placesHelp(o) ?? HistoryText.summarySentence(o))
					Label(state.text, systemImage: state.symbol)
						.font(.subheadline)
						.foregroundStyle(state.warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)
					if let related = model.relatedHistoryItem(o.id) {
						Label(HistoryText.relatedNote(related), systemImage: "link")
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(2)
							.fixedSize(horizontal: false, vertical: true)
							.help(HistoryText.relatedNote(related))
					}
				}
				.frame(maxWidth: .infinity, alignment: .topLeading)
				.probeFrame("historyDetailTextContent")
			}
			.scrollBounceBehavior(.basedOnSize)
			.frame(maxHeight: .infinity, alignment: .top)
			.probeFrame("historyDetailText")
			// What the preset looks like, and which folders it reached: a picture and a list, never more sentences.
			HStack(alignment: .top, spacing: 10) {
				HistoryPreview(item: o, details: details)
				HistoryFolders(item: o, details: details)
			}
			.frame(height: HistorySheet.previewRowHeight, alignment: .topLeading)
			// The prominent action of the sheet: it opens the confirmation, where nothing is written before "되돌리기"
			// (and a global undo is never triggered by Return there).
			HStack(spacing: 8) {
				Button { model.prepareUndo(o.id) } label: { Label(String(localized: "되돌리기…"), systemImage: "arrow.uturn.backward") }
					.buttonStyle(.borderedProminent)
					.disabled(!o.canUndo || inProgress || model.isWorking || preparing)
					.help(HistoryText.undoHelp(o, busy: model.isWorking))
					.accessibilityIdentifier("historyUndo")
				if preparing { ProgressView().controlSize(.small) }
				// A refused undo, pin or delete, in one line beside the buttons (the whole text in its tooltip).
				if let notice = model.historyNotice {
					Label(notice, systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.foregroundStyle(Theme.warning)
						.lineLimit(1)
						.truncationMode(.tail)
						.help(notice)
						.accessibilityIdentifier("historyNotice")
				}
				Spacer(minLength: 4)
				// The record itself, at the other end of the row from the prominent action: it asks first, and it
				// changes no folder — only the record and its backups go.
				Button { model.askDeleteHistory([o.id]) } label: { Label(String(localized: "지우기…"), systemImage: "trash") }
					.disabled(inProgress)
					.help(HistoryText.deleteHelp(o))
					.accessibilityIdentifier("historyDelete")
					.layoutPriority(1)
			}
			.controlSize(.small)
			.frame(height: UILayout.actionRowHeight)
			.probeFrame("historyDetailActions")
		}
	}

	/// When the undo that undid `o` started (it is listed as well).
	private func undoneTime(_ o: OperationOverview) -> Date? {
		guard case .undone(let by) = o.status else { return nil }
		return model.historyItems.first { $0.id == by }?.startedAt
	}

}

/// The preset a record applied, drawn the way the preset editor draws one — on the app's sample folder, never on the
/// folders the operation touched (`PresetPreview`, `PreviewPicture`). One accessibility element with the preview's
/// summary, like the editor's preview window, and under the picture the words the editor puts in its footer (which view,
/// how much is drawn, which options were drawn with Finder's defaults) — the picture's own text is too small at this size
/// to read them there. A record that applied no single preset (an undo record, an apply of several presets at once) says
/// so in one line instead of drawing a wrong picture; so does one whose file could not be read.
private struct HistoryPreview: View {
	@Environment(AppModel.self) private var model
	let item: OperationOverview
	let details: HistoryDetails?
	/// The sample items are dated from the moment the sheet opened, so the picture does not change under the selection.
	@State private var now = Date()

	var body: some View {
		let preview = details?.preset.map {
			PresetPreview.make(settings: $0, defaults: model.previewDefaults, locale: AppLanguage.locale, now: now, measure: PreviewIcons.measure)
		}
		VStack(alignment: .leading, spacing: 4) {
			Text(HistoryText.previewTitle(drawn: preview != nil))
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
			if let preview {
				PreviewPicture(preview: preview)
					.accessibilityElement(children: .ignore)
					.accessibilityAddTraits(.isImage)
					.accessibilityLabel(String(localized: "미리보기"))
					.accessibilityValue(preview.summary)
					.help(help(preview))
					.accessibilityIdentifier("historyPreview")
				// The footer's words, on screen and not only in the tooltip: the view drawn, and that a "유지" value is
				// drawn with Finder's defaults **as they are now**, not as they were when the operation ran.
				Text(caption(preview))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.truncationMode(.tail)
					.frame(width: PreviewPicture.size.width, height: HistorySheet.captionHeight, alignment: .topLeading)
					.help(help(preview))
					.accessibilityIdentifier("historyPreviewCaption")
			} else {
				// The line stands where the picture would, with the button right under it — and the whole takes exactly as
				// much room as picture and caption, so nothing below the row moves when the selection changes.
				// While the manifest is read, the box stays empty: no wrong picture and no line that would be taken back.
				VStack(alignment: .leading, spacing: 6) {
					Text(line)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityIdentifier("historyPreview")
					// An undo record has a preset to show — the one its target applied. The button goes to that record.
					if details != nil, item.isUndo, let undone = undoneOperation {
						Button(HistoryText.showUndone) { model.historySelection = undone }
							.controlSize(.small)
							.accessibilityIdentifier("historyShowUndone")
					}
					Spacer(minLength: 0)
				}
				.frame(width: PreviewPicture.size.width, height: PreviewPicture.size.height + 4 + HistorySheet.captionHeight,
				       alignment: .topLeading)
			}
		}
		.frame(width: PreviewPicture.size.width, alignment: .leading)
		.probeFrame("historyPreview")
	}

	/// Why there is no picture: the record's file could not be read at all, or it holds no one preset to draw.
	private var line: String {
		if model.historyDetailsUnreadable == item.id { return HistoryText.detailsUnreadable }
		guard details != nil else { return "" }
		return item.isUndo && undoneOperation != nil ? HistoryText.noPreviewUndo : HistoryText.noPreview(item)
	}

	/// The operation this undo record undid, when it is still listed.
	private var undoneOperation: UUID? {
		guard let id = item.undoOfOperationID, model.historyItems.contains(where: { $0.id == id }) else { return nil }
		return id
	}

	private func caption(_ preview: PresetPreview) -> String {
		[preview.footerLeading, preview.scaleBadge, preview.countBadge].compactMap { $0 }.joined(separator: " · ")
	}

	private func help(_ preview: PresetPreview) -> String {
		([caption(preview), preview.footerTrailing] + preview.details).joined(separator: "\n")
	}
}

/// The folders the operation changed (an undo record: the ones it put back), read from its manifest for the selected
/// record only: under the roots it ran on when there are several, in the order it wrote them, at most
/// `ChangedFolders`'s cap and then "외 N개". A global operation changed Finder's default view instead and says so.
/// The folders it skipped or could not write keep their counts line, whose tooltip names them.
private struct HistoryFolders: View {
	let item: OperationOverview
	let details: HistoryDetails?

	var body: some View {
		let folders = details?.folders
		VStack(alignment: .leading, spacing: 4) {
			Text(HistoryText.foldersTitle(item, count: folders?.total ?? item.folderCount))
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
			if !item.isGlobal, let folders, !folders.isEmpty {
				list(folders)
			}
			if let counts = HistoryText.countsLine(item) {
				Text(counts)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.help(HistoryText.countsHelp(item, details) ?? counts)
					.accessibilityIdentifier("historyCounts")
			}
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("historyFolders")
		.probeFrame("historyFolders")
	}

	/// The rows: a heading per root, which names the long path once, and under it each folder by its own name and where it
	/// sits **inside** that root — so the column shows the shape of what was changed instead of repeating one path per line.
	@ViewBuilder private func list(_ folders: ChangedFolders) -> some View {
		let roots = folders.shown.map(\.root)
		ScrollView {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(Array(folders.shown.enumerated()), id: \.element.id) { i, folder in
					if !folder.root.isEmpty, i == 0 || roots[i - 1] != folder.root {
						Text(Fmt.abbreviate(folder.root))
							.font(.caption.weight(.semibold))
							.lineLimit(1)
							.truncationMode(.middle)
							.padding(.top, i == 0 ? 0 : 4)
							.help(folder.root)
					}
					row(folder)
				}
				if let more = HistoryText.moreFolders(folders.hidden) {
					Text(more).font(.caption).foregroundStyle(.secondary).lineLimit(1)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.scrollBounceBehavior(.basedOnSize)
	}

	private func row(_ folder: ChangedFolders.Item) -> some View {
		let shown = HistoryText.folderRow(folder.path, under: folder.root)
		// One element first, then its help: a help set before the combine is repeated once per child text (as in HistoryRow).
		return HStack(spacing: 4) {
			Image(systemName: "folder")
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			Text(shown.name)
				.font(.caption)
				.lineLimit(1)
				.truncationMode(.middle)
				.layoutPriority(1)
			if !shown.place.isEmpty {
				Text(shown.place)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
		.accessibilityElement(children: .combine)
		.help(Fmt.abbreviate(folder.path))
	}
}

/// "되돌릴까요?": what the undo will do (and skip) before anything is written.
private struct UndoConfirmView: View {
	@Environment(AppModel.self) private var model
	let pending: PendingUndo

	var body: some View {
		let o = pending.overview
		VStack(alignment: .leading, spacing: 8) {
			// The sheet is as tall as the details' pane needs; a confirmation of four lines sits in the middle of it rather
			// than at the top with the buttons a screen away from the sentence they confirm.
			Spacer(minLength: 0)
			HStack(spacing: 10) {
				GradientTile(systemImage: pending.isGlobal ? "macwindow" : "arrow.uturn.backward", size: 26)
				VStack(alignment: .leading, spacing: 1) {
					Text(String(localized: "되돌릴까요?")).font(.headline)
					Text(verbatim: HistoryText.title(o) + " · " + HistoryText.fullTime(o.startedAt))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			if let global = pending.global {
				globalBody(global)
			} else {
				folderBody
			}
			if let related = pending.related {
				Label(HistoryText.relatedNote(related), systemImage: "link")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
			HStack(spacing: 8) {
				Spacer()
				Button(String(localized: "취소"), role: .cancel) { model.cancelUndo() }
					.keyboardShortcut(.cancelAction)
					.accessibilityIdentifier("undoCancel")
				if pending.recordsOnly {
					// Writes nothing (Finder is left alone): only the record.
					Button(String(localized: "되돌린 것으로 기록")) { model.confirmUndo() }
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
						.disabled(model.isWorking)
						.accessibilityIdentifier("undoConfirm")
				} else if pending.isGlobal {
					// Restarts Finder: a click, never Return.
					Button(String(localized: "되돌리기 (Finder 다시 시작)")) { model.confirmUndo() }
						.buttonStyle(.borderedProminent)
						.disabled(!pending.canConfirm || model.isWorking)
						.accessibilityIdentifier("undoConfirm")
				} else {
					Button(String(localized: "되돌리기")) { model.confirmUndo() }
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
						.disabled(!pending.canConfirm || model.isWorking)
						.accessibilityIdentifier("undoConfirm")
				}
			}
			.controlSize(.small)
		}
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("undoConfirmation")
	}

	@ViewBuilder private var folderBody: some View {
		let roots = pending.overview.roots
		VStack(alignment: .leading, spacing: 6) {
			if pending.recordsOnly {
				Text(String(localized: "폴더 \(pending.alreadyRestored.count)개가 모두 이미 적용 전 상태입니다. 아무것도 쓰지 않고 이 작업을 되돌린 것으로 기록합니다."))
					.font(.callout.weight(.semibold))
					.fixedSize(horizontal: false, vertical: true)
			} else if pending.restorable.isEmpty {
				Text(String(localized: "되돌릴 폴더가 없습니다. 아무것도 바꾸지 않습니다."))
					.font(.callout.weight(.semibold))
			} else {
				// Folders whose icon positions alone changed get no view settings back: they are named apart.
				let views = pending.restorable.count - pending.restorablePositionsOnly
				if views > 0 {
					Text(String(localized: "\(views)개 폴더를 이 작업 전의 보기 설정으로 되돌립니다."))
						.font(.callout)
						.fixedSize(horizontal: false, vertical: true)
				}
				if pending.restorablePositionsOnly > 0 {
					Text(String(localized: "\(pending.restorablePositionsOnly)개 폴더의 아이콘 자리를 이 작업 전으로 되돌립니다."))
						.font(.callout)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			if !roots.isEmpty {
				Text(String(localized: "대상: \(roots.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.tail)
					.help(roots.map(Fmt.abbreviate).joined(separator: "\n"))
			}
			if !pending.alreadyRestored.isEmpty && !pending.recordsOnly {
				Text(String(localized: "\(pending.alreadyRestored.count)개 폴더는 이미 적용 전 상태라 그대로 둡니다."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			if !pending.unreadable.isEmpty {
				PathListBox(title: String(localized: "읽지 못함 \(pending.unreadable.count)개: 설정 파일(.DS_Store)을 읽을 수 없어 되돌리지 못합니다(실패로 기록)."),
				            paths: pending.unreadable, identifier: "undoUnreadable")
			}
			if !pending.conflicts.isEmpty {
				PathListBox(title: String(localized: "충돌 \(pending.conflicts.count)개: 적용한 뒤 보기 설정이 다시 바뀐 폴더는 건너뜁니다(그 뒤의 변경을 지킵니다)."),
				            paths: pending.conflicts, identifier: "undoConflicts")
			}
			Label(String(localized: "Finder는 다시 시작하지 않습니다. 끝나면 다시 시작할지 묻습니다. 되돌리기도 기록되고 백업됩니다."), systemImage: "info.circle")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	@ViewBuilder private func globalBody(_ g: PendingUndo.GlobalInfo) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if g.alreadyRestored {
				Text(String(localized: "Finder 기본 보기는 이미 이 작업 전의 값입니다. Finder를 건드리지 않고 이 작업을 되돌린 것으로 기록합니다."))
					.font(.callout.weight(.semibold))
					.fixedSize(horizontal: false, vertical: true)
			} else {
				Text(String(localized: "Finder 기본 보기를 이 작업 전의 값(\(HistoryText.time(g.recordedAt)) 기록)으로 되돌립니다. Finder가 자동으로 다시 시작됩니다."))
					.font(.callout)
					.fixedSize(horizontal: false, vertical: true)
			}
			Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
				GridRow {
					Text(String(localized: "지금")).foregroundStyle(.secondary)
					Text(PresetRow.summary(g.current)).lineLimit(1)
				}
				GridRow {
					Text(String(localized: "되돌릴 값")).foregroundStyle(.secondary)
					Text(PresetRow.summary(g.restored)).lineLimit(1)
				}
			}
			.font(.subheadline)
			if !g.alreadyRestored {
				RestartNote(text: String(localized: "열려 있는 Finder 창은 닫혔다가 다시 열립니다(검색·최근 항목 창 제외).\n진행 중인 복사나 이동이 있으면 끝난 뒤에 하세요.\n되돌리기 전 상태도 자동으로 백업됩니다."))
				.accessibilityElement(children: .combine)
				.accessibilityIdentifier("undoGlobalWarning")
			}
		}
	}
}

private struct UndoRunningView: View {
	let pending: PendingUndo

	var body: some View {
		VStack(spacing: 10) {
			ProgressView().controlSize(.regular)
			Text(pending.isGlobal ? String(localized: "Finder를 종료하고 Finder 기본 보기를 되돌리는 중… (Finder가 다시 시작됩니다)")
				: String(localized: "\(pending.restorable.count)개 폴더를 되돌리는 중…"))
				.font(.callout)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.accessibilityElement(children: .combine)
	}
}

private struct UndoResultView: View {
	@Environment(AppModel.self) private var model
	let outcome: UndoOutcome

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Centred like the confirmation: the result is two lines in the sheet the details' pane sets the height of.
			Spacer(minLength: 0)
			HStack(alignment: .top, spacing: 10) {
				Image(systemName: outcome.succeeded && outcome.conflicts.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
					.font(.system(size: 22))
					.foregroundStyle(outcome.succeeded && outcome.conflicts.isEmpty ? Theme.success : Theme.warning)
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 2) {
					Text(outcome.error != nil ? String(localized: "되돌리지 못했습니다")
						: (outcome.recordedOnly ? String(localized: "되돌린 것으로 기록했습니다") : String(localized: "되돌렸습니다")))
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					// Without the status line's "완료: " / "중단: ": the heading above already says how it went.
					Text(HistoryText.outcomeBody(outcome))
						.font(.callout)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityIdentifier("undoResultMessage")
				}
			}
			if !outcome.conflicts.isEmpty {
				PathListBox(title: String(localized: "충돌로 건너뛴 폴더(적용한 뒤 다시 바뀜):"),
				            paths: outcome.conflicts, identifier: "undoResultConflicts")
			}
			if !outcome.failed.isEmpty {
				PathListBox(title: String(localized: "되돌리지 못한 폴더:"), paths: outcome.failed, identifier: "undoResultFailed")
			}
			if !outcome.isGlobal && !outcome.restored.isEmpty {
				Label(String(localized: "이미 열어본 폴더는 Finder를 다시 시작해야 되돌린 모양이 보입니다."),
				      systemImage: "info.circle")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
			HStack {
				Spacer()
				Button(String(localized: "목록으로")) { model.closeUndoResult() }
					.controlSize(.small)
					.accessibilityIdentifier("undoResultDone")
			}
		}
	}
}

/// A titled warning box with a short scrolling list of folders (abbreviated, whole path in the tooltip).
private struct PathListBox: View {
	let title: String
	let paths: [String]
	let identifier: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(title, systemImage: "exclamationmark.triangle.fill")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Theme.warning)
				.fixedSize(horizontal: false, vertical: true)
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					ForEach(paths, id: \.self) { path in
						Text(Fmt.abbreviate(path))
							.font(.subheadline)
							.lineLimit(1)
							.truncationMode(.middle)
							.help(Fmt.abbreviate(path))
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.scrollBounceBehavior(.basedOnSize)
			.frame(maxHeight: 64)
			.fixedSize(horizontal: false, vertical: true)
		}
		.warningBox()
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier(identifier)
	}
}

extension View {
	/// "Finder를 다시 시작할까요?" after folders were written (an apply, a folder undo: `after` names what the restart
	/// shows). "지금 다시 시작" quits and launches Finder; "나중에" leaves it alone.
	func relaunchQuestion(isPresented: Binding<Bool>, after reason: RelaunchReason, relaunch: @escaping () -> Void) -> some View {
		alert(String(localized: "Finder를 다시 시작할까요?"), isPresented: isPresented) {
			Button(String(localized: "지금 다시 시작")) { relaunch() }
			Button(String(localized: "나중에"), role: .cancel) {}
		} message: {
			Text(reason == .undo
				? String(localized: "이미 열어본 폴더는 Finder를 다시 시작해야 되돌린 보기 설정이 보입니다. 열려 있던 Finder 창은 다시 열립니다(검색·최근 항목 창 제외).")
				: String(localized: "이미 열어본 폴더는 Finder를 다시 시작해야 새 보기 설정이 보입니다. 열려 있던 Finder 창은 다시 열립니다(검색·최근 항목 창 제외)."))
		}
	}
}

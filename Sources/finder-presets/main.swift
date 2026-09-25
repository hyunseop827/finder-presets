import Foundation
import FinderPresetsCore

// Minimal CLI used for integration testing of FinderPresetsCore against the real Finder.
// Data lives in ~/Library/Application Support/FinderPresets (override with FINDER_PRESETS_DATA_DIR).

let dirs = AppDirectories.standard   // honours FINDER_PRESETS_DATA_DIR
let presetStore = PresetStore(dirs: dirs)
let ruleStore = RuleStore(dirs: dirs)
let opStore = OperationStore(dirs: dirs)
let globals = GlobalDefaults.readCurrent()

func usage() -> Never {
	print("""
	finder-presets — Finder Presets CLI (integration testing)

	  show <folder>                         현재 보기 설정 (폴더 고유 / 상속)
	  preset-from <folder> <name>           폴더의 현재 설정을 프리셋으로 저장
	  preset-set <name> key=value ...       프리셋 필드 수정 (viewStyle=icon|list|column|gallery, groupBy=kind, icon.iconSize=88, icon.arrangeBy=name, list.sortColumn=dateModified, list.sortAscending=false ...)
	                                        groupBy: none, kind, application, dateLastOpened, dateAdded, dateModified, dateCreated, size (Finder 문자열 "Kind" 등도 받음). 값 "-" 는 유지
	  presets                               프리셋 목록
	  preset-export <name> <file.json> / preset-import <file.json>
	  rule-set <folder> <preset> [--no-subfolders] / rule-clear <folder> / rules
	  analyze <preset> <root>... [--depth N] [--pin-defaults]
	  apply <preset> <root>... [--depth N] [--pin-defaults] [--relaunch]
	                                        --relaunch: Finder를 종료한 뒤 쓰고 다시 실행한다 (종료되지 않으면 쓰지 않음). 열려 있던 Finder 창은 다시 연다
	  undo [<opId>|last] [--force] [--yes]  폴더 적용 되돌리기. 데이터 폴더·대상을 보여 준 뒤 확인한다 (--yes: 묻지 않음)
	                                        last = 아직 되돌리지 않은 가장 최근의 폴더 적용. 이미 되돌린 작업은 --force 가 있어야 다시 되돌린다
	  ops [--prune [정책]]                  작업 목록 (되돌리기 상태, 고정). --prune: 보관 정책으로 지울 작업 미리보기 (지우지 않음)
	  prune [--yes] [정책]                  보관 정책으로 오래된 작업과 그 백업을 지운다. 목록을 보여 준 뒤 확인한다 (--yes: 묻지 않음)
	                                        정책: --max-count N (기본 50) --max-age-days D (기본 30, 최대 36500) --max-mb M (기본 200)
	  pin <opId> / unpin <opId>             작업 고정 / 고정 해제 (고정한 작업은 정리하지 않음)
	  relaunch-finder                       Finder 재실행 (열려 있던 Finder 창은 다시 연다). 어느 작업 뒤인지 모르므로 종료하는 Finder가 창이 열린 폴더를 덮어써도 다시 쓰지 않는다 (적용이면 apply --relaunch)
	  global-show                           Finder 전역 기본 보기 설정 요약 (읽기 전용)
	  global-apply <preset> --i-understand-finder-restarts
	                                        프리셋을 전역 기본값(com.apple.finder)에 적용 (그룹 기준 제외). Finder를 종료했다가 다시 실행한다
	  global-undo [<opId>|last] --i-understand-finder-restarts
	                                        전역 적용 되돌리기 (마찬가지로 Finder를 다시 실행한다)

	데이터 폴더: \(dirs.root.path)\(ProcessInfo.processInfo.environment["FINDER_PRESETS_DATA_DIR"] == nil ? " (FINDER_PRESETS_DATA_DIR 로 바꿀 수 있음)" : " (FINDER_PRESETS_DATA_DIR)")
	""")
	exit(2)
}

/// " (Finder 창 N개를 다시 열었습니다)" after a restart that opened Finder's windows again; "" when none was open.
func reopenedNote(_ windows: [URL]) -> String {
	windows.isEmpty ? "" : " (Finder 창 \(windows.count)개를 다시 열었습니다)"
}

/// Asks on an interactive terminal; a script must pass `--yes` (nothing is undone silently).
func confirm(_ question: String, yes: Bool) -> Bool {
	if yes { return true }
	guard isatty(STDIN_FILENO) != 0 else {
		print("확인이 필요합니다. 터미널에서 실행하거나 --yes 를 붙이세요.")
		return false
	}
	print("\(question) [y/N] ", terminator: ""); fflush(stdout)
	let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
	return answer == "y" || answer == "yes"
}

let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

func fmt(_ s: ViewSettings) -> String {
	var parts: [String] = []
	parts.append("view=\(s.viewStyle?.rawValue ?? "-")")
	let i = s.icon
	parts.append("icon[size=\(i.iconSize.map { "\($0)" } ?? "-") text=\(i.textSize.map { "\($0)" } ?? "-") sort=\(i.arrangeBy?.rawValue ?? "-") labelBottom=\(i.labelOnBottom.map { "\($0)" } ?? "-") info=\(i.showItemInfo.map { "\($0)" } ?? "-") preview=\(i.showIconPreview.map { "\($0)" } ?? "-") grid=\(i.gridSpacing.map { "\($0)" } ?? "-")]")
	let l = s.list
	parts.append("list[text=\(l.textSize.map { "\($0)" } ?? "-") icon=\(l.iconSize.map { "\($0)" } ?? "-") sort=\(l.sortColumn?.rawValue ?? "-") asc=\(l.sortAscending.map { "\($0)" } ?? "-") preview=\(l.showIconPreview.map { "\($0)" } ?? "-") relativeDates=\(l.useRelativeDates.map { "\($0)" } ?? "-") allSizes=\(l.calculateAllSizes.map { "\($0)" } ?? "-")]")
	// The grouping (GRP0) as Finder spells it, quoted: "Date Modified" has a space.
	parts.append("group=\(s.groupBy.map { "\"\($0.rawValue)\"" } ?? "-")")
	return parts.joined(separator: " ")
}

func folderURL(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }

func loadPreset(_ name: String) throws -> Preset {
	guard let p = try presetStore.find(name: name) else { print("프리셋 없음: \(name)"); exit(1) }
	return p
}

func makePlan(presetName: String, args: [String]) throws -> (Preset, Plan) {
	var roots: [URL] = []
	var depth: Int? = nil
	var pin = false
	var it = args.makeIterator()
	while let a = it.next() {
		switch a {
		case "--depth": depth = Int(it.next() ?? "") ?? nil
		case "--pin-defaults": pin = true
		case "--relaunch": break
		default: roots.append(folderURL(a))
		}
	}
	guard !roots.isEmpty else { usage() }
	// With subfolders the scan would reach every folder of the home folder (Desktop included); only the root itself is unsupported.
	let tooWide = roots.filter { HomeFolders.isHomeOrAncestor($0.path) }
	guard tooWide.isEmpty else {
		print("홈 폴더와 그 상위 폴더는 대상으로 쓸 수 없습니다: \(tooWide.map(\.path).joined(separator: ", ")). 그 안의 폴더를 지정하세요.")
		exit(1)
	}
	let preset = try loadPreset(presetName)
	let rules = try ruleStore.load()
	let presets = try presetStore.list()
	let resolver = RuleResolver(rules: rules.rules, defaultPresetID: preset.id)
	let planner = Planner(presets: presets, resolver: resolver, globals: globals, options: PlanOptions(pinInheritedDefaults: pin))
	let scanned = FolderScanner(options: ScanOptions(maxDepth: depth, excludedPaths: ScanOptions.defaultExclusions())).scan(roots: roots)
	return (preset, planner.plan(scanned: scanned, roots: roots))
}

func printPlan(_ plan: Plan) {
	let c = plan.counts
	print("분석: \(plan.entries.count)개 폴더 — 이미 동일 \(c[.alreadyMatching] ?? 0) / 변경 \(c[.willChange] ?? 0) / 읽지 못함 \(c[.unreadable] ?? 0) / 제외 \(c[.excluded] ?? 0) / 권한 없음 \(c[.permissionDenied] ?? 0) / 미지원 \(c[.unsupported] ?? 0)"
		+ (c[.iconPositionsOnly].map { " / 아이콘 자리만 \($0)" } ?? ""))
	// The positions Finder stored would put the new icon size at the old places.
	if plan.iconPositionResets > 0 {
		print("아이콘 자리 새로 잡기: \(plan.iconPositionResets)개 폴더 (정렬 없음·자동 격자 정렬에서 아이콘 크기나 간격이 바뀌어 겹치지 않도록 저장된 아이콘 위치를 지웁니다. 되돌리기로 복원)")
	}
	for e in plan.entries {
		let indent = String(repeating: "  ", count: e.depth)
		var line = "\(indent)\(e.folder.lastPathComponent)  [\(e.category.rawValue)]"
		if let r = e.reason { line += " \(r)" }
		switch e.ruleSource {
		case .exactRule: line += " (규칙)"
		case .inheritedRule(_, let from): line += " (상속: \(URL(fileURLWithPath: from).lastPathComponent))"
		default: break
		}
		if !e.diffs.isEmpty { line += "  " + e.diffs.map { "\($0.field): \($0.current ?? "미설정") → \($0.target)" }.joined(separator: ", ") }
		if e.resetsIconPositions { line += "  (아이콘 자리 새로 잡음)" }
		print(line)
	}
}

func printOp(_ op: FinderPresetsOperation) {
	let s = op.summary
	print("작업 \(op.id.uuidString) [\(op.kind.rawValue)] 변경 \(s.changed) / 건너뜀 \(s.skipped) / 실패 \(s.failed)"
		+ (s.positionsOnly > 0 ? " / 아이콘 자리만 \(s.positionsOnly)" : ""))
	for e in op.entries where e.status == .failed || e.status == .skippedConflict {
		print("  \(e.status.rawValue): \(e.folderPath) — \(e.error ?? "")")
	}
	let positions = op.entries.filter { $0.iconPositions != nil }.count
	if positions > 0 { print("아이콘 위치를 바꾼 폴더 \(positions)개") }
	for e in op.entries where e.iconPositionsError != nil {
		print("  아이콘 위치는 그대로: \(e.folderPath) — \(e.iconPositionsError ?? "")")
	}
}

// MARK: Operations: history, undo status, retention

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .binary) }   // 1024-based, like --max-mb

/// An operation by ID: from the history when it is there, otherwise read from disk (clear error when there is none).
func findOperation(_ id: UUID, in history: OperationHistory) throws -> FinderPresetsOperation {
	if let op = history.operation(id) { return op }
	let manifest = opStore.directory(for: id).appendingPathComponent(OperationStore.manifestFileName)
	guard FileManager.default.fileExists(atPath: manifest.path) else { throw OperationStoreError.notFound(id) }
	return try opStore.load(id: id)
}

/// The operation an undo command names: "last" is the newest undoable one of its kind, anything else a UUID. Prints
/// `noneLeft` and stops when there is nothing to undo.
func operationToUndo(_ which: String, global: Bool, noneLeft: String, in history: OperationHistory) throws -> FinderPresetsOperation {
	guard which != "last" else {
		guard let last = history.latestUndoable(global: global) else { print(noneLeft); exit(1) }
		return last
	}
	guard let id = UUID(uuidString: which) else { usage() }
	return try findOperation(id, in: history)
}

/// `OperationHistory`'s verdict in words (the same rules the app uses).
func undoStatusText(_ o: OperationOverview) -> String {
	var text: String
	switch o.status {
	case .undoable: text = o.isUndo ? "다시 적용할 수 있음" : "되돌릴 수 있음"
	case .undone(let by): text = "되돌림 (작업 \(by.uuidString))"
	case .nothingToUndo: text = o.isGlobal ? "되돌릴 것 없음 (스냅샷 없음)" : "되돌릴 것 없음 (바뀐 폴더 없음)"
	}
	if o.isUndo { text = "되돌리기 작업 (대상 \(o.undoOfOperationID?.uuidString ?? "?")) · " + text }
	if o.foundAlreadyRestored { text += " · 이미 적용 전 상태라 아무것도 쓰지 않음" }
	return text
}

@MainActor func overviewLine(_ o: OperationOverview) -> String {
	"\(o.id.uuidString)  \(o.kind.rawValue)  \(dateFmt.string(from: o.startedAt))  preset=\(o.presetName ?? "-")"
}

/// An operation without `finishedAt` is still being written (the app or another finder-presets: `FinderPresetsOperation.isInProgress`) or was
/// left behind (a crash, a forced quit, a failed save); the folders it recorded can be undone, but not while it is written.
func unfinishedNote(_ op: FinderPresetsOperation) -> String {
	if op.isInProgress() {
		if let writer = op.writer {
			return "주의: 이 작업을 쓰는 프로그램(pid \(writer.pid))이 아직 실행 중입니다. 끝난 뒤에 되돌리세요."
		}
		return "주의: 이 작업은 끝났다는 기록이 없습니다 (아직 진행 중이거나 중간에 멈춤). 앱이나 다른 finder-presets 이 아직 적용 중이면 끝난 뒤에 되돌리세요."
	}
	return "주의: 이 작업은 끝났다는 기록이 없습니다 (쓰던 프로그램이 중간에 멈춤). 기록된 폴더만 되돌립니다."
}

func targetText(_ o: OperationOverview) -> String {
	if o.isGlobal { return "Finder 기본 보기" }
	return o.roots.isEmpty ? "(없음)" : o.roots.joined(separator: ", ")
}

/// `--max-count N`, `--max-age-days D`, `--max-mb M` on top of the app's policy; any other argument
/// must be in `allowed`.
func retentionPolicy(_ args: ArraySlice<String>, allowed: Set<String>) -> RetentionPolicy {
	var policy = RetentionPolicy.standard
	func bad(_ flag: String) -> Never { print("\(flag) 뒤에 0 이상의 숫자를 주세요."); exit(2) }
	var it = args.makeIterator()
	while let a = it.next() {
		switch a {
		case "--max-count":
			guard let v = it.next().flatMap({ Int($0) }), v >= 0 else { bad(a) }
			policy.maxCount = v
		case "--max-age-days":
			// Up to 100 years: a larger age keeps everything anyway, and days() prints it as a whole number.
			guard let v = it.next().flatMap({ Double($0) }), v.isFinite, v >= 0, v <= 36_500 else { print("\(a) 뒤에 0 이상 36500 이하의 숫자를 주세요."); exit(2) }
			policy.maxAge = v * 86400
		case "--max-mb":
			guard let v = it.next().flatMap({ Int64($0) }), v >= 0, v <= Int64.max / (1024 * 1024) else { bad(a) }
			policy.maxBytes = v * 1024 * 1024
		default:
			guard allowed.contains(a) else { print("알 수 없는 인자: \(a)"); usage() }
		}
	}
	return policy
}

func reasonText(_ r: RetentionPlan.Reason, _ p: RetentionPolicy) -> String {
	switch r {
	case .tooOld: "\(days(p.maxAge))일 지남"
	case .overCount: "최근 \(p.maxCount)개 밖"
	case .overSize: "\(bytes(p.maxBytes)) 초과"
	}
}

func protectionText(_ p: RetentionPlan.Protection) -> String {
	switch p {
	case .pinned: "고정함"
	case .inProgress: "진행 중"
	case .latestUndoable: "가장 최근의 되돌릴 수 있는 작업"
	case .undoOfKeptOperation: "남는 작업을 되돌린 기록"
	}
}

/// "48", "48.5" (Int(d) traps beyond Int's range: only small whole numbers are printed as integers).
func number(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }

func days(_ interval: TimeInterval) -> String {
	let d = interval / 86400
	// Int(d) traps beyond Int's range: only small whole numbers are printed as integers.
	return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%.1f", d)
}

@MainActor func printRetention(_ plan: RetentionPlan) {
	let p = plan.policy
	print("데이터 폴더: \(dirs.root.path)")
	print("보관 정책: 최근 \(p.maxCount)개 · \(days(p.maxAge))일 · \(bytes(p.maxBytes)). 고정한 작업, 진행 중인 작업, 가장 최근의 되돌릴 수 있는 폴더·전역 작업, 남는 작업을 되돌린 기록은 지우지 않습니다.")
	let removed = plan.removed
	if removed.isEmpty {
		print("지울 작업 없음")
	} else {
		print("지울 작업 \(removed.count)개 (\(bytes(plan.removedBytes))):")
		for item in removed {
			print("  \(overviewLine(item.overview))  \(bytes(item.bytes))  이유: \(item.reasons.map { reasonText($0, p) }.joined(separator: ", "))")
		}
	}
	let protected = plan.protected
	if !protected.isEmpty {
		print("지우지 않고 지키는 작업 \(protected.count)개:")
		for item in protected {
			let over = item.reasons.isEmpty ? "" : " (정책으로는 \(item.reasons.map { reasonText($0, p) }.joined(separator: ", ")))"
			print("  \(overviewLine(item.overview))  \(bytes(item.bytes))  \(item.protection.map(protectionText) ?? "")\(over)")
		}
	}
	print("남는 작업 \(plan.kept.count)개 (\(bytes(plan.keptBytes)))")
	if !plan.unreadable.isEmpty {
		print("읽지 못한 작업 기록 \(plan.unreadable.count)개는 그대로 둡니다:")
		for u in plan.unreadable { print("  \(u)") }
	}
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
do {
	switch cmd {
	case "show":
		guard args.count >= 2 else { usage() }
		let loc = try ParentStoreLocator.locate(folderURL(args[1]))
		let state = try Planner.readState(at: loc, globals: globals)
		print("폴더: \(loc.folder.path)\n설정 파일: \(loc.storeURL.path) (키 \"\(loc.key)\")")
		print("폴더 고유: \(state.hasExplicitRecords ? fmt(state.explicit) : "없음 (Finder 기본값 사용)")")
		print("실효 값 : \(fmt(state.effective))")
		if let r = state.records { print("레코드  : \(r.records.map(\.type).joined(separator: ", "))") }

	case "preset-from":
		guard args.count >= 3 else { usage() }
		let loc = try ParentStoreLocator.locate(folderURL(args[1]))
		let state = try Planner.readState(at: loc, globals: globals)
		var settings = state.explicit
		if !state.hasExplicitRecords { print("경고: 폴더 고유 설정이 없어 실효 값(전역 기본값 포함)을 저장합니다."); settings = state.effective }
		let p = Preset(name: args[2], settings: settings)
		try presetStore.save(p)
		print("저장: \(p.name) — \(fmt(p.settings))")

	case "preset-set":
		guard args.count >= 3 else { usage() }
		var p = try loadPreset(args[1])
		for kv in args.dropFirst(2) {
			let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
			guard parts.count == 2 else { continue }
			let (k, v) = (parts[0], parts[1])
			// A number is checked against the app editor's ranges (PresetLimits), but refused rather than clamped as the
			// editor does: a script gets an error instead of a value it did not ask for.
			// "-" (or nothing) leaves the option alone.
			let limits: (range: ClosedRange<Double>?, sizes: [Double]?, whole: Bool)? = switch k {
				case "icon.iconSize": (PresetLimits.iconSize, nil, false)
				case "icon.textSize", "list.textSize": (PresetLimits.textSize, nil, true)
				case "icon.gridSpacing": (PresetLimits.gridSpacing, nil, false)
				case "list.iconSize": (nil, PresetLimits.listIconSizes, false)
				default: nil
			}
			if let limits, !v.isEmpty, v != "-" {
				let allowed = limits.range.map { "\(number($0.lowerBound))–\(number($0.upperBound))" }
					?? (limits.sizes ?? []).map(number).joined(separator: " 또는 ")
				guard let n = Double(v), n.isFinite, limits.range.map({ $0.contains(n) }) ?? true, limits.sizes.map({ $0.contains(n) }) ?? true,
				      !limits.whole || n == n.rounded() else {
					print("오류: \(k)=\(v) 은(는) 쓸 수 없습니다 (\(allowed)\(limits.whole ? " 사이의 정수" : "")). 저장하지 않았습니다.")
					exit(1)
				}
			}
			let d = Double(v); let b = Bool(v)
			switch k {
			case "viewStyle": p.settings.viewStyle = ViewStyle.allCases.first { "\($0)" == v } ?? ViewStyle(rawValue: v)
			case "groupBy":
				// The case name ("dateModified") or Finder's own string ("Date Modified"); "-" (or nothing) is "유지".
				if v.isEmpty || v == "-" {
					p.settings.groupBy = nil
				} else if let g = GroupBy.allCases.first(where: { "\($0)" == v }) ?? GroupBy(rawValue: v) {
					p.settings.groupBy = g
				} else {
					print("오류: groupBy=\(v) 은(는) 쓸 수 없습니다 (\(GroupBy.allCases.map { "\($0)" }.joined(separator: ", "))). 저장하지 않았습니다.")
					exit(1)
				}
			case "icon.iconSize": p.settings.icon.iconSize = d
			case "icon.textSize": p.settings.icon.textSize = d
			case "icon.gridSpacing": p.settings.icon.gridSpacing = d
			case "icon.labelOnBottom": p.settings.icon.labelOnBottom = b
			case "icon.showItemInfo": p.settings.icon.showItemInfo = b
			case "icon.showIconPreview": p.settings.icon.showIconPreview = b
			case "icon.arrangeBy": p.settings.icon.arrangeBy = SortKey(rawValue: v)
			case "list.textSize": p.settings.list.textSize = d
			case "list.iconSize": p.settings.list.iconSize = d
			case "list.sortColumn": p.settings.list.sortColumn = ListColumn(rawValue: v)
			case "list.sortAscending": p.settings.list.sortAscending = b
			case "list.showIconPreview": p.settings.list.showIconPreview = b
			case "list.useRelativeDates": p.settings.list.useRelativeDates = b
			case "list.calculateAllSizes": p.settings.list.calculateAllSizes = b
			default: print("알 수 없는 키: \(k)")
			}
		}
		if p.settings.list.hasDanglingSortDirection {
			// The direction is stored inside the sort column's entry: alone it could never be written, but a global apply
			// would restart Finder and then fail verification every time.
			print("오류: list.sortAscending 은 list.sortColumn 과 함께 지정해야 합니다 (예: list.sortColumn=name list.sortAscending=false). 저장하지 않았습니다.")
			exit(1)
		}
		try presetStore.save(p)
		print("수정: \(p.name) — \(fmt(p.settings))")

	case "presets":
		for p in try presetStore.list() { print("\(p.name): \(fmt(p.settings))") }

	case "preset-export":
		guard args.count >= 3 else { usage() }
		try presetStore.export(try loadPreset(args[1]), to: folderURL(args[2]))
		print("내보냄: \(args[2])")

	case "preset-import":
		guard args.count >= 2 else { usage() }
		let p = try presetStore.importPreset(from: folderURL(args[1]))
		print("가져옴: \(p.name) — \(fmt(p.settings))")

	case "rule-set":
		guard args.count >= 3 else { usage() }
		var doc = try ruleStore.load()
		let preset = try loadPreset(args[2])
		let path = FolderRule.normalize(folderURL(args[1]).path)
		doc.rules.removeAll { $0.path == path }
		doc.rules.append(FolderRule(path: path, presetID: preset.id, appliesToSubfolders: !args.contains("--no-subfolders")))
		try ruleStore.save(doc)
		print("규칙: \(path) → \(preset.name)")

	case "rule-clear":
		guard args.count >= 2 else { usage() }
		var doc = try ruleStore.load()
		let path = FolderRule.normalize(folderURL(args[1]).path)
		doc.rules.removeAll { $0.path == path }
		try ruleStore.save(doc)

	case "rules":
		let doc = try ruleStore.load()
		let presets = Dictionary(uniqueKeysWithValues: try presetStore.list().map { ($0.id, $0.name) })
		for r in doc.rules { print("\(r.path) → \(presets[r.presetID] ?? "?")\(r.appliesToSubfolders ? " (하위 포함)" : "")") }

	case "analyze":
		guard args.count >= 3 else { usage() }
		let (_, plan) = try makePlan(presetName: args[1], args: Array(args.dropFirst(2)))
		printPlan(plan)

	case "apply":
		guard args.count >= 3 else { usage() }
		let (preset, plan) = try makePlan(presetName: args[1], args: Array(args.dropFirst(2)))
		printPlan(plan)
		let applier = Applier(operations: opStore, globals: globals)
		let request = ApplyRequest(plan: plan, presetName: preset.name, presetSnapshot: preset.settings)
		let op: FinderPresetsOperation
		if args.contains("--relaunch") {
			// A Finder that quits writes the parent stores it holds in memory back over what was written while it
			// ran, so with --relaunch the stores are written while it is down (quit → write → launch). Nothing is written
			// when Finder does not quit. Finder's windows are read before the quit and opened again once it is back
			// (`FinderWindows`). The read-back below waits until Finder has settled: `runWithFinderQuit`
			// gives it that moment (`launch` returns as soon as its process exists) and launches it once more if it went
			// away meanwhile.
			print("Finder 창 읽기 → Finder 종료 → 쓰기 → Finder 실행 → 창 다시 열기 → 기다림 → 되읽기…")
			let run = try GlobalApplier(operations: opStore, finder: RealFinderLifecycle())
				.runWithFinderQuit { try applier.apply(request) { print("  쓰는 중: \($0)") } }
			op = run.result
			printOp(op)
			print(run.finderRelaunched ? "Finder 재실행 완료" + reopenedNote(run.reopenedWindows) : "Finder 재실행 실패: 직접 Finder를 실행하세요")
		} else {
			op = try applier.apply(request) { print("  쓰는 중: \($0)") }
			printOp(op)
			if op.summary.changed > 0 {
				// `relaunch-finder` quits Finder after the write: a Finder that quits may write its own view of a folder
				// whose window is open over it, and nothing writes it again.
				print("참고: Finder가 이미 열어본 상위 폴더는 Finder를 재실행해야 반영됩니다. 적용과 함께 하려면 --relaunch 를 쓰세요(Finder 종료 → 쓰기 → 실행). "
					+ "따로 하는 relaunch-finder 는 창이 열린 폴더를 종료하는 Finder가 덮어쓸 수 있고, 그것을 다시 쓰지 않습니다.")
			}
		}
		// Verify after the relaunch (a Finder that quits writes cached parent stores back from memory).
		let lost = applier.verify(op)
		if !lost.isEmpty {
			print("경고: \(args.contains("--relaunch") ? "재실행 후" : "기록 직후") 검증에서 \(lost.count)개 폴더의 값이 다릅니다 (Finder가 덮어씀):")
			for e in lost { print("  \(e.folderPath)") }
		}

	case "undo":
		let flags: Set<String> = ["--force", "--yes"]
		let which = args.dropFirst().first { !flags.contains($0) } ?? "last"
		let force = args.contains("--force")
		// The same verdict the app uses (OperationHistory): undone, undoable, or nothing to undo.
		let history = try OperationHistory(store: opStore)
		// "last" is the newest folder apply that changed a folder and is not undone (an undo of it that was undone again
		// does not count).
		let op = try operationToUndo(which, global: false, noneLeft: "되돌릴 작업 없음 (데이터 폴더: \(dirs.root.path))", in: history)
		guard !op.kind.isGlobal else {
			print("전역 작업입니다. 'finder-presets global-undo \(op.id.uuidString) --i-understand-finder-restarts' 로 되돌리세요."); exit(1)
		}
		switch history.status(of: op) {
		case .undoable:
			if op.kind == .undo { print("참고: 되돌리기 작업을 되돌리면 그 작업이 되돌린 적용이 다시 반영됩니다.") }
		case .nothingToUndo:
			print("되돌릴 폴더가 없습니다: 작업 \(op.id.uuidString) [\(op.kind.rawValue)]은 바꾼 폴더가 없습니다 (데이터 폴더: \(dirs.root.path))."); exit(1)
		case .undone(let by):
			guard force else {
				// An undo that only found everything already as before wrote nothing: there is nothing to redo with it.
				let redo = history.operation(by).map(OperationHistory.foundAlreadyRestored) == true
					? "  - 이 되돌리기는 모든 폴더가 이미 적용 전 상태라 아무것도 쓰지 않은 기록입니다. 다시 적용하려면 프리셋을 다시 적용하세요."
					: "  - 되돌린 것을 다시 적용하려면: finder-presets undo \(by.uuidString)"
				print("""
				이미 되돌린 작업입니다: \(op.id.uuidString) [\(op.kind.rawValue)] (되돌리기 작업 \(by.uuidString)).
				\(redo)
				  - 그래도 이 작업의 모든 폴더를 적용 전 값으로 다시 쓰려면 --force 를 붙이세요 (그 뒤에 바뀐 폴더도 덮어씁니다).
				""")
				exit(1)
			}
			print("주의: 이미 되돌린 작업입니다 (되돌리기 작업 \(by.uuidString)). --force: 이 작업의 모든 폴더를 적용 전 값으로 다시 씁니다.")
		}
		if op.finishedAt == nil { print(unfinishedNote(op)) }
		// Show where this comes from and what it touches before anything is written: an app started with FINDER_PRESETS_DATA_DIR
		// records its operations there, and the default folder may hold real ones.
		print("데이터 폴더: \(dirs.root.path)")
		print("작업 \(op.id.uuidString) [\(op.kind.rawValue)] \(dateFmt.string(from: op.startedAt)) preset=\(op.presetName ?? "-")")
		print("대상 루트: \(op.roots.isEmpty ? "(없음)" : op.roots.joined(separator: ", "))")
		let undo = UndoService(operations: opStore)
		let preview = undo.preview(op)
		let restored = preview.alreadyRestored.count
		let unreadable = preview.unreadable.count
		print("되돌리기 대상 \(preview.items.count)개 폴더, 충돌 \(preview.conflicts.count)개" + (restored > 0 ? ", 이미 적용 전 상태 \(restored)개 (그대로 둠)" : "")
			+ (unreadable > 0 ? ", 읽지 못함 \(unreadable)개 (되돌리지 못함)" : "") + (force ? " (--force: 충돌도 복원)" : ""))
		for c in preview.conflicts { print("  충돌: \(c.folderPath)") }
		for u in preview.unreadable { print("  읽지 못함: \(u.folderPath) — \(u.unreadable ?? "")") }
		if !preview.items.isEmpty && restored == preview.items.count {
			print("모든 폴더가 이미 적용 전 상태입니다. 되돌리면 아무것도 쓰지 않고 이 작업을 되돌린 것으로 기록합니다 (undo last 가 다음 작업으로 넘어갑니다).")
		}
		guard confirm("이 작업을 되돌릴까요?", yes: args.contains("--yes")) else { print("취소했습니다 (아무것도 바꾸지 않음)."); exit(2) }
		let result = try undo.undo(op, force: args.contains("--force"))
		printOp(result)
		if OperationHistory.foundAlreadyRestored(result) { print("모든 폴더가 이미 적용 전 상태라 아무것도 쓰지 않았습니다. 이 작업은 되돌린 것으로 기록했습니다.") }

	case "ops":
		if args.contains("--prune") {
			// Preview only: the same plan `prune` would carry out, nothing is deleted.
			let plan = try opStore.retentionPlan(policy: retentionPolicy(args.dropFirst(), allowed: ["--prune"]))
			printRetention(plan)
			print(plan.removed.isEmpty ? "미리보기입니다. 아무것도 지우지 않았습니다." : "미리보기입니다. 아무것도 지우지 않았습니다. 지우려면: finder-presets prune (정책 인자는 같게)")
			break
		}
		guard args.count == 1 else { print("알 수 없는 인자: \(args.dropFirst().joined(separator: " "))"); usage() }
		let listing = try opStore.listReadable()
		let history = OperationHistory(listing.operations)
		let nextFolder = history.latestUndoable(global: false)?.id
		let nextGlobal = history.latestUndoable(global: true)?.id
		print("데이터 폴더: \(dirs.root.path)")
		if history.operations.isEmpty { print("기록된 작업 없음") }
		for o in history.overviews {
			var line = "\(overviewLine(o))  변경 \(o.folderCount) 건너뜀 \(o.skippedCount) 실패 \(o.failedCount)"
				+ (o.positionsOnlyCount > 0 ? " 아이콘 자리만 \(o.positionsOnlyCount)" : "") + "  \(undoStatusText(o))"
			if !o.isFinished { line += o.inProgress ? "  (진행 중)" : "  (미완료)" }
			if o.pinned { line += "  [고정]" }
			if o.id == nextFolder { line += "  ← undo last" }
			if o.id == nextGlobal { line += "  ← global-undo last" }
			print(line)
			print("    대상: \(targetText(o))")
		}
		if !listing.unreadable.isEmpty {
			print("읽지 못한 작업 기록 \(listing.unreadable.count)개 (그대로 둠):")
			for u in listing.unreadable { print("  \(u)") }
		}

	case "prune":
		let plan = try opStore.retentionPlan(policy: retentionPolicy(args.dropFirst(), allowed: ["--yes"]))
		printRetention(plan)
		guard !plan.removed.isEmpty else { print("지울 것이 없습니다. 아무것도 바꾸지 않았습니다."); break }
		guard confirm("위 작업 \(plan.removed.count)개와 그 백업을 지울까요? 지운 작업은 되돌릴 수 없습니다.", yes: args.contains("--yes")) else {
			print("취소했습니다 (아무것도 지우지 않음)."); exit(2)
		}
		// Exactly the plan shown above: an operation that changed meanwhile (pinned, finished) is left for the next run.
		let result = opStore.applyRetention(plan)
		print("지움: \(result.removed.count)개 (\(bytes(plan.removed.filter { result.removed.contains($0.id) }.reduce(0) { $0 + $1.bytes })))")
		if !result.skipped.isEmpty {
			print("그 사이에 바뀌어 남겨 둔 작업 \(result.skipped.count)개: \(result.skipped.map(\.uuidString).joined(separator: ", "))")
		}
		if !result.failed.isEmpty {
			for f in result.failed { print("  지우지 못함: \(f.id.uuidString) — \(f.message)") }
			exit(1)
		}

	case "pin", "unpin":
		guard args.count == 2, let id = UUID(uuidString: args[1]) else { usage() }
		let pin = cmd == "pin"
		let wasPinned = (try? opStore.load(id: id))?.pinned
		let op = try opStore.setPinned(id: id, pinned: pin)
		let what = "작업 \(op.id.uuidString) [\(op.kind.rawValue)] \(dateFmt.string(from: op.startedAt)) preset=\(op.presetName ?? "-")"
		if wasPinned == pin {
			print(pin ? "이미 고정되어 있습니다: \(what)" : "고정되어 있지 않습니다: \(what)")
		} else {
			print(pin ? "고정했습니다: \(what). 정리(prune)해도 지우지 않습니다." : "고정을 풀었습니다: \(what). 보관 정책에 따라 정리될 수 있습니다.")
		}

	case "relaunch-finder":
		// The app's restart without a write: Finder's windows read, Finder quit and launched, the windows opened again,
		// Finder given its moment to settle and launched once more if it went away (`GlobalApplier.runWithFinderQuit`
		// writes no record). Throws `finderDidNotQuit` when Finder stays.
		let run = try GlobalApplier(operations: opStore, finder: RealFinderLifecycle()).runWithFinderQuit {}
		print(run.finderRelaunched ? "Finder 재실행 완료" + reopenedNote(run.reopenedWindows) : "Finder 재실행 실패: 직접 Finder를 실행하세요")

	case "global-show":
		let snap = GlobalDefaultsWriter.snapshot(domain: GlobalDefaultsWriter.finderDomain)
		print("데이터 폴더: \(dirs.root.path)")
		print("도메인: \(GlobalDefaultsWriter.finderDomain) (읽기 전용)")
		print("FXPreferredViewStyle: \(snap.preferredViewStyle ?? "(없음)")")
		if let svs = snap.standardViewSettingsDictionary {
			print("StandardViewSettings 섹션: \(svs.keys.sorted().joined(separator: ", "))")
		} else {
			print("StandardViewSettings: (없음)")
		}
		print("전역 값 : \(fmt(snap.decodedSettings))")
		let globalOps = try opStore.list().filter { $0.kind.isGlobal }
		if let last = globalOps.first {
			print("마지막 전역 작업: \(last.id.uuidString) [\(last.kind.rawValue)] \(last.startedAt) preset=\(last.presetName ?? "-")\(last.finishedAt == nil ? " (미완료)" : "")")
		} else {
			print("전역 작업 기록 없음")
		}

	case "global-apply":
		guard args.count >= 2 else { usage() }
		let preset = try loadPreset(args[1])
		let current = GlobalDefaultsWriter.snapshot(domain: GlobalDefaultsWriter.finderDomain)
		print("현재 전역: \(fmt(current.decodedSettings))")
		print("프리셋   : \(preset.name) — \(fmt(preset.settings))")
		// The grouping is never written to Finder's defaults (ViewSettings.globalDefaultsPart): only folders hold it.
		if preset.settings.groupBy != nil { print("참고: 그룹 기준은 Finder 기본값에 쓰지 않습니다 (폴더에만 씁니다: finder-presets apply).") }
		let diffs = current.decodedSettings.differences(to: preset.settings.globalDefaultsPart)
		if diffs.isEmpty { print("변경할 값이 없습니다 (이미 동일). Finder를 건드리지 않습니다."); exit(0) }
		print("변경: " + diffs.map { "\($0.field): \($0.current ?? "미설정") → \($0.target)" }.joined(separator: ", "))
		guard args.contains("--i-understand-finder-restarts") else {
			print("""

			거부: 전역 적용은 Finder를 종료했다가 다시 실행합니다.
			  - 열려 있는 Finder 창은 닫혔다가 다시 열리고(폴더를 보여 주지 않는 검색·최근 항목 창 등은 제외), 진행 중인 복사/이동이 중단될 수 있습니다.
			  - Finder가 종료된 상태에서만 값이 유지되므로 다른 순서로는 적용되지 않습니다.
			  - 적용 전 값은 operations/<id>/global-before.json 에 저장되며 'finder-presets global-undo last --i-understand-finder-restarts'로 되돌립니다.
			동의하면 같은 명령에 --i-understand-finder-restarts 를 붙여 다시 실행하세요.
			""")
			exit(2)
		}
		let applier = GlobalApplier(operations: opStore, finder: RealFinderLifecycle())
		print("Finder 창 읽기 → Finder 종료 → 값 쓰기 → Finder 실행 → 창 다시 열기 → 기다림 → 되읽기…")
		let op = try applier.apply(preset.settings, presetName: preset.name)
		print("완료: 작업 \(op.id.uuidString) [\(op.kind.rawValue)]" + (op.finderRelaunched ? "" : " — Finder 재실행 실패: 직접 Finder를 실행하세요"))
		print("적용 후: \(fmt(op.globalAfter?.decodedSettings ?? ViewSettings()))")
		print("되돌리기: finder-presets global-undo \(op.id.uuidString) --i-understand-finder-restarts")

	case "global-undo":
		let restartFlag = "--i-understand-finder-restarts"
		let which = args.dropFirst().first { $0 != restartFlag } ?? "last"
		// The same verdict the app uses (OperationHistory), checked before Finder's defaults are even read.
		let history = try OperationHistory(store: opStore)
		let op = try operationToUndo(which, global: true, noneLeft: "되돌릴 전역 작업 없음 (데이터 폴더: \(dirs.root.path))", in: history)
		guard op.kind.isGlobal else { print("전역 작업이 아닙니다: \(op.id.uuidString) [\(op.kind.rawValue)]. 폴더 적용은 'finder-presets undo \(op.id.uuidString)' 로 되돌리세요."); exit(1) }
		switch history.status(of: op) {
		case .undoable:
			if op.kind == .undoGlobal { print("참고: 전역 되돌리기 작업을 되돌리면 그 작업이 되돌린 전역 적용이 다시 반영됩니다.") }
		case .nothingToUndo:
			print("되돌릴 수 없습니다: 작업 \(op.id.uuidString) [\(op.kind.rawValue)]에 적용 전 값(스냅샷)이 기록되지 않았습니다."); exit(1)
		case .undone(let by):
			if history.operation(by).map(OperationHistory.foundAlreadyRestored) == true {
				print("이미 되돌린 것으로 기록된 전역 작업입니다: \(op.id.uuidString) [\(op.kind.rawValue)] (되돌리기 작업 \(by.uuidString): Finder 기본 보기가 이미 적용 전 값이라 Finder를 건드리지 않음). 다시 적용하려면 프리셋을 다시 전역 적용하세요.")
			} else {
				print("이미 되돌린 전역 작업입니다: \(op.id.uuidString) [\(op.kind.rawValue)] (되돌리기 작업 \(by.uuidString)). 되돌린 것을 다시 적용하려면: finder-presets global-undo \(by.uuidString) \(restartFlag)")
			}
			exit(1)
		}
		guard let file = op.globalSnapshotFile else { print("되돌릴 수 없습니다: 작업 \(op.id.uuidString)에 스냅샷이 없습니다."); exit(1) }
		if op.finishedAt == nil { print(unfinishedNote(op)) }
		let target = try opStore.loadGlobalSnapshot(file, for: op)
		let current = GlobalDefaultsWriter.snapshot(domain: GlobalDefaultsWriter.finderDomain)
		print("데이터 폴더: \(dirs.root.path)")
		print("되돌릴 작업: \(op.id.uuidString) [\(op.kind.rawValue)] \(dateFmt.string(from: op.startedAt)) preset=\(op.presetName ?? "-")")
		print("현재 전역: \(fmt(current.decodedSettings))")
		print("복원 값  : \(fmt(target.decodedSettings)) (\(dateFmt.string(from: target.takenAt)) 기록)")
		if current.hasSameValues(as: target) {
			// Nothing to write and Finder is left alone; with the flag the operation is recorded as undone (so `last` moves on).
			guard args.contains(restartFlag) else {
				print("이미 그 값입니다. Finder를 건드리지 않습니다. \(restartFlag) 를 붙이면 Finder를 건드리지 않고 이 작업을 되돌린 것으로 기록합니다 (global-undo last 가 다음 작업으로 넘어갑니다).")
				exit(0)
			}
			let applier = GlobalApplier(operations: opStore, finder: RealFinderLifecycle())
			let undoOp = try applier.undo(op)
			print(OperationHistory.foundAlreadyRestored(undoOp)
				? "이미 그 값이라 Finder를 건드리지 않고 되돌린 것으로 기록했습니다: 작업 \(undoOp.id.uuidString) [\(undoOp.kind.rawValue)]"
				: "완료: 작업 \(undoOp.id.uuidString) [\(undoOp.kind.rawValue)]" + (undoOp.finderRelaunched ? "" : " — Finder 재실행 실패: 직접 Finder를 실행하세요"))
			exit(0)
		}
		// The same restart as global-apply (windows close and open again, copies in progress may stop), so the same explicit consent.
		guard args.contains(restartFlag) else {
			print("""

			거부: 전역 되돌리기도 Finder를 종료했다가 다시 실행합니다.
			  - 열려 있는 Finder 창은 닫혔다가 다시 열리고(폴더를 보여 주지 않는 검색·최근 항목 창 등은 제외), 진행 중인 복사/이동이 중단될 수 있습니다.
			  - 위 작업의 기록 값(operations/\(op.id.uuidString)/\(file))으로 FXPreferredViewStyle·StandardViewSettings 를 되돌립니다.
			동의하면 같은 명령에 \(restartFlag) 를 붙여 다시 실행하세요.
			""")
			exit(2)
		}
		print("Finder 창 읽기 → Finder 종료 → 값 복원 → Finder 실행 → 창 다시 열기 → 기다림 → 되읽기…")
		let applier = GlobalApplier(operations: opStore, finder: RealFinderLifecycle())
		let undoOp = try applier.undo(op)
		if OperationHistory.foundAlreadyRestored(undoOp) {
			// Became equal meanwhile: GlobalApplier recorded it without touching Finder.
			print("그 사이에 이미 그 값이 되어 Finder를 건드리지 않고 되돌린 것으로 기록했습니다: 작업 \(undoOp.id.uuidString) [\(undoOp.kind.rawValue)]")
			exit(0)
		}
		print("완료: 작업 \(undoOp.id.uuidString) [\(undoOp.kind.rawValue)]" + (undoOp.finderRelaunched ? "" : " — Finder 재실행 실패: 직접 Finder를 실행하세요"))
		print("복원 후: \(fmt(undoOp.globalAfter?.decodedSettings ?? ViewSettings()))")

	default: usage()
	}
} catch {
	print("오류: \(error.localizedDescription)")
	exit(1)
}

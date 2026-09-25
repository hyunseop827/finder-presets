import Foundation
import FinderPresetsCore

/// The app speaks Korean (its development language, `CFBundleDevelopmentRegion` ko) and English. Every text is keyed by
/// its Korean wording in `Resources/ko.lproj` and `Resources/en.lproj` (`Localizable.strings`, plus
/// `Localizable.stringsdict` for English plurals; scripts/build-app.sh copies both folders into the bundle): SwiftUI
/// literals (`Text("…")`, `Button("…")`, `.help("…")`, `.accessibilityLabel("…")`) and `String(localized:)` look them up
/// in the app bundle, whose language macOS picks at launch from the user's preferred languages: the one chosen in the
/// app's Settings window (the per-app `AppleLanguages`, Views/LanguageSettings.swift), else the system's
/// (`-AppleLanguages '(en)'` on the command line for one run). A text passed on as a `String` is localized where it is
/// made (`String(localized:)`), never where it is shown.
/// Outside the app bundle (the unit tests) there are no tables and every text stays Korean.
///
/// The `finder-presets` command-line tool and the core's own messages stay Korean; the core's errors the app can meet are worded
/// here (`ErrorText`).
enum AppLanguage {
	/// The localization the bundle chose for this launch: "ko" or "en" (Korean when none of the user's languages is one of
	/// the two). Outside the app bundle (unit tests) whatever the test runner's bundle says.
	static let code: String = Bundle.main.preferredLocalizations.first ?? "ko"

	/// Dates follow the app's language (not the system region, which may differ): the first preferred language of that
	/// localization ("en-GB" keeps its date order), else the localization itself. Fixed at launch like `code`: a language
	/// chosen in the Settings window changes `Locale.preferredLanguages` at once but the texts only after a relaunch.
	static let locale: Locale =
		Locale(identifier: Locale.preferredLanguages.first { LanguageChoice.matches($0, code) } ?? code)

	/// Stands in for an argument a view lays out on its own: `around(String(localized: "\(slot)의 지정을 따릅니다"))` gives
	/// the words before and after it in the app's language ("" and "의 지정을 따릅니다", "Follows " and ""), so the name
	/// between them can be truncated in the middle while the words stay whole.
	static let slot = "\u{E000}"
	static func around(_ text: String) -> (before: String, after: String) {
		guard let range = text.range(of: slot) else { return (text, "") }
		return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
	}
}

/// The core's errors (their own texts are Korean, shared with `finder-presets`) in the app's language. Anything else keeps its own
/// description, which Foundation already gives in the app's language.
enum ErrorText {
	static func describe(_ error: any Error) -> String {
		switch error {
		case let e as LocatorError:
			switch e {
			case .rootFolder: return String(localized: "루트 디렉터리에는 적용할 수 없습니다.")
			case .volumeRoot: return String(localized: "볼륨 루트는 v1에서 지원하지 않습니다.")
			case .parentNotWritable(let path): return String(localized: "상위 폴더에 쓸 수 없습니다: \(path)")
			}
		case let e as StoreEditorError:
			switch e {
			case .unreadable(let detail): return String(localized: "설정 파일을 읽을 수 없습니다: \(detail)")
			case .verificationFailed(let detail): return String(localized: "쓴 파일 재검증 실패: \(detail)")
			case .writeFailed(let detail): return String(localized: "설정 파일 쓰기 실패: \(detail)")
			case .backupMismatch(let path): return String(localized: "백업한 설정 파일이 원본과 달라 쓰지 않았습니다: \(path)")
			}
		case let e as PresetStoreError:
			switch e {
			case .unreadable(let detail): return String(localized: "프리셋 파일을 읽을 수 없습니다: \(detail)")
			}
		case let e as OperationStoreError:
			switch e {
			case .notFound(let id): return String(localized: "작업 기록이 없습니다: \(id.uuidString)")
			case .inProgress(let id): return String(localized: "아직 진행 중인 작업이라 바꾸지 않았습니다: \(id.uuidString)")
			case .unreadable(let id, let detail): return String(localized: "작업 기록을 읽을 수 없습니다 (\(id.uuidString)): \(detail)")
			}
		case let e as GlobalApplyError:
			switch e {
			case .nothingToApply: return String(localized: "프리셋에 Finder 기본값으로 쓸 값이 없습니다 (그룹 기준은 폴더에만 씁니다)")
			case .snapshotIncomplete: return String(localized: "현재 전역 설정을 기록하지 못해 중단했습니다 (아무것도 바꾸지 않음)")
			case .finderDidNotQuit:
				return String(localized: "Finder를 종료하지 못해 중단했습니다 (아무것도 바꾸지 않음). 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Finder 제어를 허용했는지 확인하세요")
			case .notUndoable(let detail): return String(localized: "되돌릴 수 없는 작업입니다: \(detail)")
			case .notAlreadyRestored: return UndoRefusal.globalChanged.message
			case .verificationFailed(_, let diffs):
				return String(localized: "적용한 뒤 다시 읽은 값이 다릅니다: \(differences(diffs)). 툴바의 \"기록\"에서 되돌릴 수 있습니다.")
			}
		case let e as GlobalDefaultsError:
			switch e {
			case .synchronizeFailed(let domain): return String(localized: "기본값을 디스크에 기록하지 못했습니다 (\(domain))")
			case .corruptSnapshot: return String(localized: "저장된 전역 설정 스냅샷을 읽을 수 없어 복원을 중단했습니다")
			}
		default:
			return error.localizedDescription
		}
	}

	/// The values read back that differ, in the app's language ("icon.iconSize: 미설정 ≠ 64"; the property names are the
	/// model's). Without a property this app understands, only that the values differ.
	static func differences(_ diffs: [FieldDiff]) -> String {
		guard !diffs.isEmpty else { return String(localized: "기록한 값과 다릅니다") }
		return diffs.map { "\($0.field): \($0.current ?? String(localized: "미설정")) ≠ \($0.target)" }.joined(separator: ", ")
	}
}

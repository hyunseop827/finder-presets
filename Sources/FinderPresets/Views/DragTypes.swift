import SwiftUI
import UniformTypeIdentifiers
import FinderPresetsCore

// In-app drags. Both types are dynamic (derived from an unregistered tag), so they need no Info.plist declaration —
// an undeclared `UTType(exportedAs:)` is not matched by drop destinations — and nothing outside the app accepts them
// (Finder never copies or moves a folder because a row of this app was dropped on it).

extension UTType {
	/// A preset row, dropped on a folder row to assign it.
	static let presetReference = UTType(tag: "finder-presets-preset-reference", tagClass: .filenameExtension, conformingTo: .data)
		?? UTType(exportedAs: "com.hyunseop.FinderPresets.preset-reference")
	/// A folder row, dropped on the preset list to make a preset from that folder.
	static let targetReference = UTType(tag: "finder-presets-target-reference", tagClass: .filenameExtension, conformingTo: .data)
		?? UTType(exportedAs: "com.hyunseop.FinderPresets.target-reference")
}

struct PresetReference: Codable, Transferable, Sendable {
	var id: UUID
	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .presetReference)
	}
}

struct TargetReference: Codable, Transferable, Sendable {
	var path: String
	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .targetReference)
	}
}

/// What the preset list accepts: a folder row of this app, or files from Finder (sorted out by the handler).
enum PresetAreaDrop: Transferable {
	case listedFolder(String)
	case file(URL)
	static var transferRepresentation: some TransferRepresentation {
		ProxyRepresentation(importing: { (ref: TargetReference) in PresetAreaDrop.listedFolder(ref.path) })
		ProxyRepresentation(importing: { (url: URL) in PresetAreaDrop.file(url) })
	}
}

/// Folders become presets, preset JSON files are imported, anything else is refused with an alert (a plain file used
/// to become a fake preset holding Finder's defaults). Only `file:` URLs count: a web link to "….json" would otherwise
/// be downloaded on the main thread and stored as a preset.
@MainActor
enum PresetAreaDropHandler {
	static func handle(_ items: [PresetAreaDrop], model: AppModel) -> Bool {
		var folders: [URL] = []
		var files: [URL] = []
		var rejected: [String] = []
		for item in items {
			switch item {
			case .listedFolder(let path):
				folders.append(URL(fileURLWithPath: path))
			case .file(let url):
				guard url.isFileURL else {
					rejected.append(url.absoluteString)
					continue
				}
				if FinderWindows.isFolder(url) {
					folders.append(url)
				} else if url.pathExtension.lowercased() == "json" {
					files.append(url)
				} else {
					rejected.append(url.lastPathComponent)
				}
			}
		}
		for folder in folders { model.importPreset(from: folder) }
		if !files.isEmpty { model.importPresetFiles(files) }
		if !rejected.isEmpty {
			model.report(String(localized: "폴더나 프리셋 JSON 파일만 놓을 수 있습니다: \(rejected.joined(separator: ", "))"))
		}
		return !(folders.isEmpty && files.isEmpty)
	}
}

/// What is being dragged over a folder row.
enum RowDropHover: Sendable { case preset, folder }

/// A folder row tells a preset (assign it to this folder, row highlight) from Finder folders (added to the list like a
/// drop on the list itself, highlighted on the whole list) while the drag is still over it.
struct TargetRowDropDelegate: DropDelegate {
	let path: String
	let model: AppModel
	@Binding var rowHover: RowDropHover?
	@Binding var listFolderHover: Bool

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.presetReference, .fileURL]) }

	func dropEntered(info: DropInfo) { update(info) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		update(info)
		return DropProposal(operation: rowHover == nil ? .forbidden : .copy)
	}

	func dropExited(info: DropInfo) {
		rowHover = nil
		listFolderHover = false
	}

	func performDrop(info: DropInfo) -> Bool {
		defer {
			rowHover = nil
			listFolderHover = false
		}
		if info.hasItemsConforming(to: [.presetReference]) {
			guard let provider = info.itemProviders(for: [.presetReference]).first else { return false }
			let path = self.path
			let model = self.model
			_ = provider.loadTransferable(type: PresetReference.self) { result in
				guard case .success(let ref) = result else { return }
				Task { @MainActor in model.assignPreset(ref.id, to: [path]) }
			}
			return true
		}
		let providers = info.itemProviders(for: [.fileURL])
		guard !providers.isEmpty else { return false }
		let model = self.model
		Task { @MainActor in
			var urls: [URL] = []
			for provider in providers {
				if let url = await Self.loadURL(provider) { urls.append(url) }
			}
			if !urls.isEmpty { model.addFolders(urls) }   // same as a drop on the list itself
		}
		return true
	}

	/// Anything else (a folder row of this app on its way to the preset list) highlights nothing here.
	private func update(_ info: DropInfo) {
		let preset = info.hasItemsConforming(to: [.presetReference])
		let folder = !preset && info.hasItemsConforming(to: [.fileURL])
		rowHover = preset ? .preset : (folder ? .folder : nil)
		listFolderHover = folder
	}

	private static func loadURL(_ provider: NSItemProvider) async -> URL? {
		await withCheckedContinuation { continuation in
			_ = provider.loadTransferable(type: URL.self) { continuation.resume(returning: try? $0.get()) }
		}
	}
}

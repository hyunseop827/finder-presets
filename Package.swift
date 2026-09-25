// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "FinderPresets",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "FinderPresetsCore", targets: ["FinderPresetsCore"]),
		.executable(name: "finder-presets", targets: ["finder-presets"]),
		.executable(name: "FinderPresets", targets: ["FinderPresets"])
	],
	dependencies: [
		.package(url: "https://github.com/sindresorhus/DSStore", from: "0.1.0")
	],
	targets: [
		.target(
			name: "FinderPresetsCore",
			dependencies: [.product(name: "DSStore", package: "DSStore")]
		),
		.executableTarget(
			name: "finder-presets",
			dependencies: ["FinderPresetsCore"]
		),
		.executableTarget(
			name: "FinderPresets",
			dependencies: ["FinderPresetsCore"]
		),
		.testTarget(
			name: "FinderPresetsCoreTests",
			dependencies: ["FinderPresetsCore"],
			resources: [.copy("Fixtures")]
		),
		// The app's models and helpers (no window is opened): status line, layout budget, preset editor and preview, history and
		// undo, Finder restarts, services and the quick preset, localization.
		.testTarget(
			name: "FinderPresetsTests",
			dependencies: ["FinderPresets"]
		)
	]
)

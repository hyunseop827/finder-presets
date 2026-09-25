import SwiftUI

/// The two columns: presets on the left, the folders to apply to on the right, a hairline in between. Both have fixed
/// sizes (UILayout); nothing they show changes them.
struct Workbench: View {
	@Environment(\.colorSchemeContrast) private var contrast

	var body: some View {
		HStack(spacing: 0) {
			PresetPane()
				.section(EdgeInsets(top: UILayout.inset, leading: UILayout.edge, bottom: UILayout.inset, trailing: UILayout.inset))
				.frame(width: UILayout.presetColumnWidth)
				.probeFrame("presetSection")
			Rectangle()
				.fill(Theme.hairline(contrast))
				.frame(width: 1)
				.padding(.vertical, UILayout.inset)
				.accessibilityHidden(true)
			TargetPane()
				.section(EdgeInsets(top: UILayout.inset, leading: UILayout.inset, bottom: UILayout.inset, trailing: UILayout.edge))
				.frame(width: UILayout.targetColumnWidth)
				.probeFrame("targetSection")
		}
		.frame(width: UILayout.content.width, height: UILayout.workbenchHeight)
	}
}

import SwiftUI

/// Numbered circle in front of an area title. Decorative: the title itself reads "1. 프리셋".
struct StepBadge: View {
	let number: Int

	var body: some View {
		Text(verbatim: String(number))
			.font(.system(size: 11, weight: .bold, design: .rounded))
			.foregroundStyle(.white)
			.frame(width: 18, height: 18)
			.background(Theme.badge, in: Circle())
			.accessibilityHidden(true)
	}
}

/// Rounded tile with a white symbol on the badge gradient (help strip, confirmation sheet).
struct GradientTile: View {
	let systemImage: String
	var size: CGFloat = 22

	var body: some View {
		Image(systemName: systemImage)
			.font(.system(size: size * 0.5, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: size, height: size)
			.background(Theme.badge, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
			.accessibilityHidden(true)
	}
}

/// Title row of an area: badge, title and count on the left (the longer explanation is their tooltip and the title's
/// VoiceOver hint), a trailing accessory that never wraps. Fixed height, whatever the texts are.
struct SectionHeader<Accessory: View>: View {
	let step: Int
	let title: String
	let count: String
	let help: String
	@ViewBuilder var accessory: Accessory

	var body: some View {
		HStack(spacing: 6) {
			HStack(spacing: 6) {
				StepBadge(number: step)
				Text(title)
					.font(.headline)
					.lineLimit(1)
					.accessibilityLabel(String(step) + ". " + title)
					.accessibilityAddTraits(.isHeader)
					.accessibilityHint(help)
				Text(count)
					.font(.subheadline.monospacedDigit())
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.help(help)
			Spacer(minLength: 8)
			accessory.fixedSize()
		}
		.frame(height: UILayout.headerHeight)
	}
}

/// Empty list placeholder: a small gradient symbol and two short lines, centered in the list. No frame and no button
/// (the area's own buttons do that; a second button with the same name would confuse VoiceOver and the UI automation).
struct EmptyListHint: View {
	let systemImage: String
	let title: String
	let message: String

	var body: some View {
		VStack(spacing: 4) {
			Image(systemName: systemImage)
				.font(.system(size: 20))
				.foregroundStyle(Theme.brand)
				.accessibilityHidden(true)
			Text(title).font(.callout.weight(.semibold))
			Text(message)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.lineLimit(2)
		}
		.frame(maxWidth: 220)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.allowsHitTesting(false)
		.accessibilityElement(children: .combine)
	}
}

extension View {
	/// Background of the app's own sheets: a surface a step lighter than the window in dark mode, so the sheet's edge
	/// does not run into the dimmed window behind it.
	func sheetSurface() -> some View {
		presentationBackground(Theme.sheet)
	}

	/// Soft warning panel behind a notice: the Finder-restart warnings and the lists of skipped or failed folders.
	func warningBox() -> some View {
		padding(8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
	}

	/// Drop feedback drawn over the view (the layout never changes): soft fill, dashed accent border, centered capsule.
	func dropHighlight(_ active: Bool, message: String, systemImage: String, radius: CGFloat = UILayout.wellRadius) -> some View {
		modifier(DropHighlight(active: active, message: message, systemImage: systemImage, radius: radius))
	}
}

struct DropHighlight: ViewModifier {
	let active: Bool
	let message: String
	let systemImage: String
	let radius: CGFloat
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorSchemeContrast) private var contrast

	func body(content: Content) -> some View {
		content
			.overlay {
				if active {
					ZStack {
						RoundedRectangle(cornerRadius: radius, style: .continuous)
							.fill(Theme.accentText.opacity(0.10))
						RoundedRectangle(cornerRadius: radius, style: .continuous)
							.strokeBorder(Theme.accentText, style: StrokeStyle(lineWidth: contrast == .increased ? 3 : 2, dash: [6, 4]))
						DropCapsule(message: message, systemImage: systemImage)
					}
					.padding(3)
					.allowsHitTesting(false)
					.accessibilityHidden(true)
					.transition(.opacity)
				}
			}
			.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
	}
}

/// Warning panel that says what a Finder restart does, one sentence per line (broken by hand: the sheets have a fixed
/// width and each line fits). `text` is the whole notice, already localized.
struct RestartNote: View {
	let text: String

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "arrow.clockwise").foregroundStyle(Theme.warning).accessibilityHidden(true)
			Text(text)
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
		}
		.warningBox()
	}
}

/// A preset's color dot; on the accent selection it gets a white ring so it stays visible.
struct PresetDot: View {
	let tint: Color
	var size: CGFloat = 7

	var body: some View {
		Circle()
			.fill(tint)
			.overlay(Circle().strokeBorder(OnSelection(Color.clear, selected: Color.white), lineWidth: 1.5))
			.frame(width: size, height: size)
			.accessibilityHidden(true)
	}
}

/// White label on the accent fill ("놓으면 프리셋을 만듭니다").
struct DropCapsule: View {
	let message: String
	let systemImage: String

	var body: some View {
		Label(message, systemImage: systemImage)
			.font(.callout.weight(.semibold))
			.foregroundStyle(.white)
			.lineLimit(1)
			.padding(.horizontal, 10)
			.padding(.vertical, 5)
			.background(Theme.accent, in: Capsule())
			.shadow(color: Theme.shadow, radius: 6, y: 2)
	}
}

/// What a dragged row looks like under the pointer.
struct DragPreview<Icon: View>: View {
	let title: String
	let hint: String
	@ViewBuilder var icon: Icon

	var body: some View {
		HStack(spacing: 8) {
			icon
			VStack(alignment: .leading, spacing: 1) {
				Text(title).font(.callout.weight(.semibold)).lineLimit(1)
				Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}
}

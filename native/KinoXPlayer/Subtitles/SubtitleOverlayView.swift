import SwiftUI

struct SubtitleOverlayView: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var preferences: AppPreferences

    private var displayFrame: SubtitleDisplayFrame {
        controller.subtitleDisplayFrame(at: controller.currentTime)
    }

    var body: some View {
        let frame = displayFrame
        let secondaryText = frame.secondaryText
        let primaryText = frame.primaryText
        let subtitleStack = FixedSubtitleLaneLayout(
            spacing: 24,
            minimumSecondaryLaneHeight: SubtitleLaneGeometry.minimumHeight(
                forFontSize: CGFloat(preferences.secondaryFontSize)
            ),
            minimumPrimaryLaneHeight: SubtitleLaneGeometry.minimumHeight(
                forFontSize: CGFloat(preferences.primaryFontSize)
            )
        ) {
            subtitleText(
                secondaryText.isEmpty ? " " : secondaryText,
                size: preferences.secondaryFontSize,
                color: Color(hex: preferences.secondaryColorHex) ?? .yellow
            )
            .opacity(secondaryText.isEmpty ? 0 : 1)
            .accessibilityHidden(secondaryText.isEmpty)
            .id("secondary-subtitle-row")

            subtitleText(
                primaryText.isEmpty ? " " : primaryText,
                size: preferences.primaryFontSize,
                color: Color(hex: preferences.primaryColorHex) ?? .white
            )
            .opacity(primaryText.isEmpty ? 0 : 1)
            .accessibilityHidden(primaryText.isEmpty)
            .id("primary-subtitle-row")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.bottom, preferences.subtitleBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Playback actions can show the HUD in the same update in which subtitle
        // rows change. Keep the rows out of that animation transaction so an
        // outgoing lower row and an incoming upper row can never coexist at the
        // same vertical position.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityElement(children: frame.isAlignedPair ? .ignore : .contain)
        .accessibilityLabel(frame.isAlignedPair ? frame.accessibilityText : "")
        .accessibilityHidden(frame.isEmpty)

        ZStack {
            subtitleStack

            Group {
                if let hudMessage = controller.hudMessage {
                    Text(hudMessage)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.72), in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: controller.hudMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func subtitleText(_ text: String, size: Double, color: Color) -> some View {
        Text(text)
            .font(.system(
                size: size,
                weight: preferences.boldSubtitles ? .bold : .semibold,
                design: .rounded
            ))
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .foregroundStyle(color)
            .shadow(color: .black, radius: 1.2, x: -1, y: -1)
            .shadow(color: .black, radius: 1.2, x: 1, y: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if preferences.showSubtitleBackground {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.black.opacity(preferences.subtitleBackgroundOpacity))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1_080)
            .layoutPriority(1)
            .accessibilityLabel(text)
    }
}

/// Keeps S2 in the upper lane and S1 in the lower lane even when either track
/// is temporarily empty. Each lane has enough stable capacity for a normal
/// two-line cue and expands only when a longer cue requires it.
struct FixedSubtitleLaneLayout: Layout {
    let spacing: CGFloat
    let minimumSecondaryLaneHeight: CGFloat
    let minimumPrimaryLaneHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = finiteDimension(proposal.width)
        let rowSizes = measuredSizes(
            for: subviews,
            availableWidth: proposedWidth
        )
        let contentWidth = proposedWidth
            ?? rowSizes.map(\.width).max()
            ?? 0

        return laneGeometry(
            rowSizes: rowSizes,
            containerWidth: contentWidth,
            spacing: spacing
        ).contentSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let availableWidth = finiteDimension(bounds.width) ?? 0
        let rowSizes = measuredSizes(
            for: subviews,
            availableWidth: availableWidth
        )
        let geometry = laneGeometry(
            rowSizes: rowSizes,
            containerWidth: availableWidth,
            spacing: spacing
        )

        let frames = [geometry.secondary, geometry.primary]
        for (index, subview) in subviews.enumerated() where index < frames.count {
            let frame = frames[index]
            subview.place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width,
                    height: frame.height
                )
            )
        }
    }

    private func measuredSizes(
        for subviews: Subviews,
        availableWidth: CGFloat?
    ) -> [CGSize] {
        let rowProposal = ProposedViewSize(width: availableWidth, height: nil)
        return subviews.map { subview in
            let size = subview.sizeThatFits(rowProposal)
            return CGSize(
                width: finiteDimension(size.width) ?? 0,
                height: finiteDimension(size.height) ?? 0
            )
        }
    }

    private func laneGeometry(
        rowSizes: [CGSize],
        containerWidth: CGFloat,
        spacing: CGFloat
    ) -> SubtitleLaneGeometryResult {
        SubtitleLaneGeometry.layout(
            secondarySize: rowSizes.indices.contains(0) ? rowSizes[0] : .zero,
            primarySize: rowSizes.indices.contains(1) ? rowSizes[1] : .zero,
            containerWidth: containerWidth,
            minimumSecondaryLaneHeight: minimumSecondaryLaneHeight,
            minimumPrimaryLaneHeight: minimumPrimaryLaneHeight,
            spacing: spacing
        )
    }

    private func finiteDimension(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

struct SubtitleLaneGeometryResult {
    let secondaryLane: CGRect
    let primaryLane: CGRect
    let secondary: CGRect
    let primary: CGRect
    let contentSize: CGSize
}

enum SubtitleLaneGeometry {
    /// Reserves a stable two-line lane at the configured font size. Longer
    /// cues can expand the lane without ever intersecting the other track.
    static func minimumHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        max(72, normalized(fontSize) * 2.8 + 12)
    }

    static func layout(
        secondarySize: CGSize,
        primarySize: CGSize,
        containerWidth: CGFloat,
        minimumSecondaryLaneHeight: CGFloat,
        minimumPrimaryLaneHeight: CGFloat,
        spacing: CGFloat
    ) -> SubtitleLaneGeometryResult {
        let width = normalized(containerWidth)
        let gap = normalized(spacing)
        let secondaryHeight = normalized(secondarySize.height)
        let primaryHeight = normalized(primarySize.height)
        let secondaryLaneHeight = max(
            normalized(minimumSecondaryLaneHeight),
            secondaryHeight
        )
        let primaryLaneHeight = max(
            normalized(minimumPrimaryLaneHeight),
            primaryHeight
        )

        let secondaryLane = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: secondaryLaneHeight
        )
        let primaryLane = CGRect(
            x: 0,
            y: secondaryLane.maxY + gap,
            width: width,
            height: primaryLaneHeight
        )
        let secondary = rowFrame(for: secondarySize, in: secondaryLane)
        let primary = rowFrame(for: primarySize, in: primaryLane)

        return SubtitleLaneGeometryResult(
            secondaryLane: secondaryLane,
            primaryLane: primaryLane,
            secondary: secondary,
            primary: primary,
            contentSize: CGSize(width: width, height: primaryLane.maxY)
        )
    }

    private static func rowFrame(for proposedSize: CGSize, in lane: CGRect) -> CGRect {
        let rowWidth = min(normalized(proposedSize.width), lane.width)
        let rowHeight = normalized(proposedSize.height)
        return CGRect(
            x: lane.minX + (lane.width - rowWidth) / 2,
            y: lane.maxY - rowHeight,
            width: rowWidth,
            height: rowHeight
        )
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}

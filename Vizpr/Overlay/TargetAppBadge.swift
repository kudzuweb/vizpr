import AppKit
import SwiftUI

/// Sizes for the target-app indicator, shared by the views, the panel margin
/// and the pane measurement so they cannot drift apart.
///
/// The resting and expanded pills hold the icon inside their leading edge. The
/// inviz pill is too small for that, so its icon sits outside the left edge.
enum TargetAppMetrics {
    /// Icon inside the resting pill and the expanded pane.
    static let paneIconSize: CGFloat = 28
    /// Space between the pill's left edge and the icon inside it.
    static let paneIconLeading: CGFloat = 12
    /// Space between the icon and the transcript column in the expanded pane.
    static let paneIconTextGap: CGFloat = 8
    /// The icon never sits closer than this to the expanded pane's top edge.
    static let paneIconMinTop: CGFloat = 8
    /// Icon beside the inviz pill.
    static let invizIconSize: CGFloat = 20
    /// Space between the inviz pill's left edge and the indicator beside it.
    static let invizGap: CGFloat = 6
    static let iconToNameGap: CGFloat = 4
    static let nameMaxWidth: CGFloat = 110
    static let nameFontSize: CGFloat = 11
    static let opacity = 0.85

    /// Where the transcript column starts when the icon is shown: past the
    /// icon, but never inside the look's own padding.
    static func textLeading(paddingHorizontal: CGFloat) -> CGFloat {
        max(paddingHorizontal, paneIconLeading + paneIconSize + paneIconTextGap)
    }

    /// Room the panel needs on each side of the pane. Only the inviz pill puts
    /// its indicator outside the pane.
    static func sideInset(for display: TargetAppDisplay, inviz: Bool) -> CGFloat {
        guard inviz else { return 0 }
        switch display {
        case .off: return 0
        case .icon: return invizIconSize + invizGap
        case .iconAndName: return invizIconSize + iconToNameGap + nameMaxWidth + invizGap
        }
    }

    /// Width the name needs, up to `nameMaxWidth`. A flexible frame would take
    /// the full proposed width, so the name is sized from its measured text.
    static func nameWidth(_ name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: nameFontSize)
        // One extra point keeps SwiftUI's own layout from truncating by a pixel.
        let measured = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 1
        return min(measured, nameMaxWidth)
    }
}

/// The frontmost app's icon, and its name when asked for. Quiet by design:
/// partly transparent, and the name in the look's mutable text style.
struct TargetAppBadge: View {
    let app: TargetApp.Info
    let display: TargetAppDisplay
    let iconSize: CGFloat
    let look: OverlayLook

    var body: some View {
        HStack(spacing: TargetAppMetrics.iconToNameGap) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
            if display == .iconAndName {
                Text(app.name)
                    .font(.system(size: TargetAppMetrics.nameFontSize))
                    .foregroundStyle(look.mutableStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: TargetAppMetrics.nameWidth(app.name), alignment: .leading)
            }
        }
        .opacity(TargetAppMetrics.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictating into \(app.name)")
    }
}

extension View {
    /// Places the target-app badge just outside the inviz pill's left edge,
    /// vertically centered. It overlays, so the pill's own size is unchanged.
    @ViewBuilder func targetAppBeside(
        _ app: TargetApp.Info?, display: TargetAppDisplay, look: OverlayLook
    ) -> some View {
        if display != .off, let app {
            overlay(alignment: .leading) {
                TargetAppBadge(app: app, display: display, iconSize: TargetAppMetrics.invizIconSize, look: look)
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + TargetAppMetrics.invizGap }
            }
        } else {
            self
        }
    }
}

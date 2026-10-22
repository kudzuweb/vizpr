import AppKit
import SwiftUI

/// Sizes for the target-app indicator, shared by the views, the panel margin
/// and the pane measurement so they cannot drift apart.
enum TargetAppMetrics {
    static let pillIconSize: CGFloat = 16
    static let headerIconSize: CGFloat = 14
    /// Space between the pill's left edge and the indicator beside it.
    static let pillGap: CGFloat = 6
    static let iconToNameGap: CGFloat = 4
    static let nameMaxWidth: CGFloat = 110
    static let nameFontSize: CGFloat = 11
    static let opacity = 0.85
    /// Header row in the expanded pane: top inset plus the icon.
    static let headerTopInset: CGFloat = 10
    static let headerHeight = headerTopInset + headerIconSize

    /// Room the panel needs on each side of the pane for the indicator that
    /// sits outside the resting and inviz pills.
    static func sideInset(for display: TargetAppDisplay) -> CGFloat {
        switch display {
        case .off: 0
        case .icon: pillIconSize + pillGap
        case .iconAndName: pillIconSize + iconToNameGap + nameMaxWidth + pillGap
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

    /// Height the expanded pane adds for its header row.
    static func paneHeaderHeight(for display: TargetAppDisplay, hasApp: Bool) -> CGFloat {
        display == .off || !hasApp ? 0 : headerHeight
    }
}

/// The frontmost app's icon, and its name when asked for. Quiet by design:
/// small, partly transparent, and the name in the look's mutable text style.
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
    /// Places the target-app badge just outside this pill's left edge,
    /// vertically centered. It overlays, so the pill's own size is unchanged.
    @ViewBuilder func targetAppBeside(
        _ app: TargetApp.Info?, display: TargetAppDisplay, look: OverlayLook
    ) -> some View {
        if display != .off, let app {
            overlay(alignment: .leading) {
                TargetAppBadge(app: app, display: display, iconSize: TargetAppMetrics.pillIconSize, look: look)
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + TargetAppMetrics.pillGap }
            }
        } else {
            self
        }
    }
}

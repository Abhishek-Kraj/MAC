import SwiftUI
import AppKit

extension PanelResizeEdge {
    /// Real resize cursor per direction on macOS 15+. Below that AppKit has no
    /// public diagonal cursor, so the axis cursors stand in and the corners
    /// fall back to a crosshair.
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            switch self {
            case .top:            return .frameResize(position: .top,           directions: .all)
            case .bottom:         return .frameResize(position: .bottom,        directions: .all)
            case .leading:        return .frameResize(position: .left,          directions: .all)
            case .trailing:       return .frameResize(position: .right,         directions: .all)
            case .topLeading:     return .frameResize(position: .topLeft,       directions: .all)
            case .topTrailing:    return .frameResize(position: .topRight,      directions: .all)
            case .bottomLeading:  return .frameResize(position: .bottomLeft,    directions: .all)
            case .bottomTrailing: return .frameResize(position: .bottomRight,   directions: .all)
            }
        }
        switch self {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom:       return .resizeUpDown
        default:                  return .crosshair
        }
    }
}

/// The little diagonal-arrows chip at the panel's bottom-trailing corner.
///
/// This is only the affordance — the resizing itself is handled by an AppKit
/// local event monitor, before any view sees the press (see
/// `AppDelegate.installPanelResizeMonitor`). It is deliberately inert so it can
/// never intercept the drag it advertises.
struct ResizeGripHint: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(Design.Ink.tertiary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Design.Surface.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
            )
            .allowsHitTesting(false)
            .help("Drag any edge or corner to resize")
    }
}

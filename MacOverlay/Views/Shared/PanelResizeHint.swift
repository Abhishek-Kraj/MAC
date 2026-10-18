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

import Foundation

/// Which edge or corner of the panel a drag is resizing.
///
/// Deltas are reported in the orientation SwiftUI drags use — `dx` positive to
/// the right, `dy` positive DOWNWARD — and each edge decides which side of the
/// frame that moves, so the opposite edge stays pinned exactly the way a normal
/// window's does.
///
/// Deliberately free of SwiftUI and AppKit beyond geometry: the arithmetic here
/// is what decides whether the panel resizes the way a person expects, and it
/// is worth testing without standing up a window. The edge detection and the
/// cursor belong with the window — see `AppDelegate.installPanelResizeMonitor`
/// and `PanelResizeHint.swift`.
enum PanelResizeEdge: CaseIterable {
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// +1 when the grabbed side is on the right, -1 when it is on the left,
    /// 0 when this edge does not touch the width at all.
    var widthSign: CGFloat {
        switch self {
        case .top, .bottom:                             return 0
        case .trailing, .topTrailing, .bottomTrailing:  return 1
        case .leading, .topLeading, .bottomLeading:     return -1
        }
    }

    /// +1 when the grabbed side is at the bottom, -1 when it is at the top,
    /// 0 when this edge does not touch the height at all.
    var heightSign: CGFloat {
        switch self {
        case .leading, .trailing:                       return 0
        case .bottom, .bottomLeading, .bottomTrailing:  return 1
        case .top, .topLeading, .topTrailing:           return -1
        }
    }

    /// The frame produced by dragging this edge `dx` to the right and `dy`
    /// downward from `base`, never going below `minimum`, with the opposite
    /// edge(s) pinned the way a normal window resize behaves.
    func resizedFrame(from base: NSRect, dx: CGFloat, dy: CGFloat,
                      minimum: NSSize) -> NSRect {
        let newW = widthSign == 0
            ? base.width
            : max(minimum.width,  base.width  + widthSign  * dx)
        let newH = heightSign == 0
            ? base.height
            : max(minimum.height, base.height + heightSign * dy)
        // Grabbing the leading edge pins the trailing one, so the origin has to
        // follow the width. Grabbing a bottom edge pins the top, so the origin
        // has to follow the height. Every other case holds the origin.
        let originX = widthSign  < 0 ? base.maxX - newW : base.origin.x
        let originY = heightSign > 0 ? base.maxY - newH : base.origin.y
        return NSRect(x: originX, y: originY, width: newW, height: newH)
    }
}

// MARK: - Hit detection

extension PanelResizeEdge {

    /// How far from the window edge a press still counts as a resize.
    ///
    /// Measured from the WINDOW edge, and deliberately wider than the visible
    /// shell's inset. The shell is inset 6pt top and bottom and 14pt per side
    /// (6pt of root padding plus the card's own 8pt), so a band that stopped at
    /// the window edge would sit entirely in the invisible margin — and the
    /// thing a person actually grabs is the visible edge of the card, which
    /// they would miss. These values reach a couple of points past the shell,
    /// which is also what a normal window's frame does.
    static let bandHorizontal: CGFloat = 16
    static let bandVertical:   CGFloat = 10

    /// Corner bands, measured along each axis. Wider than the edge bands on
    /// purpose: a window's corners are the easiest thing to grab, and this
    /// panel's only resize target used to be a single 18pt corner grip.
    static let cornerHorizontal: CGFloat = 22
    static let cornerVertical:   CGFloat = 14

    /// Which edge or corner a press at `point` grabs inside a window of `size`,
    /// or nil when it lands in the interior.
    ///
    /// `point` is in window coordinates — y grows upward, as AppKit reports it
    /// — but nothing here depends on that: every test is a distance from a
    /// border, so the same answers hold for either orientation.
    ///
    /// Corners are checked first. A corner press is one that falls inside BOTH
    /// an edge band and the wider corner band for that axis, so a press beside
    /// a corner but only near one edge still resizes just that edge.
    static func at(point: NSPoint, in size: NSSize) -> PanelResizeEdge? {
        let left   = point.x <= bandHorizontal
        let right  = point.x >= size.width - bandHorizontal
        let bottom = point.y <= bandVertical
        let top    = point.y >= size.height - bandVertical

        let nearLeft   = point.x <= cornerHorizontal
        let nearRight  = point.x >= size.width - cornerHorizontal
        let nearBottom = point.y <= cornerVertical
        let nearTop    = point.y >= size.height - cornerVertical

        if top && nearLeft     { return .topLeading }
        if top && nearRight    { return .topTrailing }
        if bottom && nearLeft  { return .bottomLeading }
        if bottom && nearRight { return .bottomTrailing }
        if left   { return .leading }
        if right  { return .trailing }
        if top    { return .top }
        if bottom { return .bottom }
        return nil
    }
}

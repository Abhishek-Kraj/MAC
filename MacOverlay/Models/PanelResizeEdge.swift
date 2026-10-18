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
    /// Measured from the WINDOW edge and reaching well PAST the visible shell,
    /// because the shell is inset 6pt top and bottom and 14pt per side (6pt of
    /// root padding plus the card's own 8pt). Widths tighter than this do not
    /// work, and the failure is silent rather than obvious: a press a few
    /// points inside the card is not a resize at all, so it falls through to
    /// whatever is underneath and the border looks dead. Measured against a
    /// real press that missed — the user grabbed the trailing border 8pt
    /// inside the card's edge, which the 16pt version of this rejected.
    ///
    /// The ceiling is the chrome. In a 440x800 panel the close button starts
    /// 26pt in from the leading edge and 16pt down from the top, the bar's
    /// brand pill 18pt in, its trailing cluster ends 30pt in, and the compose
    /// button sits 54pt in from the trailing edge. 25 and 14 leave every one of
    /// them clickable while still reaching 11pt inside the card.
    static let bandHorizontal: CGFloat = 25
    static let bandVertical:   CGFloat = 14

    /// How far a corner reaches along the leading/trailing axis, so a corner
    /// press is a wider target than a plain edge — a window's corners are the
    /// easiest thing to grab, and this panel's only resize target used to be a
    /// single 18pt corner grip. Deliberately no equivalent on the vertical
    /// axis: the bands are already at the limit the top chrome allows, and the
    /// corners come out 34pt wide by 14pt tall, which is more than four times
    /// the old grip's area.
    static let cornerHorizontal: CGFloat = 34

    /// The border strips as rectangles for `addCursorRect`, in a view of `size`
    /// whose y-axis runs downward when `flipped`.
    ///
    /// The same border as `at(point:in:)`, built from the other direction: that
    /// one asks how far a point is from each edge, this one lays rects over the
    /// edges. They have to describe the same strip of window, because a cursor
    /// rect that is narrower than the grab region is a live border wearing an
    /// arrow — the exact thing this mechanism was added to fix — and one that is
    /// wider makes the panel look draggable where it only moves.
    ///
    /// `NSRect` containment is closed on a min edge and OPEN on a max edge,
    /// while the hit test is closed on both. Each strip therefore carries one
    /// extra point past its max edge. That point is deliberate: it makes the
    /// cursor region a superset of the grab region rather than an approximation
    /// that is short in places, and a cursor appearing one point early is not
    /// perceptible the way a missing one is. `testPanelResizeCursorBands…`
    /// pins both the agreement and the size of the overhang.
    ///
    /// Edges first and corners last, because a rect added later wins where two
    /// overlap — which is the same order of preference the hit test uses.
    static func bands(in size: NSSize, flipped: Bool) -> [(PanelResizeEdge, NSRect)] {
        let w = size.width, h = size.height
        let bh = bandHorizontal, bv = bandVertical, ch = cornerHorizontal

        /// One point, for the open max edge described above.
        let pad: CGFloat = 1

        // The window's top edge is the view's low edge exactly when flipped:
        // the hosting view is flipped, so its y counts down from the top.
        let topY: CGFloat = flipped ? 0 : h - bv
        let bottomY: CGFloat = flipped ? h - bv : 0

        // The long axis of each strip spans the whole view (plus the same pad,
        // so a strip still covers the extreme row the neighbouring strip's pad
        // reaches), because a point right at a corner belongs to the corner.
        return [
            (.leading,  NSRect(x: 0, y: 0, width: bh + pad, height: h + pad)),
            (.trailing, NSRect(x: w - bh, y: 0, width: bh + pad, height: h + pad)),
            (.top,      NSRect(x: 0, y: topY, width: w + pad, height: bv + pad)),
            (.bottom,   NSRect(x: 0, y: bottomY, width: w + pad, height: bv + pad)),

            (.topLeading,     NSRect(x: 0, y: topY, width: ch + pad, height: bv + pad)),
            (.topTrailing,    NSRect(x: w - ch, y: topY, width: ch + pad, height: bv + pad)),
            (.bottomLeading,  NSRect(x: 0, y: bottomY, width: ch + pad, height: bv + pad)),
            (.bottomTrailing, NSRect(x: w - ch, y: bottomY, width: ch + pad, height: bv + pad)),
        ]
    }

    /// Which edge or corner a press at `point` grabs inside a window of `size`,
    /// or nil when it lands in the interior.
    ///
    /// `point` is in window coordinates — y grows upward, as AppKit reports it,
    /// so `bottom` is the low-y end. That is orientation-dependent even though
    /// the answer only ever depends on a distance from a border: a flipped view
    /// measures y downward and has to be converted before calling this.
    /// `bands(in:flipped:)` is where that conversion lives.
    ///
    /// Corners are checked first, and they are the intersection of an edge band
    /// with the WIDER corner band on the other axis. A press beside a corner
    /// that is only near one edge therefore still resizes just that edge.
    static func at(point: NSPoint, in size: NSSize) -> PanelResizeEdge? {
        let left   = point.x <= bandHorizontal
        let right  = point.x >= size.width - bandHorizontal
        let bottom = point.y <= bandVertical
        let top    = point.y >= size.height - bandVertical

        let nearLeft  = point.x <= cornerHorizontal
        let nearRight = point.x >= size.width - cornerHorizontal

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

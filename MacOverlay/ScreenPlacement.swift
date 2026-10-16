import AppKit

/// Which screen a window should be constrained to when it is being moved.
///
/// This used to live on `AppDelegate` and fall back to `NSScreen.main` —
/// the screen holding key focus. With two displays that is the wrong target
/// for a drag in progress, so a drag toward the second monitor was clamped
/// straight back to the first and the panel looked stuck.
///
/// Split out here because it is pure geometry with no AppKit window state,
/// so it can be tested with synthetic screen rects and no display attached.
enum ScreenPlacement {

    /// Index of the screen `frame` belongs to, or nil when there are none.
    ///
    /// Prefers the screen the frame overlaps most, so a frame straddling two
    /// displays is judged by where most of it sits. A frame entirely off
    /// every screen — a hotkey nudge past an edge — falls back to the
    /// nearest by centre distance, so it lands somewhere sensible instead of
    /// being pinned to whichever display happens to have focus.
    static func bestScreenIndex(for frame: NSRect, screens: [NSRect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        let overlaps = screens.enumerated().map { index, rect -> (Int, CGFloat) in
            let hit = frame.intersection(rect)
            return (index, hit.isNull ? 0 : hit.width * hit.height)
        }
        if let best = overlaps.max(by: { lhs, rhs in lhs.1 < rhs.1 }), best.1 > 0 {
            return best.0
        }

        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return screens.indices.min {
            distance(from: centre, to: screens[$0]) < distance(from: centre, to: screens[$1])
        }
    }

    /// The `NSScreen` equivalent of `bestScreenIndex(for:screens:)`.
    /// `hint` is AppKit's own suggestion and is used only when no screen is
    /// attached at all.
    static func screen(for frame: NSRect, hint: NSScreen?) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return hint }
        guard let i = bestScreenIndex(for: frame, screens: screens.map(\.frame)) else { return hint }
        return screens[i]
    }

    /// Clamps a frame so it sits on `target` without losing its size: full
    /// frame horizontally so the bottom can reach the absolute edge, and
    /// visibleFrame at the top so the menu bar stays reachable.
    static func clamp(_ frame: NSRect, to target: NSScreen) -> NSRect {
        var f = frame
        let sf = target.frame
        let vf = target.visibleFrame
        f.origin.x = min(max(f.origin.x, sf.minX), sf.maxX - f.size.width)
        f.origin.y = min(max(f.origin.y, sf.minY), vf.maxY - f.size.height)
        return f
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
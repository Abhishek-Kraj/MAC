import SwiftUI
import AppKit

/// Drag-to-move for the overlay panel.
///
/// The panel sets `isMovableByWindowBackground`, but AppKit's background
/// drag only fires where nothing else claims the mouse-down — and the shell
/// is wall-to-wall filled capsules, cards, and controls, so in practice
/// almost none of the overlay could actually be grabbed.
///
/// Empty chrome uses AppKit event tracking so it receives the press before
/// SwiftUI's filled containers and measures movement from the press itself.
/// The brand button retains its separate simultaneous click/drag gesture.
struct PanelDragArea: NSViewRepresentable {
    @Environment(OverlayViewModel.self) private var vm
    /// A double-click on the area (the header uses it to rename).
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onDrag = { [vm] dx, dy, ended in vm.onPanelDrag?(dx, dy, ended) }
        view.onDoubleClick = onDoubleClick
        view.toolTip = onDoubleClick == nil ? nil : "Drag to move · double-click to rename"
    }

    final class DragView: NSView {
        var onDrag: ((CGFloat, CGFloat, Bool) -> Void)?
        var onDoubleClick: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            let anchor = window.convertPoint(toScreen: event.locationInWindow)
            var dragged = false
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = window.convertPoint(toScreen: next.locationInWindow)
                let dx = point.x - anchor.x, dy = point.y - anchor.y
                if !dragged && hypot(dx, dy) >= 3 { dragged = true }
                if dragged { onDrag?(dx, dy, next.type == .leftMouseUp) }
                if next.type == .leftMouseUp { break }
            }
        }
    }
}

/// Reports cumulative screen-space offsets to `vm.onPanelDrag`, which
/// AppDelegate applies to the panel's origin.
private struct PanelDragGesture: ViewModifier {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var didDrag: Bool

    /// Absolute screen point where this drag began.
    @State private var anchor: NSPoint?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            // A minimum distance means a plain click is still a click: the
            // gesture only engages once the pointer actually travels.
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    // Screen-space deltas, NOT SwiftUI's translation. The
                    // handle travels with the window it's moving, so a
                    // window-relative translation is measured against an
                    // origin that just shifted underneath it — each event
                    // then reports a delta polluted by the move it caused.
                    // Same feedback loop the corner resize grip avoids, and
                    // the same fix: `NSEvent.mouseLocation` is absolute and
                    // cannot feed back.
                    let loc = NSEvent.mouseLocation
                    if anchor == nil { anchor = loc }
                    guard let a = anchor else { return }
                    didDrag = true
                    vm.onPanelDrag?(loc.x - a.x, loc.y - a.y, false)
                }
                .onEnded { _ in
                    let loc = NSEvent.mouseLocation
                    let a = anchor ?? loc
                    vm.onPanelDrag?(loc.x - a.x, loc.y - a.y, true)
                    anchor = nil
                    // Clear on the next runloop turn, not now: the control's
                    // own click action fires in this same event and still
                    // needs to see that a drag happened. Clearing here — or
                    // leaving it to the control — would strand the flag true
                    // whenever a drag ends off the control, which happens
                    // every time the panel clamps at a screen edge and the
                    // cursor keeps going without it.
                    DispatchQueue.main.async { didDrag = false }
                }
        )
    }
}

extension View {
    /// Let this view drag the overlay panel while keeping its own gestures.
    ///
    /// `didDrag` flips true as soon as the press becomes a drag, and stays
    /// true until the control reads and clears it. A control that also has a
    /// click action must check it: the window follows the cursor, so the
    /// pointer is still inside the control on mouse-up and the click would
    /// otherwise fire at the end of every drag.
    func panelDraggable(didDrag: Binding<Bool>) -> some View {
        modifier(PanelDragGesture(didDrag: didDrag))
    }
}

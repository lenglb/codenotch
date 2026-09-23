import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at your
/// usage must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first — the hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: ((CGPoint) -> Void)?
    /// ⌥-drag on the chrome, reported as the raw pointer delta since the last
    /// event — not a cumulative offset, so the caller decides what "along the
    /// edge" means for the current one. Chosen over a plain click-and-hold
    /// threshold so an ordinary click never risks being read as a tiny nudge.
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    /// The ⌥-drag ended. Where to persist the offset the drags above moved to.
    var onDragEnd: (() -> Void)?

    private var dragScreenPoint: CGPoint?

    override func sendEvent(_ event: NSEvent) {
        // Capture the whole gesture before a SwiftUI child can consume its
        // mouseDown. Keep dispatch non-blocking so normal AppKit tracking and
        // redraws continue, including after Option is released mid-drag.
        if let previous = dragScreenPoint {
            if event.type == .leftMouseDragged {
                let point = convertPoint(toScreen: event.locationInWindow)
                dragScreenPoint = point
                onDrag?(point.x - previous.x, previous.y - point.y)
                return
            }
            if event.type == .leftMouseUp {
                finishOptionDrag()
                return
            }
        }
        if event.type == .leftMouseDown,
           event.modifierFlags.contains(.option), onDrag != nil,
           contentView?.hitTest(event.locationInWindow) != nil {
            dragScreenPoint = convertPoint(toScreen: event.locationInWindow)
            onDragStart?()
            return
        }
        guard event.type == .rightMouseDown,
              let menu = contextMenuProvider?(),
              let view = contentView,
              view.hitTest(event.locationInWindow) != nil
        else { return super.sendEvent(event) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func finishOptionDrag() {
        guard dragScreenPoint != nil else { return }
        dragScreenPoint = nil
        onDragEnd?()
    }

    override func orderOut(_ sender: Any?) {
        finishOptionDrag()
        super.orderOut(sender)
    }

    override func close() {
        finishOptionDrag()
        super.close()
    }

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        onClick?(event.locationInWindow)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

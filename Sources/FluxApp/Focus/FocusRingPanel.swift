// FluxApp.Focus — transient focus ring panel (design spec §5).
//
// One transparent, non-activating NSPanel that draws only a thin rounded
// ring in the system accent color. The panel cannot become key or main,
// ignores mouse events, is excluded from window cycling, joins all Spaces
// and full-screen auxiliary spaces, and is hidden from the Accessibility
// tree so it can never become a spatial navigation candidate or pollute
// context history.

import AppKit

/// The ring view: a stroked rounded rectangle with a transparent center and
/// no labels or text (design spec §5).
@MainActor
final class FocusRingView: NSView {
    private let strokeWidth: CGFloat
    private let cornerRadius: CGFloat

    init(frame: NSRect, strokeWidth: CGFloat = 2.5, cornerRadius: CGFloat = 4) {
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FocusRingView does not support NSCoder")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset = strokeWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

/// The non-activating panel hosting the focus ring (design spec §5).
@MainActor
final class FocusRingPanel: NSPanel {
    let ringView: FocusRingView

    init(frame: NSRect) {
        let view = FocusRingView(frame: NSRect(origin: .zero, size: frame.size))
        ringView = view
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = view
        // Hidden from the Accessibility tree so the ring can never become a
        // spatial navigation candidate (design spec §5).
        setAccessibilityElement(false)
        view.setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

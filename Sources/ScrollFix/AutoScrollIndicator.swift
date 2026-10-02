import AppKit

/// A visual marker for the fixed point used by automatic scrolling.
/// `show(at:)` expects AppKit screen coordinates, as returned by `NSEvent.mouseLocation`.
@MainActor
final class AutoScrollIndicator {
    private static let side: CGFloat = 36

    private let panel: IndicatorPanel

    init() {
        let frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let panel = IndicatorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = FourArrowView(frame: frame)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.panel = panel
    }

    func show(at point: CGPoint) {
        panel.setFrameOrigin(NSPoint(
            x: point.x - Self.side / 2,
            y: point.y - Self.side / 2
        ))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FourArrowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Automatisches Scrollen: Startpunkt")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Automatisches Scrollen: Startpunkt")
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        plate.fill()
        plate.lineWidth = 1
        NSColor(calibratedWhite: 1, alpha: 0.48).setStroke()
        plate.stroke()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arrows = NSBezierPath()
        arrows.lineWidth = 1.8
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round

        // Leave a small gap around the center dot so all four arrows remain legible.
        arrow(in: arrows, from: NSPoint(x: center.x, y: center.y + 3),
              tip: NSPoint(x: center.x, y: center.y + 10),
              wingA: NSPoint(x: center.x - 3, y: center.y + 7),
              wingB: NSPoint(x: center.x + 3, y: center.y + 7))
        arrow(in: arrows, from: NSPoint(x: center.x, y: center.y - 3),
              tip: NSPoint(x: center.x, y: center.y - 10),
              wingA: NSPoint(x: center.x - 3, y: center.y - 7),
              wingB: NSPoint(x: center.x + 3, y: center.y - 7))
        arrow(in: arrows, from: NSPoint(x: center.x - 3, y: center.y),
              tip: NSPoint(x: center.x - 10, y: center.y),
              wingA: NSPoint(x: center.x - 7, y: center.y + 3),
              wingB: NSPoint(x: center.x - 7, y: center.y - 3))
        arrow(in: arrows, from: NSPoint(x: center.x + 3, y: center.y),
              tip: NSPoint(x: center.x + 10, y: center.y),
              wingA: NSPoint(x: center.x + 7, y: center.y + 3),
              wingB: NSPoint(x: center.x + 7, y: center.y - 3))

        NSColor.white.setStroke()
        arrows.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2))
        NSColor.white.setFill()
        dot.fill()
    }

    private func arrow(in path: NSBezierPath, from start: NSPoint, tip: NSPoint, wingA: NSPoint, wingB: NSPoint) {
        path.move(to: start)
        path.line(to: tip)
        path.move(to: wingA)
        path.line(to: tip)
        path.line(to: wingB)
    }
}

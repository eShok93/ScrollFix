import AppKit
import CoreVideo
import QuartzCore

enum MouseWheelFrameClockKind: String, Sendable {
    case idle, displayLink, timer
    var label: String {
        switch self {
        case .idle: "Bereit"
        case .displayLink: "Bildschirmtakt"
        case .timer: "Timer"
        }
    }
}

protocol WheelDisplayPulseDriver: AnyObject {
    var displayID: UInt32 { get }
    var bounds: CGRect { get }
    func resume() -> Bool
    func pause()
    func invalidate()
}

/// Created, selected, called and destroyed on the event worker's run loop.
/// Every display is prepared while idle so changing screens does not allocate
/// a display link in the wheel callback. Only the selected display is unpaused.
final class MouseWheelFrameClock {
    private var drivers: [any WheelDisplayPulseDriver]
    private let onFrame: () -> Void
    private var activeDisplayID: UInt32?
    private var valid = true

    init(drivers: [any WheelDisplayPulseDriver] = [], onFrame: @escaping () -> Void) {
        self.drivers = drivers
        self.onFrame = onFrame
    }

    static func prepare(onFrame: @escaping () -> Void) -> MouseWheelFrameClock? {
        autoreleasepool {
            let clock = MouseWheelFrameClock(onFrame: onFrame)
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      number.uint32Value != 0 else { continue }
                let id = number.uint32Value
                let pulse: () -> Void = { [weak clock] in clock?.receivePulse(from: id) }
                if #available(macOS 14.0, *) {
                    clock.drivers.append(NativeWheelDisplayDriver(screen: screen, displayID: id, onFrame: pulse))
                } else if let driver = LegacyWheelDisplayDriver(displayID: id, onFrame: pulse) {
                    clock.drivers.append(driver)
                }
            }
            return clock.drivers.isEmpty ? nil : clock
        }
    }

    func resume(at point: CGPoint) -> Bool {
        guard valid, let selected = drivers.first(where: { $0.bounds.contains(point) }) ?? drivers.first else {
            return false
        }
        if activeDisplayID == selected.displayID { return true }
        pause()
        activeDisplayID = selected.displayID
        guard selected.resume() else { activeDisplayID = nil; selected.pause(); return false }
        return true
    }

    func pause() {
        let previous = activeDisplayID
        activeDisplayID = nil
        drivers.first(where: { $0.displayID == previous })?.pause()
    }

    func invalidate() {
        valid = false
        activeDisplayID = nil
        for driver in drivers { driver.invalidate() }
        drivers.removeAll()
    }

    func receivePulse(from displayID: UInt32) {
        guard valid, activeDisplayID == displayID else { return }
        onFrame()
    }
}

/// A health deadline independent of wheel inputs: repeated inputs cannot conceal
/// a stopped frame clock. The worker cancels the old tail before using a fallback.
struct WheelFrameClockHealth {
    private var lastPulse: UInt64?
    private var startedAt: UInt64?
    static let deadline: UInt64 = 100_000_000

    mutating func start(at now: UInt64) {
        guard startedAt == nil else { return }
        startedAt = now
    }
    mutating func pulse(at now: UInt64) { lastPulse = now }
    mutating func reset() { self = WheelFrameClockHealth() }
    func isStalled(at now: UInt64) -> Bool {
        guard let reference = lastPulse ?? startedAt else { return false }
        return now < reference || now - reference > Self.deadline
    }
}

@available(macOS 14.0, *)
private final class NativeWheelDisplayDriver: NSObject, WheelDisplayPulseDriver {
    let displayID: UInt32
    let bounds: CGRect
    private let onFrame: () -> Void
    private var link: CADisplayLink?

    init(screen: NSScreen, displayID: UInt32, onFrame: @escaping () -> Void) {
        self.displayID = displayID
        bounds = CGDisplayBounds(displayID)
        self.onFrame = onFrame
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.isPaused = true
        let rate = Float(max(30, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: RunLoop.current, forMode: .common)
        self.link = link
    }

    func resume() -> Bool { guard let link else { return false }; link.isPaused = false; return true }
    func pause() { link?.isPaused = true }
    func invalidate() { link?.invalidate(); link = nil }
    @objc private func frame(_ sender: CADisplayLink) { onFrame() }
}

/// macOS 13 compatibility. The Core Video callback only signals a coalescing
/// run-loop source. Motion and CGEvent objects remain on the event worker.
@available(macOS, introduced: 13.0, deprecated: 14.0, message: "macOS 13 compatibility only")
private final class LegacyWheelDisplayDriver: WheelDisplayPulseDriver {
    let displayID: UInt32
    let bounds: CGRect
    private let bridge: WheelDisplayPulseBridge
    private var link: CVDisplayLink?

    init?(displayID: UInt32, onFrame: @escaping () -> Void) {
        self.displayID = displayID
        bounds = CGDisplayBounds(displayID)
        bridge = WheelDisplayPulseBridge(onFrame: onFrame)
        guard bridge.isReady else { bridge.invalidate(); return nil }
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &created) == kCVReturnSuccess,
              let created,
              CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                  guard let context else { return kCVReturnSuccess }
                  Unmanaged<WheelDisplayPulseBridge>.fromOpaque(context).takeUnretainedValue().signal()
                  return kCVReturnSuccess
              }, Unmanaged.passUnretained(bridge).toOpaque()) == kCVReturnSuccess else {
            bridge.invalidate()
            return nil
        }
        link = created
    }

    func resume() -> Bool {
        guard let link else { return false }
        bridge.setActive(true)
        if CVDisplayLinkIsRunning(link) { return true }
        guard CVDisplayLinkStart(link) == kCVReturnSuccess else { bridge.setActive(false); return false }
        return true
    }
    func pause() {
        bridge.setActive(false)
        if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }
    func invalidate() { pause(); link = nil; bridge.invalidate() }
}

private final class WheelDisplayPulseBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let loop: CFRunLoop
    private let onFrame: () -> Void
    private var source: CFRunLoopSource?
    private var active = false

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return source != nil }

    init(onFrame: @escaping () -> Void) {
        loop = CFRunLoopGetCurrent()
        self.onFrame = onFrame
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { pointer in
            guard let pointer else { return }
            Unmanaged<WheelDisplayPulseBridge>.fromOpaque(pointer).takeUnretainedValue().deliver()
        }
        source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        if let source { CFRunLoopAddSource(loop, source, .commonModes) }
    }
    func setActive(_ value: Bool) { lock.lock(); active = value && source != nil; lock.unlock() }
    func signal() {
        lock.lock()
        if active, let source { CFRunLoopSourceSignal(source); CFRunLoopWakeUp(loop) }
        lock.unlock()
    }
    private func deliver() {
        lock.lock(); let allowed = active; lock.unlock()
        if allowed { onFrame() }
    }
    func invalidate() {
        lock.lock(); active = false; let previous = source; source = nil; lock.unlock()
        if let previous {
            CFRunLoopRemoveSource(loop, previous, .commonModes)
            CFRunLoopSourceInvalidate(previous)
        }
    }
}

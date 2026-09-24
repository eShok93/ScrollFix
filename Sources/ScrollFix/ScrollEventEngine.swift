import AppKit
import CoreGraphics
import Foundation

/// Makes trackpad scrolling natural and discrete mouse-wheel scrolling classic.
final class ScrollEventEngine {
    var onRunningChange: ((Bool, String?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reverseTouchSurface = false
    private var lastTouchTime: UInt64 = 0
    private var touchCount = 0
    private var lastSourceWasTouchSurface = false

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start(reverseTouchSurface: Bool) {
        self.reverseTouchSurface = reverseTouchSurface
        if let eventTap {
            if CGEvent.tapIsEnabled(tap: eventTap) { return }
            stop()
        }
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << NSEvent.EventType.gesture.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.receive,
            userInfo: context
        ) else {
            onRunningChange?(false, "macOS hat den Scrollfilter abgewiesen.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onRunningChange?(true, nil)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        onRunningChange?(false, nil)
    }

    private static let receive: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<ScrollEventEngine>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = engine.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                let running = CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
                engine.onRunningChange?(running, running ? nil : "macOS hat den Scroll-Ereignisfilter pausiert.")
            }
            return Unmanaged.passUnretained(event)
        }

        if type.rawValue == NSEvent.EventType.gesture.rawValue {
            let touching = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil).count ?? 0
            if touching >= 2 {
                engine.lastTouchTime = DispatchTime.now().uptimeNanoseconds
                engine.touchCount = max(engine.touchCount, touching)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        return Unmanaged.passUnretained(engine.rewriteWheelEvent(event))
    }

    func rewriteWheelEvent(_ event: CGEvent) -> CGEvent {
        let gesturePhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let isPrecise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        // Two-finger gestures distinguish a trackpad from a high-resolution mouse,
        // which may also send continuous scroll events. Keep the last known source
        // during momentum, where the touch signal may already have ended.
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastTouchTime == 0 ? UInt64.max : now &- lastTouchTime
        let touching = touchCount
        touchCount = 0
        let isTouchSurface: Bool
        if !isPrecise && gesturePhase == 0 && momentumPhase == 0 {
            isTouchSurface = false
        } else if touching >= 2 && elapsed < 222_000_000 {
            isTouchSurface = true
        } else if momentumPhase == 0 && elapsed > 333_000_000 {
            isTouchSurface = false
        } else {
            isTouchSurface = lastSourceWasTouchSurface
        }
        lastSourceWasTouchSurface = isTouchSurface
        guard isTouchSurface == reverseTouchSurface else { return event }

        let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let pointDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixedDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let acceleratedDelta = event.getIntegerValueField(.scrollWheelEventAcceleratedDeltaAxis1)
        let rawDelta = event.getIntegerValueField(.scrollWheelEventRawDeltaAxis1)
        guard lineDelta != 0 || pointDelta != 0 || fixedDelta != 0 || acceleratedDelta != 0 || rawDelta != 0 else {
            return event
        }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineDelta)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedDelta)
        event.setIntegerValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: -acceleratedDelta)
        event.setIntegerValueField(.scrollWheelEventRawDeltaAxis1, value: -rawDelta)
        return event
    }
}

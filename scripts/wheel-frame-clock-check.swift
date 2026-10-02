import AppKit
import Foundation

/// Observe the real frame clock on its worker run loop. No event tap, CGEvent,
/// input posting, visible window or permission request is used.
private final class ClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [UInt64] = []
    private var callbacksOnMain = 0
    private var result = ""
    private var finished = false
    private var succeeded = false

    func frame() {
        lock.lock()
        times.append(DispatchTime.now().uptimeNanoseconds)
        if Thread.isMainThread { callbacksOnMain += 1 }
        lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func complete(idle: Int, active: Int, paused: Int, invalidated: Int) {
        lock.lock(); defer { lock.unlock() }
        let gaps = zip(times, times.dropFirst()).map { Double($1 - $0) / 1_000_000 }.sorted()
        let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let maximum = gaps.last ?? 0
        succeeded = idle == 0 && active >= 8 && paused == active && invalidated == active && callbacksOnMain == 0
        result = String(format: "Frame clock: idle=%d active=%d paused=%d invalidated=%d mainCallbacks=%d median=%.2fms max=%.2fms",
                        idle, active, paused, invalidated, callbacksOnMain, median, maximum)
        finished = true
    }
    func fail() { lock.lock(); result = "Frame clock unavailable"; finished = true; lock.unlock() }
    func report() -> Bool { lock.lock(); defer { lock.unlock() }; print(result); return succeeded }
}

@main
struct WheelFrameClockCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let probe = ClockProbe()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        let worker = Thread {
            autoreleasepool {
                let loop = CFRunLoopGetCurrent()
                let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                    CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0) { _ in }
                CFRunLoopAddTimer(loop, keepAlive, .defaultMode)
                defer { CFRunLoopTimerInvalidate(keepAlive) }
                guard let clock = MouseWheelFrameClock.prepare(onFrame: { probe.frame() }) else { probe.fail(); return }
                CFRunLoopRunInMode(.defaultMode, 0.12, false)
                let idle = probe.count
                guard clock.resume(at: point) else { clock.invalidate(); probe.fail(); return }
                CFRunLoopRunInMode(.defaultMode, 0.45, false)
                let active = probe.count
                clock.pause()
                CFRunLoopRunInMode(.defaultMode, 0.12, false)
                let paused = probe.count
                clock.invalidate()
                CFRunLoopRunInMode(.defaultMode, 0.12, false)
                probe.complete(idle: idle, active: active, paused: paused, invalidated: probe.count)
            }
        }
        worker.name = "ScrollFix.frame-clock-check"
        worker.start()
        let deadline = Date().addingTimeInterval(3)
        while !probe.isFinished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard probe.isFinished, probe.report() else { exit(1) }
    }
}

import CoreGraphics
import Foundation

struct ScrollTapDiagnosticCounters {
    private(set) var tapTimeoutCount: UInt64 = 0
    private(set) var maxCallbackDurationNanoseconds: UInt64 = 0

    mutating func recordTimeout() { tapTimeoutCount &+= 1 }

    mutating func recordCallbackDuration(_ duration: UInt64) {
        maxCallbackDurationNanoseconds = max(maxCallbackDurationNanoseconds, duration)
    }

    mutating func reset() { self = .init() }
}

/// Owns the active scroll tap and every mutable part of its callback on one
/// dedicated run-loop thread. Main-thread clients exchange only value commands
/// and snapshots; CGEvent and Core Foundation ports never cross that boundary.
final class ScrollEventTapWorker: @unchecked Sendable {
    struct Snapshot: Sendable {
        let sequence: UInt64
        let generation: UInt64
        let isRunning: Bool
        let isPausedByUserInput: Bool
        let isTerminal: Bool
        let issue: String?
        let usingTrackpadOnlyFastPath: Bool
        let lastDecision: ScrollSourceClassifier.Decision?
        let directionRecords: [ScrollDirectionTrace.Record]
        let tapTimeoutCount: UInt64
        let maxCallbackDurationNanoseconds: UInt64
        var wheelSamples: [MouseWheelSample] = []
        var wheelPostedFrames: UInt64 = 0
        var wheelMaxTickGapNanoseconds: UInt64 = 0
        var wheelFrameClock: MouseWheelFrameClockKind = .idle
    }

    enum Command: Sendable {
        case start(generation: UInt64, reverseTouchSurface: Bool)
        case stop(generation: UInt64)
        case verify(generation: UInt64)
        case setReverseTouchSurface(Bool)
        case setTrackpadOnlyEligible(Bool, at: UInt64)
        case setWheelConfiguration(MouseWheelConfiguration)
        case cancelWheelMotion
        case refreshWheelFrameClock
        case resetClassification(ScrollDirectionTrace.ResetReason)
        case resumeAfterUserInputDisable
        case snapshot(generation: UInt64)
        case removeTapAfterUserInput
        case shutdown
    }

    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let simulateBootstrapFailureForTesting: Bool
    private let lock = NSLock()
    private let threadStopped = DispatchSemaphore(value: 0)
    // The lock protects the cross-thread command mailbox and run-loop handles.
    private var pendingCommands: [Command] = []
    private var runLoop: CFRunLoop?
    private var commandSource: CFRunLoopSource?
    private var acceptingCommands = true
    private var bootstrapFailure: String?
    private var snapshotSequence: UInt64 = 0

    // Everything below is accessed exclusively on the worker run-loop thread.
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var rewriter: ScrollWheelRewriter
    private let wheel: MouseWheelPipeline
    private var wheelTimer: CFRunLoopTimer?
    private var wheelDisplayClock: MouseWheelFrameClock?
    private var wheelHealthTimer: CFRunLoopTimer?
    private var wheelClockHealth = WheelFrameClockHealth()
    private var wheelFrameClock: MouseWheelFrameClockKind = .idle
    private var wheelDisplayRetryAfter: UInt64 = 0
    private var generation: UInt64 = 0
    private var isPausedByUserInput = false
    private var issue: String?
    private let collectDiagnostics: Bool
    private var diagnosticCounters = ScrollTapDiagnosticCounters()

    init(
        reverseTouchSurface: Bool,
        collectDirectionTrace: Bool,
        simulateBootstrapFailureForTesting: Bool = false,
        onSnapshot: @escaping @Sendable (Snapshot) -> Void
    ) {
        self.rewriter = ScrollWheelRewriter(
            reverseTouchSurface: reverseTouchSurface,
            collectDirectionTrace: collectDirectionTrace
        )
        self.collectDiagnostics = collectDirectionTrace
        self.wheel = MouseWheelPipeline(collectDiagnostics: collectDirectionTrace)
        self.simulateBootstrapFailureForTesting = simulateBootstrapFailureForTesting
        self.onSnapshot = onSnapshot
        let thread = Thread { [self] in run() }
        thread.name = "ScrollFix scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func enqueue(_ command: Command) {
        lock.lock()
        guard acceptingCommands else {
            let failure = bootstrapFailure
            let sequence: UInt64?
            if failure != nil, case .start = command {
                snapshotSequence &+= 1
                sequence = snapshotSequence
            } else {
                sequence = nil
            }
            lock.unlock()
            if let failure, let sequence, case let .start(generation, _) = command {
                onSnapshot(.init(
                    sequence: sequence, generation: generation, isRunning: false,
                    isPausedByUserInput: false, isTerminal: true, issue: failure,
                    usingTrackpadOnlyFastPath: false, lastDecision: nil,
                    directionRecords: [], tapTimeoutCount: 0,
                    maxCallbackDurationNanoseconds: 0
                ))
            }
            return
        }
        pendingCommands.append(command)
        let source = commandSource
        let loop = runLoop
        lock.unlock()
        if let source { CFRunLoopSourceSignal(source) }
        if let loop { CFRunLoopWakeUp(loop) }
    }

    func shutdown() {
        lock.lock()
        guard acceptingCommands else { lock.unlock(); return }
        acceptingCommands = false
        // A queued start must never re-create the tap after teardown begins.
        pendingCommands = [.shutdown]
        let source = commandSource
        let loop = runLoop
        lock.unlock()
        if let source { CFRunLoopSourceSignal(source) }
        if let loop { CFRunLoopWakeUp(loop) }
    }

    /// Test-only synchronization; the app never waits for teardown on main.
    func waitForShutdownForTesting(timeout: DispatchTime) -> Bool {
        threadStopped.wait(timeout: timeout) == .success
    }

    private func run() {
        if simulateBootstrapFailureForTesting {
            reportBootstrapFailure()
            threadStopped.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { context in
            guard let context else { return }
            let worker = Unmanaged<ScrollEventTapWorker>.fromOpaque(context).takeUnretainedValue()
            worker.drainCommands()
        }
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            reportBootstrapFailure()
            threadStopped.signal()
            return
        }
        CFRunLoopAddSource(loop, source, .commonModes)
        lock.lock()
        runLoop = loop
        commandSource = source
        let hasPendingCommands = !pendingCommands.isEmpty
        lock.unlock()
        if hasPendingCommands { CFRunLoopSourceSignal(source) }
        CFRunLoopRun()
        tearDownTap()
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        lock.lock()
        runLoop = nil
        commandSource = nil
        pendingCommands.removeAll()
        acceptingCommands = false
        lock.unlock()
        threadStopped.signal()
    }

    private func reportBootstrapFailure() {
        lock.lock()
        let latestGeneration = pendingCommands.compactMap { command -> UInt64? in
            switch command {
            case .start(let generation, _), .stop(let generation),
                 .verify(let generation), .snapshot(let generation): generation
            default: nil
            }
        }.last ?? 0
        let failure = "Der Scrollfilter-Thread konnte nicht starten."
        bootstrapFailure = failure
        acceptingCommands = false
        pendingCommands.removeAll()
        lock.unlock()
        generation = latestGeneration
        issue = failure
        publishSnapshot(isTerminal: true)
    }

    private func drainCommands() {
        while true {
            lock.lock()
            let commands = pendingCommands
            pendingCommands.removeAll()
            lock.unlock()
            guard !commands.isEmpty else { return }
            for command in commands {
                if process(command) { return }
            }
        }
    }

    /// Returns true when the run loop is shutting down.
    @discardableResult
    private func process(_ command: Command) -> Bool {
        switch command {
        case .start(let nextGeneration, let reverseTouchSurface):
            if generation != nextGeneration { resetDiagnostics() }
            generation = nextGeneration
            rewriter.reverseTouchSurface = reverseTouchSurface
            guard !isPausedByUserInput else { publishSnapshot(); return false }
            if eventTap == nil { createTap() } else { verifyTap() }
            publishSnapshot()
        case .stop(let nextGeneration):
            generation = nextGeneration
            tearDownTap()
            resetDiagnostics()
            issue = nil
            publishSnapshot()
        case .verify(let nextGeneration):
            generation = nextGeneration
            if !isPausedByUserInput { verifyTap() }
            if wheel.configuration.effectiveFeel == .smooth { _ = ensureWheelDisplayClock() }
            publishSnapshot()
        case .setReverseTouchSurface(let reverseTouchSurface):
            cancelWheelMotion()
            rewriter.reverseTouchSurface = reverseTouchSurface
        case .setTrackpadOnlyEligible(let eligible, let monotonicTime):
            cancelWheelMotion()
            rewriter.setTrackpadOnlyEligible(eligible, at: monotonicTime)
            publishSnapshot()
        case .setWheelConfiguration(let configuration):
            wheel.configure(configuration)
            if configuration.effectiveFeel.requiresPosting { _ = ensureWheelTimer() }
            if configuration.effectiveFeel == .smooth {
                _ = ensureWheelDisplayClock()
                ensureWheelHealthTimer()
            }
            wheelFrameClock = .idle
            if !wheel.isActive { parkWheelClocks() }
        case .cancelWheelMotion:
            cancelWheelMotion()
        case .refreshWheelFrameClock:
            cancelWheelMotion()
            wheelDisplayClock?.invalidate()
            wheelDisplayClock = nil
            wheelDisplayRetryAfter = 0
            if wheel.configuration.effectiveFeel == .smooth { _ = ensureWheelDisplayClock() }
        case .resetClassification(let reason):
            cancelWheelMotion()
            rewriter.resetClassification(reason: reason)
            publishSnapshot()
        case .resumeAfterUserInputDisable:
            isPausedByUserInput = false
            issue = nil
            publishSnapshot()
        case .snapshot(let nextGeneration):
            generation = nextGeneration
            publishSnapshot()
        case .removeTapAfterUserInput:
            tearDownTap()
            publishSnapshot()
        case .shutdown:
            tearDownTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
            return true
        }
        return false
    }

    private func createTap() {
        rewriter.resetClassification()
        cancelWheelMotion()
        let observed: [CGEventType] = [.scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                      .otherMouseDragged, .leftMouseDown, .rightMouseDown,
                                      .otherMouseDown, .flagsChanged]
        let mask = observed.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.receive,
            userInfo: context
        ) else {
            issue = "macOS hat den Scrollfilter abgewiesen."
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        issue = tapIsRunning ? nil : "macOS hat den Scrollfilter pausiert."
    }

    private func verifyTap() {
        guard let tap = eventTap else { createTap(); return }
        guard !tapIsRunning else { issue = nil; return }
        cancelWheelMotion()
        rewriter.resetClassification()
        if CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if tapIsRunning { issue = nil; return }
        }
        tearDownTap()
        createTap()
    }

    private var tapIsRunning: Bool {
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    private func tearDownTap() {
        cancelWheelMotion()
        wheelDisplayClock?.invalidate()
        wheelDisplayClock = nil
        wheelFrameClock = .idle
        if let timer = wheelHealthTimer {
            CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            CFRunLoopTimerInvalidate(timer)
            wheelHealthTimer = nil
        }
        if let timer = wheelTimer {
            CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            CFRunLoopTimerInvalidate(timer)
            wheelTimer = nil
        }
        if let source = eventSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        eventSource = nil
        eventTap = nil
        rewriter.resetClassification()
    }

    private func ensureWheelTimer() -> Bool {
        if wheelTimer != nil { return true }
        var context = CFRunLoopTimerContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        guard let timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 86_400_000,
                                              1.0 / 120, 0, 0, { _, context in
            guard let context else { return }
            Unmanaged<ScrollEventTapWorker>.fromOpaque(context).takeUnretainedValue().tickWheel()
        }, &context) else { return false }
        wheelTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        return true
    }

    private func parkWheelTimer() {
        if let timer = wheelTimer,
           CFRunLoopTimerGetNextFireDate(timer) < CFAbsoluteTimeGetCurrent() + 1 {
            CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 86_400_000)
        }
    }

    private func parkWheelClocks() {
        parkWheelTimer()
        wheelDisplayClock?.pause()
        wheelClockHealth.reset()
        if let timer = wheelHealthTimer,
           CFRunLoopTimerGetNextFireDate(timer) < CFAbsoluteTimeGetCurrent() + 1 {
            CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 86_400_000)
        }
    }

    private func ensureWheelDisplayClock() -> Bool {
        if wheelDisplayClock != nil { return true }
        guard DispatchTime.now().uptimeNanoseconds >= wheelDisplayRetryAfter else { return false }
        wheelDisplayClock = MouseWheelFrameClock.prepare { [weak self] in
            guard let self else { return }
            self.wheelClockHealth.pulse(at: DispatchTime.now().uptimeNanoseconds)
            self.tickWheel()
        }
        return wheelDisplayClock != nil
    }

    private func ensureWheelHealthTimer() {
        guard wheelHealthTimer == nil else { return }
        var context = CFRunLoopTimerContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        wheelHealthTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 86_400_000,
                                               0.05, 0, 0, { _, pointer in
            guard let pointer else { return }
            Unmanaged<ScrollEventTapWorker>.fromOpaque(pointer).takeUnretainedValue().checkWheelClockHealth()
        }, &context)
        if let timer = wheelHealthTimer { CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes) }
    }

    private func prepareWheelFrames(at point: CGPoint) -> Bool {
        if wheel.configuration.effectiveFeel == .smooth,
           let clock = wheelDisplayClock, clock.resume(at: point), let timer = wheelHealthTimer {
            wheelFrameClock = .displayLink
            parkWheelTimer()
            wheelClockHealth.start(at: DispatchTime.now().uptimeNanoseconds)
            if CFRunLoopTimerGetNextFireDate(timer) > CFAbsoluteTimeGetCurrent() + 1 {
                CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 0.05)
            }
            return true
        }
        wheelDisplayClock?.pause()
        wheelClockHealth.reset()
        if let timer = wheelHealthTimer {
            CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 86_400_000)
        }
        let ready = ensureWheelTimer()
        wheelFrameClock = ready ? .timer : .idle
        return ready
    }

    private func checkWheelClockHealth() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard wheel.isActive, wheelFrameClock == .displayLink else { return }
        guard wheelClockHealth.isStalled(at: now) else { return }
        // Drop the stale movement before switching clocks. A resumed display
        // link must never emit an old gesture into the foreground application.
        cancelWheelMotion()
        wheelDisplayClock?.invalidate()
        wheelDisplayClock = nil
        wheelDisplayRetryAfter = now + 3_000_000_000
        wheelFrameClock = .timer
        publishSnapshot()
    }

    private func cancelWheelMotion() {
        wheel.cancel()
        parkWheelClocks()
    }

    private func tickWheel() {
        guard tapIsRunning, !isPausedByUserInput, wheel.configuration.canPost else {
            cancelWheelMotion()
            return
        }
        if let frame = wheel.nextFrame(at: DispatchTime.now().uptimeNanoseconds) {
            frame.post(tap: .cgSessionEventTap)
            wheel.recordPostedFrame()
        }
        if !wheel.isActive { parkWheelClocks() }
    }

    private func resetDiagnostics() {
        rewriter.clearDirectionTrace()
        diagnosticCounters.reset()
        wheel.cancel(clearDiagnostics: true)
    }

    private func publishSnapshot(isTerminal: Bool = false) {
        lock.lock()
        snapshotSequence &+= 1
        let sequence = snapshotSequence
        lock.unlock()
        onSnapshot(.init(
            sequence: sequence, generation: generation,
            isRunning: !isPausedByUserInput && tapIsRunning,
            isPausedByUserInput: isPausedByUserInput, isTerminal: isTerminal,
            issue: issue, usingTrackpadOnlyFastPath: rewriter.trackpadOnlyFastPath.selected,
            lastDecision: rewriter.lastDecision, directionRecords: rewriter.recentDirectionRecords,
            tapTimeoutCount: diagnosticCounters.tapTimeoutCount,
            maxCallbackDurationNanoseconds: diagnosticCounters.maxCallbackDurationNanoseconds,
            wheelSamples: wheel.samples, wheelPostedFrames: wheel.postedFrames,
            wheelMaxTickGapNanoseconds: wheel.maxTickGapNanoseconds,
            wheelFrameClock: wheelFrameClock
        ))
    }

    private static let receive: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let worker = Unmanaged<ScrollEventTapWorker>.fromOpaque(context).takeUnretainedValue()
        return worker.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let callbackStart = collectDiagnostics ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if collectDiagnostics {
                let callbackEnd = DispatchTime.now().uptimeNanoseconds
                if callbackEnd >= callbackStart {
                    diagnosticCounters.recordCallbackDuration(callbackEnd - callbackStart)
                }
            }
        }
        if type == .tapDisabledByUserInput {
            cancelWheelMotion()
            isPausedByUserInput = true
            issue = "macOS hat den Scroll-Ereignisfilter deaktiviert."
            rewriter.resetClassification(reason: .userInput)
            publishSnapshot()
            enqueue(.removeTapAfterUserInput)
            return nil
        }
        if type == .tapDisabledByTimeout {
            cancelWheelMotion()
            if collectDiagnostics { diagnosticCounters.recordTimeout() }
            rewriter.resetClassification(reason: .tapTimeout)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            issue = tapIsRunning ? nil : "macOS hat den Scroll-Ereignisfilter pausiert."
            publishSnapshot()
            return nil
        }
        guard type == .scrollWheel else {
            // Observe cancellation boundaries; do not consume clicks or key input.
            cancelWheelMotion()
            return Unmanaged.passUnretained(event)
        }
        let result = rewriter.rewriteWheelEvent(event)
        let wantsFrames = wheel.configuration.effectiveFeel.requiresPosting
            && rewriter.lastDecision?.source == .mouseWheel && !ScrollFixSyntheticEvent.isGenerated(result)
        let canAnimate = !wantsFrames || prepareWheelFrames(at: result.location)
        let output = wheel.process(result, source: rewriter.lastDecision?.source,
                                   at: DispatchTime.now().uptimeNanoseconds, canAnimate: canAnimate)
        if wheel.isActive, wheelFrameClock == .timer, let timer = wheelTimer {
            // Only arm an idle timer: repeated wheel ticks must not postpone frames.
            if CFRunLoopTimerGetNextFireDate(timer) > CFAbsoluteTimeGetCurrent() + 1 {
                CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 1.0 / 120)
            }
        } else if !wheel.isActive { parkWheelClocks() }
        return output.map { Unmanaged.passUnretained($0) }
    }
}

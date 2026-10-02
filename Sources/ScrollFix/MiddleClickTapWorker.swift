@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// The button pair and AX lookup belong to this run-loop thread. UI work never
/// blocks its event tap; only value snapshots are delivered to the main actor.
final class MiddleClickTapWorker: @unchecked Sendable {
    enum Action: Sendable { case unchanged, start(CGPoint), stop }
    struct Snapshot: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let running: Bool
        let paused: Bool
        let action: Action
        let interaction: Bool
        let target: MiddleClickTarget?
        let lookupMilliseconds: Double?
    }
    private enum Command: Sendable {
        case configure(enabled: Bool, generation: UInt64, rebuild: Bool)
        case resume
        case shutdown
    }

    private let lock = NSLock()
    private var commands: [Command] = []
    private var loop: CFRunLoop?
    private var commandSource: CFRunLoopSource?
    private var accepting = true
    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let collectDiagnostics: Bool

    // Worker-owned state. Never read or mutate these from the main actor.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: CFRunLoopTimer?
    private var resolver: MiddleClickTargetResolver?
    private var routing = MiddleClickRouting()
    private var enabled = false
    private var paused = false
    private var scrolling = false
    private var pendingAnchor: CGPoint?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var releaseDeadline: UInt64 = 0
    private var forcedReleaseDeadline: UInt64 = 0
    private var releasedSince: UInt64?
    private var sawPhysicalDown = false

    init(collectDiagnostics: Bool, onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        self.collectDiagnostics = collectDiagnostics
        self.onSnapshot = onSnapshot
        let thread = Thread { [self] in run() }
        thread.name = "ScrollFix middle click"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func configure(enabled: Bool, generation: UInt64, rebuild: Bool = false) {
        enqueue(.configure(enabled: enabled, generation: generation, rebuild: rebuild))
    }
    func resume() { enqueue(.resume) }
    func shutdown() {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        accepting = false
        commands = [.shutdown]
        let source = commandSource, currentLoop = loop
        lock.unlock()
        if let source { CFRunLoopSourceSignal(source) }
        if let currentLoop { CFRunLoopWakeUp(currentLoop) }
    }
    private func enqueue(_ command: Command) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        commands.append(command)
        let source = commandSource, currentLoop = loop
        lock.unlock()
        if let source { CFRunLoopSourceSignal(source) }
        if let currentLoop { CFRunLoopWakeUp(currentLoop) }
    }

    private func run() {
        let currentLoop = CFRunLoopGetCurrent()
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { pointer in
            guard let pointer else { return }
            Unmanaged<MiddleClickTapWorker>.fromOpaque(pointer).takeUnretainedValue().drain()
        }
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            lock.lock()
            for case let .configure(_, requestedGeneration, _) in commands { generation = requestedGeneration }
            commands.removeAll()
            accepting = false
            lock.unlock()
            publish(.stop)
            return
        }
        CFRunLoopAddSource(currentLoop, source, .commonModes)
        lock.lock()
        loop = currentLoop
        commandSource = source
        let pending = !commands.isEmpty
        lock.unlock()
        if pending { CFRunLoopSourceSignal(source) }
        CFRunLoopRun()
        removeTap()
        CFRunLoopRemoveSource(currentLoop, source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        lock.lock()
        loop = nil
        commandSource = nil
        commands.removeAll()
        accepting = false
        lock.unlock()
    }

    private var running: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }
    private func publish(_ action: Action = .unchanged, interaction: Bool = false,
                         target: MiddleClickTarget? = nil, milliseconds: Double? = nil) {
        sequence &+= 1
        onSnapshot(.init(generation: generation, sequence: sequence, running: running,
                         paused: paused, action: action, interaction: interaction,
                         target: target, lookupMilliseconds: milliseconds))
    }
    private func drain() {
        lock.lock()
        let pending = commands
        commands.removeAll()
        lock.unlock()
        for command in pending {
            switch command {
            case let .configure(wanted, newGeneration, rebuild):
                let changed = enabled != wanted || generation != newGeneration || rebuild
                generation = newGeneration
                enabled = wanted
                if changed {
                    scrolling = false
                    pendingAnchor = nil
                    if rebuild { removeTap() }
                }
                if wanted && !paused { installTap() }
                // Drain a captured release even when the setting is switched off.
                if !wanted && !routing.isCapturing { removeTap() }
                publish(changed ? .stop : .unchanged)
            case .resume:
                paused = false
                removeTap()
                if enabled { installTap() }
                publish(.stop)
            case .shutdown:
                enabled = false
                removeTap()
                CFRunLoopStop(CFRunLoopGetCurrent())
                return
            }
        }
    }
    private func installTap() {
        if running { return }
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if running { return }
        }
        removeTap()
        if resolver == nil { resolver = MiddleClickTargetResolver() }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                    .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MiddleClickTapWorker>.fromOpaque(pointer).takeUnretainedValue()
                    .handle(type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            return
        }
        tap = newTap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }
    private func removeTap() {
        cancelWatchdog()
        scrolling = false
        pendingAnchor = nil
        routing.resetAfterTapRemoval(dropLateCapturedUp: routing.isCapturing || routing.dropsLateCapturedUp)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            // AX/UI delays must not discard an already captured press. Its
            // matching release may still be queued and can complete the action.
            if let tap, enabled || routing.isCapturing { CGEvent.tapEnable(tap: tap, enable: true) }
            if !running { scrolling = false; pendingAnchor = nil }
            publish(running ? .unchanged : .stop)
            return nil
        }
        if type == .tapDisabledByUserInput {
            paused = true
            removeTap()
            publish(.stop)
            return nil
        }
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let middle = event.getIntegerValueField(.mouseEventButtonNumber) == 2
            && (type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged)
        guard middle else {
            if isDown {
                scrolling = false
                pendingAnchor = nil
                publish(.stop, interaction: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDragged {
            return routing.dragRoute == .captured ? nil : Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            if let held = routing.heldRoute { return held == .captured ? nil : Unmanaged.passUnretained(event) }
            let start = DispatchTime.now().uptimeNanoseconds
            let point = event.location
            let anchor = MiddleClickRouting.appKitAnchor(from: point,
                primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
            let target: MiddleClickTarget = !enabled || MiddleClickRouting.preservesNativeModifiers(event.flags)
                ? .nativeControl : (anchor == nil ? .unknown : resolver?.target(at: point) ?? .unknown)
            let route = routing.down { target.route }
            let elapsed = collectDiagnostics ? Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000 : nil
            if route == .native {
                scrolling = false
                pendingAnchor = nil
                publish(.stop, interaction: true, target: collectDiagnostics ? target : nil, milliseconds: elapsed)
                return Unmanaged.passUnretained(event)
            }
            pendingAnchor = scrolling ? nil : anchor
            scrolling = false
            startWatchdog()
            publish(.stop, interaction: true, target: collectDiagnostics ? target : nil, milliseconds: elapsed)
            return nil
        }
        let captured = routing.isCapturing
        let route = routing.up()
        if captured {
            cancelWatchdog()
            if enabled, let anchor = pendingAnchor {
                pendingAnchor = nil
                scrolling = true
                publish(.start(anchor))
            } else {
                pendingAnchor = nil
                publish(.stop)
                if !enabled { removeTap() }
            }
        }
        return route == .captured ? nil : Unmanaged.passUnretained(event)
    }
    private func startWatchdog() {
        cancelWatchdog()
        let now = DispatchTime.now().uptimeNanoseconds
        releaseDeadline = now &+ 4_000_000_000
        forcedReleaseDeadline = now &+ 30_000_000_000
        sawPhysicalDown = CGEventSource.buttonState(.hidSystemState, button: .center)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0) { [weak self] _ in self?.checkRelease() }
        watchdog = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }
    private func cancelWatchdog() {
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        watchdog = nil
        releasedSince = nil
    }
    private func checkRelease() {
        guard routing.isCapturing else { cancelWatchdog(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        let down = CGEventSource.buttonState(.hidSystemState, button: .center)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
        if down { releasedSince = nil; sawPhysicalDown = true }
        else if releasedSince == nil { releasedSince = now }
        // Allow queued ups to drain before declaring a release lost. Polling the
        // global physical state once can otherwise cancel a perfectly real click.
        let releasedLongEnough = releasedSince.map { now >= $0 && now - $0 >= 300_000_000 } ?? false
        guard now >= forcedReleaseDeadline
            || ((sawPhysicalDown || now >= releaseDeadline) && releasedLongEnough) else { return }
        routing.expireCapturedRelease()
        pendingAnchor = nil
        scrolling = false
        cancelWatchdog()
        publish(.stop)
        if !enabled { removeTap() }
    }
}

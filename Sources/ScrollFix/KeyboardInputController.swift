@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Carbon

@MainActor
final class KeyboardInputController {
    var onState: ((Bool, String?) -> Void)?
    var onSecureInput: ((Bool) -> Void)?
    var onNavigationDiagnostic: ((UInt16, UInt64, InputContext, HomeEndSettings, Bool, String) -> Void)?
    private let focus = TextFocusMonitor()
    private var worker: KeyboardTapWorker?
    private var settings = HomeEndSettings()
    private var enabled = false
    private var generation: UInt64 = 0
    private var stateInbox = KeyboardStateInbox()

    func configure(_ settings: HomeEndSettings, active: Bool) {
        self.settings = settings
        guard active && settings.enabled else {
            if enabled {
                enabled = false; generation &+= 1
                focus.stop(); worker?.shutdown(); worker = nil
            }
            onState?(false, nil)
            return
        }
        if !enabled {
            enabled = true; generation &+= 1
            stateInbox = .init()
            let token = generation
            let newWorker = KeyboardTapWorker(settings: settings) { [weak self] state in
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == token,
                          self.stateInbox.accept(state) else { return }
                    self.onState?(state.running, state.issue)
                }
            }
            worker = newWorker
            if Bundle.main.object(forInfoDictionaryKey: "ScrollFixBuildKind") as? String == "qa" {
                newWorker.onNavigationDiagnostic = { [weak self] code, flags, context, settings, replaced, focusReadStatus in
                    Task { @MainActor in
                        guard let self, self.enabled, self.generation == token else { return }
                        self.onNavigationDiagnostic?(code, flags, context, settings, replaced, focusReadStatus)
                    }
                }
            }
            focus.onChange = { [weak self] context in self?.worker?.setContext(context) }
            newWorker.onFocusRefresh = { [weak self] in
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == token else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                        guard let self, self.enabled, self.generation == token else { return }
                        self.focus.refresh()
                    }
                }
            }
            focus.start()
            newWorker.start()
        } else { worker?.setSettings(settings) }
    }

    func refreshSecureInput() {
        guard enabled else { return }
        // Carbon explicitly documents this API as not thread safe. All reads
        // are serialized on MainActor, including TextFocusMonitor.
        let secure = IsSecureEventInputEnabled()
        worker?.setSecureInput(secure)
        onSecureInput?(secure)
    }

    func retry() {
        let saved = settings
        configure(saved, active: false)
        configure(saved, active: true)
    }

    isolated deinit { focus.stop(); worker?.shutdown() }
}

/// Single thread owns the tap, source and routing. The lock protects a small
/// value mailbox; no main-thread wait, AX lookup, disk access or logging in tap.
private final class KeyboardTapWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: HomeEndSettings
    private var focusCache = FocusContextCache()
    private var stopping = false
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var wakeSource: CFRunLoopSource?
    private var eventSource: CGEventSource?
    private var routing = HomeEndRouting()
    private let report: @Sendable (KeyboardTapState) -> Void
    private var sequence: UInt64 = 0
    var onFocusRefresh: (@Sendable () -> Void)?
    var onNavigationDiagnostic: (@Sendable (UInt16, UInt64, InputContext, HomeEndSettings, Bool, String) -> Void)?

    init(settings: HomeEndSettings, report: @escaping @Sendable (KeyboardTapState) -> Void) {
        self.settings = settings; self.report = report
    }

    func setContext(_ snapshot: FocusSnapshot) { lock.withLock { _ = focusCache.update(snapshot) } }
    func setSettings(_ settings: HomeEndSettings) { lock.withLock { self.settings = settings } }
    func setSecureInput(_ value: Bool) { lock.withLock { focusCache.setSecureInput(value) } }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "ScrollFix keyboard input"
        thread.start()
    }

    func shutdown() {
        let pair: (CFRunLoop?, CFRunLoopSource?) = lock.withLock {
            stopping = true
            return (loop, wakeSource)
        }
        if let source = pair.1 { CFRunLoopSourceSignal(source) }
        if let loop = pair.0 { CFRunLoopWakeUp(loop) }
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()!
        var sourceContext = CFRunLoopSourceContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil,
            perform: { pointer in
                guard let pointer else { return }
                let worker = Unmanaged<KeyboardTapWorker>.fromOpaque(pointer).takeUnretainedValue()
                if worker.lock.withLock({ worker.stopping }) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            })
        guard let wake = CFRunLoopSourceCreate(nil, 0, &sourceContext) else { publish(false, "Tastaturfilter konnte nicht starten."); return }
        let stopped = lock.withLock { self.loop = loop; wakeSource = wake; return stopping }
        guard !stopped else { clearMailbox(); return }
        CFRunLoopAddSource(loop, wake, .defaultMode)
        defer {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let tapSource { CFRunLoopRemoveSource(loop, tapSource, .commonModes) }
            CFRunLoopRemoveSource(loop, wake, .defaultMode)
            routing.reset(); tap = nil; tapSource = nil; eventSource = nil
            clearMailbox()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardTapWorker>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            publish(false, "Tastaturzugriff fehlt. Prüfe Bedienungshilfen und Eingabeüberwachung.")
            return
        }
        tapSource = source
        guard let sourceState = CGEventSource(stateID: .privateState) else {
            publish(false, "Tastaturfilter konnte keine Ereignisquelle erstellen.")
            return
        }
        eventSource = sourceState
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let running = CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
        publish(running, running ? nil : "Tastaturfilter konnte nicht aktiviert werden. Erneut starten.")
        if !lock.withLock({ stopping }) { CFRunLoopRun() }
    }

    private func clearMailbox() { lock.withLock { loop = nil; wakeSource = nil } }

    private func publish(_ running: Bool, _ issue: String?) {
        sequence &+= 1
        report(.init(sequence: sequence, running: running, issue: issue))
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            routing.cancelCapturedHolds()
            let running = KeyboardTapRecovery.recover(type,
                enable: { if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) } },
                valid: { self.tap.map(CFMachPortIsValid) ?? false },
                enabled: { self.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }) ?? false
            publish(running, running ? nil : "Tastaturfilter pausiert. Erneut starten.")
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardEventEncoding.marker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            lock.withLock { focusCache.invalidate(at: DispatchTime.now().uptimeNanoseconds) }
            onFocusRefresh?()
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard code == WindowsHomeEndRule.home || code == WindowsHomeEndRule.end else {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               (code == 123 || code == 124), event.flags.contains(.maskSecondaryFn) {
                let state = lock.withLock { (focusCache.context, settings, focusCache.diagnostic) }
                onNavigationDiagnostic?(code, event.flags.rawValue, state.0, state.1, false, state.2)
            }
            // Navigation shortcuts can change focus before AX notification.
            if type == .keyDown && (code == 48 || code == 53
                || !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty) {
                lock.withLock { focusCache.invalidate(at: DispatchTime.now().uptimeNanoseconds) }; onFocusRefresh?()
            }
            return Unmanaged.passUnretained(event)
        }
        let state = lock.withLock { (settings, focusCache.context, stopping, focusCache.diagnostic) }
        guard !state.2 else { return Unmanaged.passUnretained(event) }
        let inputContext = state.1
        let input = RuleInput(kind: type == .keyUp ? .up : .down, keyCode: code,
                              modifiers: KeyboardEventEncoding.modifiers(event.flags),
                              isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        let output = routing.receive(input, context: inputContext, rule: .init(settings: state.0))
        if type == .keyDown, !input.isRepeat {
            let replaced: Bool
            if case .replace = output.result { replaced = true } else { replaced = false }
            onNavigationDiagnostic?(code, event.flags.rawValue, inputContext, state.0, replaced, state.3)
        }
        guard case let .replace(replacements) = output.result else { return Unmanaged.passUnretained(event) }
        guard let events = KeyboardEventEncoding.events(for: replacements, source: eventSource) else {
            routing.keepNativeUntilRelease(input, context: inputContext)
            return Unmanaged.passUnretained(event)
        }
        for replacement in events { replacement.postToPid(output.target.processID) }
        return nil
    }
}

@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin

/// AX traffic stays on the main run loop, never in the keyboard tap.
/// Only role/subrole and an integrated-terminal control label are inspected.
@MainActor
final class TextFocusMonitor {
    var onChange: ((FocusSnapshot) -> Void)?
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var activation: NSObjectProtocol?
    private var focused: AXUIElement?
    private var configuration: TerminalAppConfiguration?
    private var supportsFocusNotifications = false
    private var generation: UInt64 = 0
    private var running = false
    private var focusReadDiagnostic = "Noch nicht geprüft"
    private var refreshToken: UInt64 = 0
    private var pendingRefresh: DispatchWorkItem?
    private var retriesRemaining = 0
    private var executableCache: [URL: URL] = [:]

    func start() {
        guard !running else { return }
        running = true
        configuration = TerminalAppConfiguration.load()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontmostApplication() }
        }
        attachToFrontmostApplication()
    }

    func stop() {
        running = false
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        detach()
        publish(.init(), sampledAt: DispatchTime.now().uptimeNanoseconds)
    }

    isolated deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        detach()
    }

    private func detach() {
        refreshToken &+= 1
        pendingRefresh?.cancel(); pendingRefresh = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; application = nil; focused = nil
        supportsFocusNotifications = false
    }

    private func attachToFrontmostApplication() {
        detach()
        generation &+= 1
        publish(.init(), sampledAt: DispatchTime.now().uptimeNanoseconds)
        guard running, let app = resolveFrontmostApplication() else { return }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 0.05)
        application = element
        var created: AXObserver?
        let error = AXObserverCreate(app.pid, { _, _, _, refcon in
            guard let refcon else { return }
            // This source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<TextFocusMonitor>.fromOpaque(refcon).takeUnretainedValue().refresh()
            }
        }, &created)
        if error == .success, let created {
            observer = created
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            supportsFocusNotifications = AXObserverAddNotification(
                created, element, kAXFocusedUIElementChangedNotification as CFString, pointer
            ) == .success
            _ = AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString, pointer)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        refresh()
    }

    func refresh() {
        refreshToken &+= 1
        pendingRefresh?.cancel(); pendingRefresh = nil
        retriesRemaining = 2
        refreshSnapshot()
    }

    private func retryRefresh() {
        guard running, retriesRemaining > 0 else { return }
        retriesRemaining -= 1
        let token = refreshToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.refreshToken == token else { return }
            self.pendingRefresh = nil
            self.refreshSnapshot()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refreshSnapshot() {
        let sampledAt = DispatchTime.now().uptimeNanoseconds
        guard running else { return }
        guard let app = resolveFrontmostApplication() else {
            focusReadDiagnostic = "Keine bestätigte Prozessidentität"
            publish(.init(focus: .transitioning), sampledAt: sampledAt)
            retryRefresh()
            return
        }
        var context = InputContext(bundleID: app.bundleID, processID: app.pid,
                                   secureInput: IsSecureEventInputEnabled(), focusGeneration: generation)
        guard let application else {
            context.focus = .transitioning
            publish(context, sampledAt: sampledAt)
            attachToFrontmostApplication()
            return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success, pid == app.pid else {
            context.focus = .transitioning
            publish(context, sampledAt: sampledAt)
            DispatchQueue.main.async { [weak self] in self?.attachToFrontmostApplication() }
            return
        }
        guard let element = readFocusedElement(application: application, expectedPID: app.pid) else {
            focused = nil; generation &+= 1; context.focusGeneration = generation
            publish(context, sampledAt: sampledAt)
            retryRefresh()
            return
        }
        if focused == nil || !CFEqual(focused, element) { generation &+= 1; focused = element }
        context.focusGeneration = generation
        AXUIElementSetMessagingTimeout(element, 0.05)
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        focusReadDiagnostic = "AX-Rolle \(role ?? "fehlt") · Fokusmeldungen \(supportsFocusNotifications)"
        if subrole == kAXSecureTextFieldSubrole as String { context.focus = .secure }
        else if supportsFocusNotifications, let role {
            context.focus = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                             kAXComboBoxRole as String].contains(role) ? .text : .other
            if role == kAXTextAreaRole as String, let configuration {
                if configuration.terminalBundleIDs.contains(context.bundleID) { context.focus = .terminal }
                else if configuration.integratedTerminalBundleIDs.contains(context.bundleID),
                        configuration.isIntegratedTerminal(bundleID: context.bundleID,
                            description: stringAttribute(element, kAXDescriptionAttribute) ?? "") {
                    context.focus = .terminal
                }
            }
        }
        publish(context, sampledAt: sampledAt)
        if role == nil { retryRefresh() }
    }

    private func readFocusedElement(application: AXUIElement, expectedPID: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let applicationResult = AXUIElementCopyAttributeValue(application,
            kAXFocusedUIElementAttribute as CFString, &value)
        if applicationResult == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success,
               FocusedElementOwnership.accepts(expectedPID: expectedPID, elementPID: owner) { return element }
        }
        // Some apps expose current focus through the public system-wide AX
        // object instead. Never accept a reply owned by another process.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        value = nil
        let systemResult = AXUIElementCopyAttributeValue(system,
            kAXFocusedUIElementAttribute as CFString, &value)
        focusReadDiagnostic = "AX-App \(applicationResult.rawValue) · AX-System \(systemResult.rawValue)"
        guard systemResult == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              FocusedElementOwnership.accepts(expectedPID: expectedPID, elementPID: owner) else { return nil }
        return element
    }

    private func resolveFrontmostApplication() -> (bundleID: String, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        let workspacePID = app.processIdentifier
        if workspacePID > 0 { return (bundleID, workspacePID) }

        // AppKit can describe an active app without a PID. Recover identity
        // using only public AX focus metadata and the process executable path.
        // No window titles, document text or values are read. Never guess a PID
        // from a bundle ID or use the first similarly named process.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString,
                                           &focusedApp) == .success,
              let focusedApp, CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else { return nil }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp as! AXUIElement, &focusedPID) == .success,
              focusedPID > 0 else { return nil }

        var expected = app.executableURL
        if expected == nil, let bundleURL = app.bundleURL {
            expected = executableCache[bundleURL]
            if expected == nil, let executable = Bundle(url: bundleURL)?.executableURL {
                executableCache[bundleURL] = executable
                expected = executable
            }
        }
        guard let expected else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_pidpath(focusedPID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let resolvedPID = FrontmostApplicationIdentity.resolve(workspacePID: workspacePID,
            focusedPID: focusedPID, expectedExecutable: expected.resolvingSymlinksInPath().path,
            actualExecutable: actual) else { return nil }
        return (bundleID, resolvedPID)
    }

    private func publish(_ context: InputContext, sampledAt: UInt64) {
        onChange?(.init(context: context, diagnostic: focusReadDiagnostic, sampleStartedAt: sampledAt))
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

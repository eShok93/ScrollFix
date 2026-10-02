import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct ScrollFixApp: App {
    @StateObject private var model = ScrollFixModel()

    var body: some Scene {
        WindowGroup("ScrollFix", id: "settings") {
            SettingsPanel(model: model)
                .frame(width: 420)
                .frame(minHeight: 620)
                .background(ScrollFixPalette.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 420, height: 620)
        .windowResizability(.contentSize)
        .commands { ScrollFixCommands() }

        MenuBarExtra {
            MenuPanel(model: model)
                .preferredColorScheme(.dark)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.allEnabledFeaturesActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                if !model.canManageLoginItem {
                    Text("Dev").font(.system(size: 10, weight: .bold))
                }
            }
            .accessibilityLabel(model.canManageLoginItem
                ? "ScrollFix \(model.overallAccessibilityState)"
                : "ScrollFix Dev \(model.overallAccessibilityState)")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ScrollFixCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Einstellungen …") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSApp.windows.first(where: { $0.title == "ScrollFix · Status" })?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
final class ScrollFixModel: ObservableObject {
    private static let isQABuild = Bundle.main.bundleIdentifier != "app.scrollfix.mac"
        || Bundle.main.object(forInfoDictionaryKey: "ScrollFixBuildKind") as? String == "qa"

    private static var initialSettings: WindowsInputSettings {
        WindowsInputSettingsStore(defaults: .standard).load(isQA: isQABuild)
    }
    @Published var homeEndSettings = ScrollFixModel.initialSettings.homeEnd {
        didSet { persistInputSettings(); updateKeyboard() }
    }
    @Published private(set) var keyboardRunning = false
    @Published private(set) var keyboardIssue: String?
    @Published private(set) var keyboardDiagnostic = "Noch kein Home/End-Ereignis"
    @Published private(set) var secureKeyboardInput = false
    @Published private(set) var terminalSelectionStatus = TerminalSelectionSetup.live.status
    @Published private(set) var terminalSelectionSetupMessage: String?
    private let keyboard = KeyboardInputController()

    func setupTerminalSelection() {
        do {
            try TerminalSelectionSetup.live.install()
            terminalSelectionStatus = TerminalSelectionSetup.live.status
            terminalSelectionSetupMessage = "Eingerichtet. Öffne ein neues Terminal-Fenster, damit die Auswahl verfügbar ist."
            homeEndSettings.terminalShiftSelection = .zshRegion
        } catch {
            terminalSelectionStatus = TerminalSelectionSetup.live.status
            terminalSelectionSetupMessage = error.localizedDescription
            updateKeyboard()
        }
    }

    private func persistInputSettings() {
        var settings = WindowsInputSettings()
        settings.homeEnd = homeEndSettings
        settings.mouseWheelEnabled = enabled
        settings.autoScrollEnabled = autoScrollEnabled
        settings.wheelFeel = wheelFeel.rawValue
        settings.wheelMinimumStep = wheelMinimumStep
        WindowsInputSettingsStore(defaults: .standard).save(settings)
    }
    private func updateKeyboard() {
        let canPost = homeEndSettings.enabled && !sessionSuspended
            && AutoScrollAccessRequest.check(interceptionAllowed: permissionGranted,
                                             preflight: { ScrollEventAccess.canPost })
        let effectiveSettings = TerminalSelectionSetup.effectiveSettings(homeEndSettings, status: terminalSelectionStatus)
        keyboard.configure(effectiveSettings, active: permissionGranted && canPost && !sessionSuspended)
        if homeEndSettings.enabled && permissionGranted && !sessionSuspended && !canPost {
            keyboardIssue = "macOS-Zugriff für die Tastatursteuerung fehlt. Klicke auf „Tastatur erneut prüfen“."
        }
        keyboard.refreshSecureInput()
    }

    @Published var enabled = ScrollFixModel.initialSettings.mouseWheelEnabled {
        didSet {
            persistInputSettings()
            if enabled { engine.resumeAfterUserInputDisable() }
            updateEngine()
            applyPointerPolicy()
        }
    }
    // The optional device-inventory bypass is a QA tool, not a production setting.
    // Production always uses the normal gesture classification.
    @Published var trackpadOnlyAssistanceEnabled = ScrollFixModel.isQABuild &&
        (UserDefaults.standard.object(forKey: "scrollFix.trackpadOnlyAssistance") as? Bool ?? true) {
        didSet {
            UserDefaults.standard.set(trackpadOnlyAssistanceEnabled, forKey: "scrollFix.trackpadOnlyAssistance")
            updatePointerInventory()
        }
    }
    @Published var autoScrollEnabled = ScrollFixModel.initialSettings.autoScrollEnabled {
        didSet {
            persistInputSettings()
            if autoScrollEnabled { retryAutoScrollPermission() }
            else { updateAutoScroll() }
        }
    }

    @Published var wheelFeel: MouseWheelFeel = {
        MouseWheelFeel(rawValue: ScrollFixModel.initialSettings.wheelFeel) ?? .direct
    }() {
        didSet {
            persistInputSettings()
            updateEngine()
        }
    }
    @Published var wheelMinimumStep = ScrollFixModel.initialSettings.wheelMinimumStep {
        didSet {
            persistInputSettings()
            updateEngine()
        }
    }
    @Published var wheelCanPost = false
    @Published var wheelSamples: [MouseWheelSample] = []
    @Published var wheelPostedFrames: UInt64 = 0
    @Published var wheelMaxTickGapNanoseconds: UInt64 = 0
    @Published var wheelFrameClock: MouseWheelFrameClockKind = .idle
    var wheelNeedsAccess: Bool { statusSnapshot.wheelNeedsAccess }

    var needsFeatureRecovery: Bool { statusSnapshot.needsFeatureRecovery }
    var featureRecoveryTitle: String { statusSnapshot.featureRecoveryTitle }

    func recoverFeatures() {
        guard permissionGranted || engine.isRunning else { openAccessibilitySettings(); return }
        if needsAttention { retryFilter() }
        let keyboardNeedsRecovery = homeEndSettings.enabled && !keyboardRunning
        if wheelNeedsAccess || (autoScrollEnabled && autoScrollIssue != nil) || keyboardNeedsRecovery {
            retryAutoScrollPermission()
        }
        if keyboardNeedsRecovery && !sessionSuspended
            && AutoScrollAccessRequest.check(interceptionAllowed: permissionGranted,
                                             preflight: { ScrollEventAccess.canPost }) {
            keyboard.retry()
        }
        refreshPermission()
    }
    @Published private(set) var permissionGranted = false
    @Published private(set) var naturalScrolling = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    @Published private(set) var engineRunning = false
    @Published private(set) var engineStarting = false
    @Published private(set) var engineIssue: String?
    @Published private(set) var autoScrollRunning = false
    @Published private(set) var autoScrollActive = false
    @Published private(set) var autoScrollIssue: String?
    @Published private(set) var autoScrollTiming = "Noch kein Messwert"
    @Published private(set) var middleClickTarget = "Noch kein Mittelklick"
    @Published private(set) var middleClickTiming = "Noch kein Messwert"
    @Published private(set) var autoScrollOutput = "Noch kein Scrollimpuls"
    @Published private(set) var lastSourceLabel = "Noch kein Scrollereignis"
    @Published private(set) var lastSourceReason = "—"
    @Published private(set) var directionRecords: [ScrollDirectionTrace.Record] = []
    @Published private(set) var tapTimeoutCount: UInt64 = 0
    @Published private(set) var maxCallbackDurationNanoseconds: UInt64 = 0
    @Published private(set) var pointerInventoryState: HIDPointerInventoryState = .unknown
    @Published private(set) var startsAtLogin = !ScrollFixModel.isQABuild && SMAppService.mainApp.status == .enabled
    @Published private(set) var loginItemIssue: String?
    @Published var showStatusDetails = false

    private let engine = ScrollEventEngine(collectDirectionTrace: ScrollFixModel.isQABuild)
    private let pointerInventory = HIDPointerInventoryMonitor()
    private lazy var autoScroll = AutoScrollController(collectDiagnostics: ScrollFixModel.isQABuild)
    private var activationObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusTimer: Timer?
    private var systemSleeping = false
    private var screensSleeping = false
    private var sessionInactive = false
    private var sessionSuspended: Bool { systemSleeping || screensSleeping || sessionInactive }

    // The event tap is the functional truth. AXIsProcessTrusted is useful to explain
    // a failed start, but it can lag or disagree with a tap macOS already accepted.
    var isActive: Bool { enabled && engineRunning }
    var needsAttention: Bool { enabled && !engineRunning && !engineStarting }
    private var statusSnapshot: ScrollFixStatusSnapshot {
        .init(
            directionEnabled: enabled,
            directionRunning: engineRunning,
            directionStarting: engineStarting,
            directionPausedByUserInput: engine.isPausedByUserInput,
            directionIssue: engineIssue,
            permissionGranted: permissionGranted,
            autoScrollEnabled: autoScrollEnabled,
            autoScrollRunning: autoScrollRunning,
            wheelRequiresPosting: wheelFeel.requiresPosting,
            wheelCanPost: wheelCanPost,
            autoScrollCanPost: autoScrollAccessGranted,
            autoScrollHasIssue: autoScrollIssue != nil
        )
    }
    var anyFeatureEnabled: Bool { statusSnapshot.anyFeatureEnabled || homeEndSettings.enabled }
    var allEnabledFeaturesActive: Bool {
        anyFeatureEnabled && (!enabled || engineRunning) && (!autoScrollEnabled || autoScrollRunning)
            && !wheelNeedsAccess && (!homeEndSettings.enabled || keyboardRunning)
    }
    var overallAccessibilityState: String {
        !anyFeatureEnabled ? "nicht aktiv" : (allEnabledFeaturesActive ? "aktiv" : "prüfen")
    }
    var canManageLoginItem: Bool { !Self.isQABuild }
    var showsDiagnostics: Bool { Self.isQABuild }
    var pointerInventoryLabel: String {
        switch pointerInventoryState {
        case .internalTrackpadOnly: "Nur internes Trackpad erkannt"
        case .externalPointerPresent: "Externes Zeigegerät erkannt"
        case .unknown: "Gerätestatus unklar"
        }
    }
    var trackpadProtectionLabel: String {
        guard trackpadOnlyAssistanceEnabled else { return "Trackpad-Schutz aus" }
        guard isActive else { return "Trackpad-Schutz vorbereitet · wartet auf Scrollfilter" }
        if engine.usingTrackpadOnlyFastPath {
            if pointerInventoryState == .internalTrackpadOnly {
                return "Trackpad-Schutz aktiv · nur internes Trackpad erkannt"
            }
            return "Trackpad-Schutz noch aktiv · Gerätewechsel wird nach der Geste übernommen"
        }
        return "Trackpad-Schutz pausiert · \(pointerInventoryLabel.lowercased())"
    }
    var trackpadDirection: String {
        if naturalScrolling { return "Natürlich (macOS)" }
        if !isActive { return "Klassisch (macOS)" }
        return engine.usingTrackpadOnlyFastPath ? "Natürlich (Trackpad-Schutz)" : "Nur erkannte Gesten korrigiert"
    }

    var usingTrackpadOnlyFastPath: Bool { engine.usingTrackpadOnlyFastPath }
    var mouseDirection: String {
        if !naturalScrolling { return "Klassisch (macOS)" }
        if !isActive { return "Natürlich (macOS)" }
        if engine.usingTrackpadOnlyFastPath { return "Keine Radkorrektur (Trackpad-Schutz)" }
        return "Zeilenrad klassisch · Pixelrad unklar"
    }

    var statusHeadline: String { statusSnapshot.directionHeadline }

    var statusDetail: String { statusSnapshot.directionDetail }

    var accessibilityStatus: (detail: String, good: Bool) {
        if engineRunning || autoScrollRunning { return ("Aktiv", true) }
        if permissionGranted { return ("Erlaubt", true) }
        return ("Nicht erteilt", false)
    }

    @Published var autoScrollAccessGranted = false

    init() {
        keyboard.onSecureInput = { [weak self] secure in
            guard let self, self.secureKeyboardInput != secure else { return }
            self.secureKeyboardInput = secure
        }
        keyboard.onNavigationDiagnostic = { [weak self] code, flags, context, settings, replaced, focusReadStatus in
            let fresh = WindowsHomeEndRule(settings: settings).apply(
                .init(kind: .down, keyCode: code, modifiers: KeyboardEventEncoding.modifiers(.init(rawValue: flags))),
                context: context)
            let ruleReplaces: Bool
            if case .replace = fresh { ruleReplaces = true } else { ruleReplaces = false }
            self?.keyboardDiagnostic = "Code \(code) · Flags \(flags) · Fokus \(context.focus) · \(replaced ? "übersetzt" : "unverändert") · App \(context.bundleID.isEmpty ? "fehlt" : context.bundleID) · PID \(context.processID) · Aktiv \(settings.enabled) · Erlaubt \(settings.allowedApps.contains(context.bundleID)) · Ausgeschlossen \(settings.excludedApps.contains(context.bundleID)) · Secure \(context.secureInput) · Neue Regel ersetzt \(ruleReplaces) · \(focusReadStatus)"
        }
        keyboard.onState = { [weak self] running, issue in
            guard let self else { return }
            if self.keyboardRunning != running { self.keyboardRunning = running }
            if self.keyboardIssue != issue { self.keyboardIssue = issue }
        }
        autoScroll.onInteraction = { [weak self] in self?.engine.cancelWheelMotion() }
        engine.onRunningChange = { [weak self] _, issue in
            guard let self else { return }
            // Worker snapshots carry a lifecycle generation. A stale running
            // update cannot revive the UI after stop or a session transition.
            let running = self.enabled && !self.sessionSuspended && self.engine.isRunning
            let currentIssue = self.enabled && !self.sessionSuspended && !running ? issue : nil
            self.setEngineState(running: running, issue: currentIssue)
            self.updateLastSource()
        }
        pointerInventory.onChange = { [weak self] state in
            guard let self else { return }
            self.pointerInventoryState = state
            self.applyPointerPolicy()
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleSessionEvent(name)
                }
            })
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.refreshWheelFrameClock() }
        }
        updatePointerInventory()
        refreshPermission()
        applyDefaultLoginItemIfNeeded()
    }

    isolated deinit {
        statusTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        engine.shutdown()
        pointerInventory.stop()
        keyboard.configure(homeEndSettings, active: false)
    }

    private func handleSessionEvent(_ name: NSNotification.Name) {
        let wasSuspended = sessionSuspended
        switch name {
        case NSWorkspace.didActivateApplicationNotification:
            engine.cancelWheelMotion()
            return
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: return
        }
        if !wasSuspended && sessionSuspended {
            pointerInventory.invalidate()
            engine.stop()
            // A session transition may discard the matching button-up event.
            // Remove the tap and capture state before the session changes.
            autoScroll.rebuild(enabled: false)
            setEngineState(running: false, issue: nil)
            if autoScrollRunning { autoScrollRunning = false }
            if autoScrollActive { autoScrollActive = false }
        } else if wasSuspended && !sessionSuspended {
            if trackpadOnlyAssistanceEnabled { pointerInventory.refresh() }
            if enabled { engine.rebuild() }
            autoScroll.rebuild(enabled: autoScrollEnabled)
        }
        refreshPermission()
    }

    func refreshPermission() {
        let trusted = ScrollEventAccess.accessibilityTrusted
        let systemNatural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        let loginEnabled = canManageLoginItem && SMAppService.mainApp.status == .enabled
        if permissionGranted != trusted { permissionGranted = trusted }
        if naturalScrolling != systemNatural { naturalScrolling = systemNatural }
        if startsAtLogin != loginEnabled { startsAtLogin = loginEnabled }
        updateEngine()
        updateAutoScroll()
        updateKeyboard()
        updateAutoScrollDiagnostics()
        updateLastSource()
        if !sessionSuspended { pointerInventory.retryIfNeeded() }
    }

    func retryFilter() {
        engine.resumeAfterUserInputDisable()
        refreshPermission()
    }

    func retryAutoScrollPermission() {
        refreshPermission()
        autoScroll.resumeAfterUserInputDisable()
        _ = AutoScrollAccessRequest.perform(
            interceptionAllowed: permissionGranted || engine.isRunning,
            preflight: { ScrollEventAccess.canPost },
            request: { ScrollEventAccess.requestPost() },
            openSettings: openAccessibilitySettings
        )
        refreshPermission()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func toggleLoginItem(_ shouldStart: Bool) {
        guard canManageLoginItem else { return }
        do {
            if shouldStart {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let current = SMAppService.mainApp.status == .enabled
            if startsAtLogin != current { startsAtLogin = current }
            if loginItemIssue != nil { loginItemIssue = nil }
        } catch {
            let current = SMAppService.mainApp.status == .enabled
            if startsAtLogin != current { startsAtLogin = current }
            loginItemIssue = "Autostart konnte nicht geändert werden."
        }
    }


    private func applyDefaultLoginItemIfNeeded() {
        guard canManageLoginItem else { return }
        let defaults = UserDefaults.standard
        let key = "scrollFix.loginItemDefaultApplied"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            toggleLoginItem(true)
        }
    }

    func quit() { NSApp.terminate(nil) }

    private func updateEngine() {
        let canPost = enabled && wheelFeel.requiresPosting && !sessionSuspended
            && AutoScrollAccessRequest.check(
                interceptionAllowed: permissionGranted || engine.isRunning,
                preflight: { ScrollEventAccess.canPost }
            )
        if wheelCanPost != canPost { wheelCanPost = canPost }
        engine.configureWheel(.init(feel: wheelFeel, canPost: canPost,
                                    minimumStep: Int64(wheelMinimumStep)))
        guard !sessionSuspended else {
            engine.stop()
            setEngineState(running: false, issue: nil)
            return
        }
        guard enabled else {
            engine.stop()
            setEngineState(running: false, issue: nil)
            return
        }
        // A running tap remains the functional truth when metadata lags.
        if engine.isRunning {
            engine.start(reverseTouchSurface: !naturalScrolling)
            setEngineState(running: true, issue: nil)
            return
        }
        // Creating an active tap also queries Post Event access. Wait for the
        // first grant so CoreGraphics cannot cache an initial denial.
        guard permissionGranted else {
            engine.stop()
            setEngineState(running: false, issue: "macOS-Ereigniszugriff fehlt.")
            return
        }
        engine.start(reverseTouchSurface: !naturalScrolling)
        setEngineState(running: engine.isRunning, issue: engine.isStarting ? nil : engineIssue)
    }

    private func updatePointerInventory() {
        if trackpadOnlyAssistanceEnabled { pointerInventory.start() }
        else { pointerInventory.stop() }
        applyPointerPolicy()
    }

    private func applyPointerPolicy() {
        let eligible = enabled && !sessionSuspended && trackpadOnlyAssistanceEnabled
            && pointerInventoryState == .internalTrackpadOnly
        engine.setTrackpadOnlyEligible(eligible)
    }

    private func updateAutoScroll() {
        guard !sessionSuspended else {
            autoScroll.stop()
            if autoScrollRunning { autoScrollRunning = false }
            if autoScrollActive { autoScrollActive = false }
            return
        }
        guard autoScrollEnabled else {
            autoScroll.stop()
            if autoScrollRunning { autoScrollRunning = false }
            if autoScrollActive { autoScrollActive = false }
            if autoScrollIssue != nil { autoScrollIssue = nil }
            return
        }
        let access = AutoScrollAccessRequest.check(
            interceptionAllowed: permissionGranted || engine.isRunning,
            preflight: { ScrollEventAccess.canPost }
        )
        if autoScrollAccessGranted != access { autoScrollAccessGranted = access }
        guard access else {
            autoScroll.stop()
            if autoScrollRunning { autoScrollRunning = false }
            if autoScrollActive { autoScrollActive = false }
            let issue = "Damit ScrollFix die Seite bewegen kann, braucht es deine macOS-Freigabe."
            if autoScrollIssue != issue { autoScrollIssue = issue }
            return
        }
        autoScroll.start()
        let running = autoScroll.isRunning
        let active = autoScroll.isScrolling
        if autoScrollRunning != running { autoScrollRunning = running }
        if autoScrollActive != active { autoScrollActive = active }
        let issue: String?
        if running {
            issue = nil
        } else if autoScroll.isPausedByUserInput {
            issue = "macOS hat den Mittelklick-Filter deaktiviert. Mit „Freigabe prüfen“ erneut starten."
        } else if permissionGranted {
            issue = "macOS hat den Mittelklick-Filter abgewiesen."
        } else {
            issue = "Bedienungshilfen-Zugriff für den Mittelklick-Filter fehlt."
        }
        if autoScrollIssue != issue { autoScrollIssue = issue }
    }

    private func updateAutoScrollDiagnostics() {
        guard Self.isQABuild else { return }
        let metrics = autoScroll.diagnostics
        if Self.isQABuild {
            let target: String
            switch metrics.lastMiddleClickTarget {
            case .link: target = "Link · nativ"
            case .nativeControl: target = "Bedienelement / Modifier · nativ"
            case .content: target = "Freie Inhalte · Autoscroll"
            case .unknown: target = "Unklar · nativ"
            case nil: target = "Noch kein Mittelklick"
            }
            let lookup: String
            if let last = metrics.lastMiddleClickMilliseconds, let maximum = metrics.maxMiddleClickMilliseconds {
                lookup = String(format: "%.1f / %.1f ms", last, maximum)
            } else {
                lookup = "Noch kein Messwert"
            }
            if middleClickTarget != target { middleClickTarget = target }
            if middleClickTiming != lookup { middleClickTiming = lookup }
        }
        let timing: String
        if let last = metrics.lastTickMilliseconds,
           let maximum = metrics.maxTickMilliseconds {
            timing = "\(Int(last.rounded())) / \(Int(maximum.rounded())) ms · \(metrics.delayedTicks) spät"
        } else {
            timing = "Noch kein Messwert"
        }
        let output: String
        if let delta = metrics.lastPostedDelta {
            let y = delta.vertical >= 0 ? "+\(delta.vertical)" : "\(delta.vertical)"
            let x = delta.horizontal >= 0 ? "+\(delta.horizontal)" : "\(delta.horizontal)"
            output = "Y \(y), X \(x) · \(metrics.postedEvents) gesendet"
        } else {
            output = "Noch kein Scrollimpuls"
        }
        if autoScrollTiming != timing { autoScrollTiming = timing }
        if autoScrollOutput != output { autoScrollOutput = output }
    }

    private func updateLastSource() {
        guard Self.isQABuild else { return }
        let label: String
        let reason: String
        if let decision = engine.lastDecision, engine.isRunning {
            switch decision.source {
            case .trackpad: label = "Vermutlich Trackpad"
            case .mouseWheel: label = "Vermutlich Mausrad"
            case .unknown: label = "Unklar · unverändert"
            }
            switch decision.reason {
            case .onlyInternalTrackpad: reason = "Nur internes Trackpad registriert"
            case .trackpadMayBegin: reason = "Trackpad-Phasenbeginn"
            case .trackpadPhase: reason = "Laufende Scrollphase"
            case .trackpadContinuation: reason = "Pixelimpuls folgt laufender Trackpad-Geste"
            case .wheelTick: reason = "Zeilenimpuls (vermutlich Rad)"
            case .phaseFreePixel: reason = "Pixelereignis ohne Gerätehinweis"
            case .momentum: reason = "Nachlauf derselben Quelle"
            case .missingStart: reason = "Beginn nicht erkannt"
            }
        } else {
            label = "Noch kein Scrollereignis"
            reason = "—"
        }
        if lastSourceLabel != label { lastSourceLabel = label }
        if lastSourceReason != reason { lastSourceReason = reason }
        if wheelSamples != engine.wheelSamples { wheelSamples = engine.wheelSamples }
        if wheelPostedFrames != engine.wheelPostedFrames { wheelPostedFrames = engine.wheelPostedFrames }
        if wheelFrameClock != engine.wheelFrameClock { wheelFrameClock = engine.wheelFrameClock }
        if wheelMaxTickGapNanoseconds != engine.wheelMaxTickGapNanoseconds {
            wheelMaxTickGapNanoseconds = engine.wheelMaxTickGapNanoseconds
        }
    }

    private func setEngineState(running: Bool, issue: String?) {
        if engineRunning != running { engineRunning = running }
        if engineStarting != engine.isStarting { engineStarting = engine.isStarting }
        if engineIssue != issue { engineIssue = issue }
        if !canManageLoginItem {
            let records = engine.recentDirectionRecords
            if directionRecords != records { directionRecords = records }
            let timeouts = engine.tapTimeoutCount
            if tapTimeoutCount != timeouts { tapTimeoutCount = timeouts }
            let maximum = engine.maxCallbackDurationNanoseconds
            if maxCallbackDurationNanoseconds != maximum {
                maxCallbackDurationNanoseconds = maximum
            }
        }
    }
}

private enum ScrollFixPalette {
    static let background = Color(rgb: 0x0C1118)
    static let surface = Color(rgb: 0x141C27)
    static let surfaceRaised = Color(rgb: 0x1C2735)
    static let border = Color(rgb: 0x2B3949)
    static let text = Color(rgb: 0xEEF4FB)
    static let secondary = Color(rgb: 0xA9B7C7)
    static let muted = Color(rgb: 0x91A0B2)
    static let accent = Color(rgb: 0x7EB4FF)
    static let green = Color(rgb: 0x61D6A6)
    static let amber = Color(rgb: 0xF3C56A)
    static let red = Color(rgb: 0xFF817A)
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}

private struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(LinearGradient(colors: [Color(rgb: 0x8CC2FF), Color(rgb: 0x477AD4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(Color(rgb: 0x10213B))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [ScrollFixPalette.surfaceRaised, ScrollFixPalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ScrollFixPalette.border, lineWidth: 1)
                    }
            }
    }
}

private struct DeviceRow: View {
    let symbol: String
    let title: String
    let detail: String
    var toggle: Binding<Bool>? = nil
    var hint = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ScrollFixPalette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScrollFixPalette.text)
                Text(detail).font(.system(size: 12))
                    .foregroundStyle(ScrollFixPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let toggle {
                Toggle(title, isOn: toggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(ScrollFixPalette.accent)
                    .accessibilityLabel(title)
                    .accessibilityHint(hint)
                    .help(hint)
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let good: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(good ? ScrollFixPalette.green : ScrollFixPalette.amber)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ScrollFixPalette.secondary)
            Spacer()
            Text(detail).font(.system(size: 12, weight: .semibold)).foregroundStyle(good ? ScrollFixPalette.green : ScrollFixPalette.amber)
        }
        .frame(minHeight: 36)
    }
}

private struct StatusLinkRow: View {
    let title: String
    let detail: String
    let good: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(good ? ScrollFixPalette.green : ScrollFixPalette.amber)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ScrollFixPalette.text)
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(good ? ScrollFixPalette.green : ScrollFixPalette.amber)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScrollFixPalette.accent)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityHint(hint)
    }
}

private struct SettingRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(ScrollFixPalette.muted)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ScrollFixPalette.secondary)
            Spacer()
            Text(detail).font(.system(size: 12, weight: .semibold)).foregroundStyle(ScrollFixPalette.secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 38)
    }
}

private struct FeaturePanel: View {
    @ObservedObject var model: ScrollFixModel

    private var trackpadDetail: String {
        if model.naturalScrolling { return "Natürlich" }
        if !model.isActive { return "Klassisch" }
        return model.usingTrackpadOnlyFastPath ? "Natürlich" : "Erkennung nötig"
    }

    private var mouseDetail: String {
        if !model.naturalScrolling { return "Klassisch" }
        return model.isActive && !model.usingTrackpadOnlyFastPath
            ? "Wie unter Windows" : "Natürlich"
    }

    private var autoScrollDetail: String {
        if !model.autoScrollEnabled { return "Mittelklick startet" }
        if model.autoScrollActive { return "Scrollt · Klick beendet" }
        if model.autoScrollIssue != nil {
            return model.autoScrollAccessGranted ? "Pausiert" : "Zugriff nötig"
        }
        return model.autoScrollRunning ? "Mittelklick startet" : "Startet …"
    }

    var body: some View {
        VStack(spacing: 4) {
            DeviceRow(symbol: "hand.draw", title: "Trackpad", detail: trackpadDetail)
            Divider().overlay(ScrollFixPalette.border)
            DeviceRow(
                symbol: "computermouse", title: "Mausrad", detail: mouseDetail,
                toggle: $model.enabled, hint: "Mausrad wie unter Windows scrollen lassen"
            )
            Divider().overlay(ScrollFixPalette.border)
            DeviceRow(
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                title: "Mittelklick-Scrollen", detail: autoScrollDetail,
                toggle: $model.autoScrollEnabled,
                hint: "Klicke mit dem Mausrad auf eine freie Fläche. Bewege den Zeiger zum Scrollen. Ein weiterer Klick stoppt. Auf Links öffnet der Mittelklick einen neuen Tab."
            )
            Text("Auf Links: Mittelklick öffnet einen neuen Tab.")
                .font(.system(size: 10)).foregroundStyle(ScrollFixPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 38).padding(.bottom, 4)
            Divider().overlay(ScrollFixPalette.border)
            DeviceRow(symbol: "keyboard", title: "Home / End wie Windows",
                      detail: !model.homeEndSettings.enabled ? "Aus" : (model.keyboardRunning ? "Zeile · Ctrl: Dokument" : "Zugriff prüfen"),
                      toggle: $model.homeEndSettings.enabled,
                      hint: "In Textfeldern: Home und End bewegen den Cursor zum Zeilenanfang oder -ende. Ctrl springt im Dokument. Shift erweitert die Auswahl.")
            if let issue = model.keyboardIssue, model.homeEndSettings.enabled {
                Text(issue).font(.system(size: 11)).foregroundStyle(ScrollFixPalette.amber)
                Button("Tastatur erneut prüfen") { model.recoverFeatures() }
            }
            if model.secureKeyboardInput && model.homeEndSettings.enabled {
                Text("Geschützte Tastatureingabe aktiv: Home / End bleiben vorübergehend unverändert.")
                    .font(.system(size: 11)).foregroundStyle(ScrollFixPalette.secondary)
            }
            if model.needsFeatureRecovery {
                Button(model.featureRecoveryTitle) { model.recoverFeatures() }
                    .buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
    }
}

private struct MenuPanel: View {
    @ObservedObject var model: ScrollFixModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openSettings) {
                HStack(spacing: 10) {
                    BrandMark(size: 30)
                    Text("ScrollFix").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ScrollFixPalette.text)
                    if !model.canManageLoginItem {
                        Text("DEV").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ScrollFixPalette.muted)
                    }
                    Spacer(minLength: 4)
                    StatusPill(enabled: model.anyFeatureEnabled, active: model.allEnabledFeaturesActive)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("ScrollFix-Einstellungen öffnen")

            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
            FeaturePanel(model: model)
            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)

            HStack {
                Button(action: openSettings) {
                    Label("Einstellungen", systemImage: "gearshape")
                }
                .buttonStyle(MenuActionButtonStyle())
                Spacer()
                Button("Beenden") { model.quit() }
                    .buttonStyle(MenuActionButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(ScrollFixPalette.background)
        .onAppear { model.refreshPermission() }
    }

    private func openSettings() {
        model.refreshPermission()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first(where: { $0.title == "ScrollFix" })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct DirectionTraceView: View {
    let records: [ScrollDirectionTrace.Record]
    let visibleCount: Int
    let tapTimeoutCount: UInt64
    let maxCallbackDurationNanoseconds: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("QA · SCROLLFOLGE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Text("\(records.count)/\(ScrollDirectionTrace.capacity)")
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(ScrollFixPalette.muted)
            Text("Tap-Zeitlimit: \(tapTimeoutCount) · Callback max: \(maxCallbackDurationNanoseconds / 1_000) µs")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ScrollFixPalette.muted)

            if records.isEmpty {
                Text("Noch kein Scrollereignis")
                    .font(.system(size: 11))
                    .foregroundStyle(ScrollFixPalette.secondary)
            } else {
                ForEach(Array(records.suffix(visibleCount).enumerated()), id: \.offset) { _, record in
                    Text(line(for: record))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isReset(record) ? ScrollFixPalette.amber : ScrollFixPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(accessibilityLine(for: record))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("P Phase · M Nachlauf · px Pixel")
                    Text("Y Eingang→Ausgang: +/− · 0 Konflikt · ∅ leer")
                }
                .font(.system(size: 9))
                .foregroundStyle(ScrollFixPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(for record: ScrollDirectionTrace.Record) -> String {
        switch record {
        case .reset(.tapTimeout): return "Reset: Tap-Zeitlimit"
        case .reset(.userInput): return "Reset: macOS-Pause"
        case .reset(.classifier): return "Reset: Filterneustart"
        case let .scroll(sample):
            let kind = sample.isContinuous ? "px" : "Zeile"
            let repetitions = sample.repetitions > 1 ? " ×\(sample.repetitions)" : ""
            return "P\(sample.scrollPhase) M\(sample.momentumPhase) · \(kind) · Y\(signName(sample.verticalInputSign))→\(signName(sample.verticalOutputSign)) · \(sourceName(sample.source))\(repetitions) · \(sample.reversed ? "gedreht" : "gleich")"
        }
    }

    private func accessibilityLine(for record: ScrollDirectionTrace.Record) -> String {
        guard case let .scroll(sample) = record else { return line(for: record) }
        return "Phase \(sample.scrollPhase), Nachlauf \(sample.momentumPhase), "
            + (sample.isContinuous ? "Pixelereignis" : "Zeilenereignis")
            + ", vertikaler Eingang " + accessibleSignName(sample.verticalInputSign)
            + ", vertikaler Ausgang " + accessibleSignName(sample.verticalOutputSign)
            + ", " + sourceName(sample.source)
            + (sample.repetitions > 1 ? ", \(sample.repetitions) gleiche Ereignisse" : "")
            + (sample.reversed ? ", Richtung gedreht" : ", Richtung unverändert")
    }

    private func isReset(_ record: ScrollDirectionTrace.Record) -> Bool {
        if case .reset = record { return true }
        return false
    }

    private func sourceName(_ source: ScrollSourceClassifier.Source) -> String {
        switch source {
        case .trackpad: "Trackpad"
        case .mouseWheel: "Mausrad"
        case .unknown: "Unklar"
        }
    }

    private func signName(_ sign: ScrollDirectionTrace.VerticalInputSign) -> String {
        switch sign {
        case .positive: "+"
        case .negative: "-"
        case .zero: "0"
        case .none: "∅"
        }
    }

    private func accessibleSignName(_ sign: ScrollDirectionTrace.VerticalInputSign) -> String {
        switch sign {
        case .positive: "positiv"
        case .negative: "negativ"
        case .zero: "widersprüchliche Vorzeichen"
        case .none: "ohne Impuls"
        }
    }
}

private struct MouseWheelTraceView: View {
    let samples: [MouseWheelSample]
    let postedFrames: UInt64
    let maxTickGap: UInt64
    let clock: MouseWheelFrameClockKind

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RADIMPULSE · \(samples.count)/16").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ScrollFixPalette.muted)
            if samples.isEmpty {
                Text("Noch kein Zeilenrad-Impuls").foregroundStyle(ScrollFixPalette.secondary)
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                let gap = sample.gapMilliseconds.map { String(format: "%.0f ms", $0) } ?? "Start"
                let raw = String(format: "%.3g", sample.rawDelta)
                let cadence = sample.denseInput ? " · dichter Strom" : ""
                let output = sample.plannedDistance.map { "\($0) px · sofort \(sample.immediateDistance ?? 0)" } ?? "macOS"
                Text("\(index + 1). \(sample.feel.title)\(cadence) · L \(sample.lineDelta) · P \(sample.pointDelta) · Raw \(raw) · \(gap) → \(output)")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(ScrollFixPalette.secondary)
            }
            Text("\(postedFrames) Frames · max. Taktabstand \(String(format: "%.1f", Double(maxTickGap) / 1_000_000)) ms")
                .foregroundStyle(ScrollFixPalette.muted)
            Text("Taktgeber: \(clock.label)").foregroundStyle(ScrollFixPalette.muted)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: ScrollFixModel
    @State private var showFineSettings = true

    private var wheelFeelExplanation: String {
        switch model.wheelFeel {
        case .native: "Scrollbewegung wie in macOS."
        case .direct: "Jeder Radschritt bewegt die Seite sofort."
        case .tactile: "Jeder Radschritt klingt kurz aus."
        case .smooth: "Die Seite bewegt sich weich mit etwas Nachlauf."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    BrandMark(size: 34)
                    Text("ScrollFix").font(.system(size: 19, weight: .bold))
                        .foregroundStyle(ScrollFixPalette.text)
                    if !model.canManageLoginItem {
                        Text("DEV").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ScrollFixPalette.muted)
                    }
                    Spacer()
                    StatusPill(enabled: model.anyFeatureEnabled, active: model.allEnabledFeaturesActive)
                }

                SurfaceCard { FeaturePanel(model: model) }

                if model.canManageLoginItem {
                    Toggle(isOn: Binding(
                        get: { model.startsAtLogin },
                        set: { model.toggleLoginItem($0) }
                    )) {
                        Label("Bei Anmeldung starten", systemImage: "power")
                            .foregroundStyle(ScrollFixPalette.secondary)
                    }
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(ScrollFixPalette.accent)
                    if let issue = model.loginItemIssue {
                        Text(issue).font(.system(size: 12)).foregroundStyle(ScrollFixPalette.amber)
                    }
                }

                DisclosureGroup("Feineinstellungen", isExpanded: $showFineSettings) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mausrad-Bewegung")
                            .foregroundStyle(ScrollFixPalette.secondary)
                        Picker("Mausrad-Bewegung", selection: $model.wheelFeel) {
                            ForEach(MouseWheelFeel.selectableCases, id: \.self) { feel in
                                Text(feel.title).tag(feel)
                            }
                        }
                        .pickerStyle(.segmented).controlSize(.small)
                        .labelsHidden().disabled(!model.enabled)
                        Text(wheelFeelExplanation)
                            .foregroundStyle(ScrollFixPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HomeEndOptionsView(settings: $model.homeEndSettings,
                                           terminalStatus: model.terminalSelectionStatus,
                                           setupMessage: model.terminalSelectionSetupMessage,
                                           setupTerminal: model.setupTerminalSelection)
                        if model.wheelFeel != .native {
                            Text("Scrollstrecke pro Radschritt")
                                .foregroundStyle(ScrollFixPalette.text)
                            Slider(value: Binding(
                                get: { Double(model.wheelMinimumStep) },
                                set: { model.wheelMinimumStep = Int($0) }
                            ), in: 16...128, step: 8)
                            .disabled(!model.enabled)
                            .accessibilityLabel("Scrollstrecke pro Radschritt")
                            HStack {
                                Text("Kürzer")
                                Spacer()
                                Text("Weiter")
                            }
                            .foregroundStyle(ScrollFixPalette.secondary)
                            if model.showsDiagnostics {
                                Text("\(model.wheelMinimumStep) px").monospacedDigit()
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.system(size: 12))
                .foregroundStyle(ScrollFixPalette.secondary)
                .tint(ScrollFixPalette.accent)

                Button {
                    model.showStatusDetails.toggle()
                } label: {
                    HStack {
                        Label(model.showsDiagnostics ? "Diagnose" : "Hilfe & Status", systemImage: "waveform.path.ecg")
                        Spacer()
                        Image(systemName: model.showStatusDetails ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ScrollFixPalette.secondary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(model.showsDiagnostics
                    ? "Zeigt Freigaben, Filterstatus und Ereignisspur"
                    : "Zeigt, welche Funktionen bereit sind und ob macOS noch eine Freigabe braucht")

                if model.showStatusDetails {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.showsDiagnostics {
                                SettingRow(title: "macOS-Scrollen", detail: model.naturalScrolling ? "Natürlich an" : "Natürlich aus")
                            }
                            StatusLinkRow(
                                title: "macOS-Zugriff", detail: model.accessibilityStatus.detail,
                                good: model.accessibilityStatus.good,
                                hint: "Öffnet die macOS-Freigabe",
                                action: model.openAccessibilitySettings
                            )
                            StatusRow(
                                title: "Mausrad",
                                detail: model.engineRunning ? "Bereit" : model.enabled ? "Nicht aktiv" : "Aus",
                                good: model.engineRunning || !model.enabled
                            )
                            StatusRow(
                                title: "Mittelklick-Scrollen",
                                detail: model.autoScrollRunning ? "Bereit" : model.autoScrollEnabled ? "Nicht aktiv" : "Aus",
                                good: model.autoScrollRunning || !model.autoScrollEnabled
                            )
                            if model.showsDiagnostics {
                                StatusRow(title: "Scrollbewegungen auslösen",
                                          detail: model.autoScrollAccessGranted || model.wheelCanPost ? "Erlaubt" : "Freigabe fehlt",
                                          good: model.autoScrollAccessGranted || model.wheelCanPost)
                                SettingRow(title: "Home/End-Test", detail: model.keyboardDiagnostic)
                                SettingRow(title: "Trackpad", detail: model.trackpadDirection)
                                SettingRow(title: "Mausrad-Erkennung", detail: model.mouseDirection)
                            }
                            if model.needsAttention {
                                Text(model.statusDetail).font(.system(size: 12))
                                    .foregroundStyle(ScrollFixPalette.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let issue = model.autoScrollIssue {
                                Text(issue).font(.system(size: 12))
                                    .foregroundStyle(ScrollFixPalette.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !model.naturalScrolling {
                                Text("Schalte in macOS „Natürliches Scrollen“ ein, damit dein Trackpad auch bei einer App-Pause wie gewohnt scrollt.")
                                    .font(.system(size: 12)).foregroundStyle(ScrollFixPalette.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.showsDiagnostics {
                                Divider().overlay(ScrollFixPalette.border)
                                Toggle("Testmodus: nur internes Trackpad", isOn: $model.trackpadOnlyAssistanceEnabled)
                                    .font(.system(size: 12)).foregroundStyle(ScrollFixPalette.text)
                                    .toggleStyle(.switch).controlSize(.small).tint(ScrollFixPalette.accent)
                                Text("Umgeht die Geräteerkennung, wenn nur das interne Trackpad angeschlossen ist.")
                                    .foregroundStyle(ScrollFixPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(model.trackpadProtectionLabel).font(.system(size: 12))
                                    .foregroundStyle(ScrollFixPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.showsDiagnostics && model.engineRunning {
                                SettingRow(title: "Letzte Quelle", detail: model.lastSourceLabel)
                                SettingRow(title: "Erkennung", detail: model.lastSourceReason)
                            }
                            if model.showsDiagnostics {
                                MouseWheelTraceView(samples: model.wheelSamples,
                                                    postedFrames: model.wheelPostedFrames,
                                                    maxTickGap: model.wheelMaxTickGapNanoseconds,
                                                    clock: model.wheelFrameClock)
                                DirectionTraceView(
                                    records: model.directionRecords,
                                    visibleCount: ScrollDirectionTrace.capacity,
                                    tapTimeoutCount: model.tapTimeoutCount,
                                    maxCallbackDurationNanoseconds: model.maxCallbackDurationNanoseconds
                                )
                                if model.autoScrollEnabled {
                                    SettingRow(title: "Mittelklick-Ziel", detail: model.middleClickTarget)
                                    SettingRow(title: "Prüfung zuletzt/max", detail: model.middleClickTiming)
                                    SettingRow(title: "Takt zuletzt/max", detail: model.autoScrollTiming)
                                    SettingRow(title: "Scrollimpuls", detail: model.autoScrollOutput)
                                }
                            }
                            Label("ScrollFix arbeitet nur auf deinem Mac.", systemImage: "lock.shield")
                                .font(.system(size: 11)).foregroundStyle(ScrollFixPalette.muted)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(ScrollFixPalette.background)
        .onAppear { model.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
    }
}

private struct SectionEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(ScrollFixPalette.accent)
            .padding(.leading, 2)
    }
}

private struct StatusPill: View {
    let enabled: Bool
    let active: Bool
    private var color: Color { !enabled ? ScrollFixPalette.muted : active ? ScrollFixPalette.green : ScrollFixPalette.amber }
    private var title: String { !enabled ? "AUS" : active ? "AKTIV" : "PRÜFEN" }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(configuration.isPressed ? Color(rgb: 0x2870C8) : Color(rgb: 0x3989ED), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.94 : 1)
    }
}

private struct MenuActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? ScrollFixPalette.text : ScrollFixPalette.accent)
            .frame(minHeight: 34)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
    }
}

import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct ScrollFixApp: App {
    @StateObject private var model = ScrollFixModel()

    var body: some Scene {
        WindowGroup("ScrollFix · Status", id: "settings") {
            SettingsPanel(model: model)
                .frame(width: 468)
                .background(ScrollFixPalette.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 468, height: 520)
        .windowResizability(.contentSize)
        .commands { ScrollFixCommands() }

        MenuBarExtra {
            MenuPanel(model: model)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: model.isActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.isActive ? ScrollFixPalette.accent : Color.secondary)
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
    @Published var enabled = UserDefaults.standard.object(forKey: "scrollFix.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "scrollFix.enabled")
            updateEngine()
        }
    }
    @Published private(set) var permissionGranted = false
    @Published private(set) var postEventGranted = false
    @Published private(set) var naturalScrolling = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    @Published private(set) var engineRunning = false
    @Published private(set) var engineIssue: String?
    @Published private(set) var startsAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginItemIssue: String?
    @Published var showStatusDetails = false

    private let engine = ScrollEventEngine()
    private var activationObserver: NSObjectProtocol?
    private var statusTimer: Timer?

    // The event tap is the functional truth. AXIsProcessTrusted is useful to explain
    // a failed start, but it can lag or disagree with a tap macOS already accepted.
    var isActive: Bool { enabled && engineRunning }
    var needsAttention: Bool { enabled && !engineRunning }
    var trackpadDirection: String { naturalScrolling || isActive ? "Natürlich" : "Klassisch" }
    var mouseDirection: String { !naturalScrolling || isActive ? "Klassisch" : "Natürlich" }

    var statusHeadline: String {
        if !enabled { return "Fix aus" }
        if engineRunning { return "Bereit" }
        if !permissionGranted { return "macOS-Zugriff nötig" }
        return "Filter prüfen"
    }

    var statusDetail: String {
        if !enabled { return "Beide Geräte folgen macOS." }
        if engineRunning { return "Trackpad natürlich · Mausrad klassisch" }
        if !permissionGranted { return "Erlaube ScrollFix in den macOS-Systemeinstellungen." }
        return "Der Scrollfilter konnte nicht starten."
    }

    var accessibilityStatus: (detail: String, good: Bool) {
        if engineRunning { return ("Aktiv", true) }
        if permissionGranted { return ("Erlaubt", true) }
        return ("Nicht erteilt", false)
    }

    init() {
        engine.onRunningChange = { [weak self] running, issue in
            Task { @MainActor in
                self?.setEngineState(running: running, issue: issue)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        refreshPermission()
    }

    func refreshPermission() {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        let canPost = CGPreflightPostEventAccess()
        let systemNatural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if permissionGranted != trusted { permissionGranted = trusted }
        if postEventGranted != canPost { postEventGranted = canPost }
        if naturalScrolling != systemNatural { naturalScrolling = systemNatural }
        if startsAtLogin != loginEnabled { startsAtLogin = loginEnabled }
        updateEngine()
    }

    func requestPostEventAccess() {
        let granted = CGRequestPostEventAccess()
        if postEventGranted != granted { postEventGranted = granted }
        updateEngine()
    }

    func retryFilter() {
        if !postEventGranted { requestPostEventAccess() }
        refreshPermission()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func toggleLoginItem(_ shouldStart: Bool) {
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

    func quit() { NSApp.terminate(nil) }

    private func updateEngine() {
        guard enabled else {
            if engine.isRunning { engine.stop() }
            setEngineState(running: engine.isRunning, issue: nil)
            return
        }
        // A working tap is authoritative even when a permission preflight reports
        // stale metadata. A new tap still requires Accessibility trust; Post Event
        // is reported separately because newer macOS versions split that check.
        if engine.isRunning {
            engine.start(reverseTouchSurface: !naturalScrolling)
            setEngineState(running: true, issue: nil)
            return
        }
        guard permissionGranted else {
            setEngineState(running: false, issue: nil)
            return
        }
        // Let CoreGraphics make the authoritative decision. If AXIsProcessTrusted
        // lags behind a newly granted permission but tap creation succeeds, the UI
        // should report a working filter instead of a stale permission warning.
        engine.start(reverseTouchSurface: !naturalScrolling)
        if engine.isRunning { setEngineState(running: true, issue: nil) }
    }

    private func setEngineState(running: Bool, issue: String?) {
        if engineRunning != running { engineRunning = running }
        if engineIssue != issue { engineIssue = issue }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ScrollFixPalette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ScrollFixPalette.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(ScrollFixPalette.secondary)
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
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
        }
        .frame(minHeight: 38)
    }
}

private struct MenuPanel: View {
    @ObservedObject var model: ScrollFixModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openSettings) {
                HStack(spacing: 10) {
                    BrandMark(size: 34)
                    Text("ScrollFix").font(.system(size: 15, weight: .bold)).foregroundStyle(ScrollFixPalette.text)
                    Spacer(minLength: 4)
                    StatusPill(enabled: model.enabled, active: model.isActive)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("ScrollFix-Einstellungen öffnen")
            .accessibilityHint("Öffnet das Einstellungsfenster")

            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)

            VStack(spacing: 0) {
                DeviceRow(
                    symbol: "hand.draw",
                    title: "Trackpad",
                    detail: model.trackpadDirection
                )
                Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
                DeviceRow(
                    symbol: "computermouse",
                    title: "Mausrad",
                    detail: model.mouseDirection
                )
            }

            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
            Toggle(isOn: $model.enabled) {
                Text("Fix aktiv").frame(maxWidth: .infinity, alignment: .leading)
            }
                .font(.system(size: 12, weight: .semibold))
                .toggleStyle(.switch)
                .tint(ScrollFixPalette.accent)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Trackpad natürlich, Mausrad klassisch")

            if model.needsAttention {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.statusDetail).font(.system(size: 11)).foregroundStyle(ScrollFixPalette.amber).fixedSize(horizontal: false, vertical: true)
                    Button(model.permissionGranted ? "Filter erneut prüfen" : "macOS-Freigabe öffnen") {
                        if model.permissionGranted { model.retryFilter() }
                        else { model.openAccessibilitySettings() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }

            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)

            HStack(spacing: 10) {
                Button {
                    openSettings()
                } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                }
                .buttonStyle(MenuActionButtonStyle())
                .accessibilityHint("Öffnet die ScrollFix-Einstellungen")
                Spacer()
                Button("Beenden") { model.quit() }
                    .buttonStyle(MenuActionButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 306)
        .background(ScrollFixPalette.background)
        .onAppear { model.refreshPermission() }
    }

    private func openSettings() {
        model.refreshPermission()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first(where: { $0.title == "ScrollFix · Status" })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: ScrollFixModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BrandMark(size: 40)
                    Text("ScrollFix").font(.system(size: 20, weight: .bold)).foregroundStyle(ScrollFixPalette.text)
                    Spacer()
                    StatusPill(enabled: model.enabled, active: model.isActive)
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionEyebrow("SCROLLRICHTUNG")
                    SurfaceCard {
                        VStack(spacing: 0) {
                            DeviceRow(
                                symbol: "hand.draw",
                                title: "Trackpad",
                                detail: model.trackpadDirection
                            )
                            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
                            DeviceRow(
                                symbol: "computermouse",
                                title: "Mausrad",
                                detail: model.mouseDirection
                            )
                            Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
                            Toggle(isOn: $model.enabled) {
                                Text("Fix aktiv").frame(maxWidth: .infinity, alignment: .leading)
                            }
                                .font(.system(size: 13, weight: .medium))
                                .toggleStyle(.switch)
                                .tint(ScrollFixPalette.accent)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity)
                                .accessibilityHint("Trackpad natürlich, Mausrad klassisch")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionEyebrow("STATUS")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 9) {
                                Image(systemName: model.isActive ? "checkmark.circle.fill" : model.needsAttention ? "exclamationmark.circle.fill" : "pause.circle.fill")
                                    .foregroundStyle(model.isActive ? ScrollFixPalette.green : model.needsAttention ? ScrollFixPalette.amber : ScrollFixPalette.muted)
                                    .accessibilityHidden(true)
                                Text(model.statusHeadline)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ScrollFixPalette.text)
                                Spacer()
                                Button {
                                    model.showStatusDetails.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(model.showStatusDetails ? "Weniger" : "Details")
                                        Image(systemName: model.showStatusDetails ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ScrollFixPalette.accent)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Zeigt macOS-Scrollrichtung, Freigabe und Scrollfilter")
                            }
                            if model.needsAttention {
                                Text(model.statusDetail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(ScrollFixPalette.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.showStatusDetails || model.needsAttention {
                                Rectangle().fill(ScrollFixPalette.border).frame(height: 1)
                                SettingRow(
                                    title: "macOS-Scrollen",
                                    detail: model.naturalScrolling ? "Natürlich an" : "Natürlich aus"
                                )
                                StatusLinkRow(
                                    title: "macOS-Freigabe",
                                    detail: model.accessibilityStatus.detail,
                                    good: model.accessibilityStatus.good,
                                    hint: "Öffnet Gerätesteuerung und Datenzugriff in den Systemeinstellungen",
                                    action: model.openAccessibilitySettings
                                )
                                if model.needsAttention && model.permissionGranted {
                                    Button {
                                        model.retryFilter()
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ScrollFixPalette.amber)
                                            Text("Scrollfilter").foregroundStyle(ScrollFixPalette.text)
                                            Spacer()
                                            Text("Erneut prüfen").foregroundStyle(ScrollFixPalette.accent)
                                            Image(systemName: "arrow.clockwise").foregroundStyle(ScrollFixPalette.accent)
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(minHeight: 36)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Versucht den Scrollfilter erneut zu starten")
                                } else {
                                    StatusRow(
                                        title: "Scrollfilter",
                                        detail: model.engineRunning ? "Läuft" : model.enabled ? "Wartet auf Zugriff" : "Pausiert",
                                        good: model.engineRunning || !model.enabled
                                    )
                                }
                            }
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Bei Anmeldung starten", isOn: Binding(
                            get: { model.startsAtLogin },
                            set: { model.toggleLoginItem($0) }
                        ))
                        .font(.system(size: 13, weight: .medium))
                        .toggleStyle(.switch)
                        .tint(ScrollFixPalette.accent)
                        if let issue = model.loginItemIssue {
                            Text(issue).font(.system(size: 11)).foregroundStyle(ScrollFixPalette.amber)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(ScrollFixPalette.muted)
                    Text("Scroll-Ereignisse bleiben auf diesem Mac.")
                        .foregroundStyle(ScrollFixPalette.muted)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
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

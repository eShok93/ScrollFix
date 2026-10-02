import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct HomeEndOptionsView: View {
    @Binding var settings: HomeEndSettings
    let terminalStatus: TerminalSelectionSetup.Status
    let setupMessage: String?
    let setupTerminal: () -> Void
    @State private var confirmTerminalSetup = false
    @State private var chosenAppNames: [String: String] = [:]
    @State private var appSelectionIssue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            switch terminalStatus {
                case .needsSetup:
                    Button("Terminal einrichten") { confirmTerminalSetup = true }
                    Text("Home/End und Shift-Auswahl auch im Terminal nutzen.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .installed:
                    if settings.terminalShiftSelection == .zshRegion {
                        Label("Auch im Terminal aktiv", systemImage: "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button("Auch im Terminal aktivieren") { settings.terminalShiftSelection = .zshRegion }
                    }
                    if let setupMessage {
                        Text(setupMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .unavailable(let reason):
                    Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Home/End in einzelnen Apps ausschalten") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.excludedApps.sorted(), id: \.self) { identifier in
                        HStack {
                            Text(appName(for: identifier))
                            Spacer()
                            Button {
                                settings.excludedApps.remove(identifier)
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Ausnahme entfernen: \(appName(for: identifier))")
                            .help("Home/End hier wieder aktivieren")
                        }
                    }
                    Button("App hinzufügen …", action: chooseExcludedApp)
                    if let appSelectionIssue {
                        Text(appSelectionIssue).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Diese Apps behalten ihr gewohntes Home/End-Verhalten.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.disabled(!settings.enabled)
            .alert("Terminal einrichten?", isPresented: $confirmTerminalSetup) {
                Button("Abbrechen", role: .cancel) { }
                Button("Einrichten") { setupTerminal() }
            } message: {
                Text("ScrollFix richtet Home/End und die Auswahl mit Shift für deine lokale zsh-Shell ein. Deine bisherige Terminal-Konfiguration wird gesichert und bleibt erhalten. Danach ein neues Terminal-Fenster öffnen.")
            }
    }
    private func appName(for identifier: String) -> String {
        if let cached = chosenAppNames[identifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return "Nicht mehr installierte App"
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = "App für Home/End-Ausnahme auswählen"
        panel.prompt = "Hinzufügen"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "app",
              let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
            appSelectionIssue = "Diese App konnte nicht hinzugefügt werden. Bitte wähle eine installierte Mac-App."
            return
        }
        chosenAppNames[identifier] = url.deletingPathExtension().lastPathComponent
        settings.excludedApps.insert(identifier)
        appSelectionIssue = nil
    }
}

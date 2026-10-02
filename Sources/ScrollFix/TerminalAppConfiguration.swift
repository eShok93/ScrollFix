import Foundation

struct TerminalAppConfiguration: Codable, Sendable {
    var terminalBundleIDs: Set<String>
    var integratedTerminalBundleIDs: Set<String>
    var integratedTerminalLabels: [String]

    static func load() -> Self? {
        guard let url = Bundle.module.url(forResource: "TerminalApps", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func isIntegratedTerminal(bundleID: String, description: String) -> Bool {
        integratedTerminalBundleIDs.contains(bundleID) && integratedTerminalLabels.contains {
            description == $0 || description.hasPrefix($0 + ",") || description.hasPrefix($0 + ".")
        }
    }
}

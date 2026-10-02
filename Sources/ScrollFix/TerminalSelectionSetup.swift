import Foundation

/// Opt-in setup, called from the settings UI, never from an input callback.
/// Reads only the local startup file to preserve it; no shell execution or logs.
struct TerminalSelectionSetup {
    enum Status: Equatable {
        case needsSetup
        case installed
        case unavailable(String)
    }

    enum SetupError: LocalizedError {
        case unsafeConfiguration
        case missingResource
        case changedConfiguration
        var errorDescription: String? {
            switch self {
            case .unsafeConfiguration: "Deine Shell-Konfiguration benötigt eine individuelle Einrichtung. Sie wurde nicht verändert."
            case .missingResource: "Das Terminal-Modul fehlt in dieser ScrollFix-Version."
            case .changedConfiguration: "Die Konfiguration wurde während der Einrichtung geändert. Bitte erneut versuchen."
            }
        }
    }

    let home: URL
    let resource: URL?
    let customStartupDirectory: String?
    private let files = FileManager.default
    private let begin = "# BEGIN ScrollFix terminal selection"
    private let end = "# END ScrollFix terminal selection"

    static var live: Self {
        Self(home: FileManager.default.homeDirectoryForCurrentUser,
             resource: Bundle.module.url(forResource: "scrollfix-selection", withExtension: "zsh"),
             customStartupDirectory: ProcessInfo.processInfo.environment["ZDOTDIR"])
    }
    private var startup: URL { home.appendingPathComponent(".zshrc") }
    private var directory: URL { home.appendingPathComponent("Library/Application Support/ScrollFix", isDirectory: true) }
    private var module: URL { directory.appendingPathComponent("terminal-selection.zsh") }
    private var block: Data {
        Data("""
        \(begin)
        if [[ -o interactive && -r "$HOME/Library/Application Support/ScrollFix/terminal-selection.zsh" ]]; then
            source "$HOME/Library/Application Support/ScrollFix/terminal-selection.zsh"
        fi
        \(end)

        """.utf8)
    }

    private func validate(_ url: URL, directory: Bool = false) throws {
        // Walk parents too: a symlink must never redirect an opt-in write.
        var candidate = url
        while candidate.path != home.path {
            do {
                let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw SetupError.unsafeConfiguration }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
            candidate.deleteLastPathComponent()
            guard candidate.path.hasPrefix(home.path) else { throw SetupError.unsafeConfiguration }
        }
        if files.fileExists(atPath: url.path) {
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard attributes[.ownerAccountID] as? UInt32 == getuid(),
                  attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
                  directory || ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576
            else { throw SetupError.unsafeConfiguration }
        }
    }

    private func checkedStartup() throws -> Data {
        guard customStartupDirectory == nil || customStartupDirectory == "",
              !files.fileExists(atPath: home.appendingPathComponent(".zshenv").path)
        else { throw SetupError.unsafeConfiguration }
        try validate(startup)
        try validate(directory, directory: true)
        try validate(module)
        let data = files.fileExists(atPath: startup.path) ? try Data(contentsOf: startup) : Data()
        // Unknown/malformed prior blocks are never edited or silently duplicated.
        let text = String(decoding: data, as: UTF8.self)
        if text.contains(begin) || text.contains(end) {
            guard data.range(of: block) != nil,
                  text.components(separatedBy: begin).count == 2,
                  text.components(separatedBy: end).count == 2
            else { throw SetupError.unsafeConfiguration }
        }
        return data
    }

    var status: Status {
        do {
            guard let resource else { throw SetupError.missingResource }
            // Fresh downloads do not need to read the user's startup file
            // merely to show the setup button.
            guard files.fileExists(atPath: module.path) else { return .needsSetup }
            let data = try checkedStartup()
            let expected = try Data(contentsOf: resource)
            let installed = try? Data(contentsOf: module)
            return data.range(of: block) != nil && installed == expected ? .installed : .needsSetup
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func effectiveSettings(_ requested: HomeEndSettings, status: Status) -> HomeEndSettings {
        var effective = requested
        if status != .installed { effective.terminalShiftSelection = .native }
        return effective
    }

    /// Returns a private backup URL when the startup file changed.
    @discardableResult
    func install() throws -> URL? {
        let original = try checkedStartup()
        let existed = files.fileExists(atPath: startup.path)
        guard let resource else { throw SetupError.missingResource }
        let payload = try Data(contentsOf: resource)
        var updated = original
        if original.range(of: block) == nil {
            if !updated.isEmpty && updated.last != 10 { updated.append(10) }
            updated.append(block)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if updated != original {
            let backupURL = directory.appendingPathComponent("zshrc-backup-\(UUID().uuidString)")
            guard files.createFile(atPath: backupURL.path, contents: original,
                                   attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            backup = backupURL
        }
        // Refuse common concurrent edits and recheck symlinks before mutation.
        guard try checkedStartup() == original,
              files.fileExists(atPath: startup.path) == existed else { throw SetupError.changedConfiguration }
        try payload.write(to: module, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: module.path)
        if updated != original {
            let mode = existed ? (try files.attributesOfItem(atPath: startup.path)[.posixPermissions]) : nil
            try updated.write(to: startup, options: .atomic)
            try files.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: startup.path)
        }
        return backup
    }
}

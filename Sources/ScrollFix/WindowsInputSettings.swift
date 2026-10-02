import Foundation

/// Versioned settings payload. The original scroll preferences migrate once;
/// local QA diagnostics are deliberately not part of this public configuration.
struct WindowsInputSettings: Codable, Equatable, Sendable {
    var version = 1
    var homeEnd: HomeEndSettings = {
        var settings = HomeEndSettings()
        // Offer setup on first launch. Effective Shift interception remains
        // native until the user confirms installation of the shell module.
        settings.terminalShiftSelection = .zshRegion
        return settings
    }()
    var mouseWheelEnabled = true
    var autoScrollEnabled = true
    var wheelFeel = "direct"
    var wheelMinimumStep = 48
}

struct WindowsInputSettingsStore {
    static let key = "scrollFix.settings.v1"
    let defaults: UserDefaults

    func load(isQA: Bool = false) -> WindowsInputSettings {
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(WindowsInputSettings.self, from: data),
           decoded.version == 1 {
            return sanitized(decoded)
        }
        var settings = WindowsInputSettings()
        settings.mouseWheelEnabled = defaults.object(forKey: "scrollFix.enabled") as? Bool ?? true
        settings.autoScrollEnabled = defaults.object(forKey: "scrollFix.autoScrollEnabled") as? Bool ?? !isQA
        settings.wheelFeel = defaults.string(forKey: "scrollFix.wheelFeel") ?? (isQA ? "smooth" : "direct")
        settings.wheelMinimumStep = defaults.object(forKey: "scrollFix.wheelMinimumStep") as? Int ?? 48
        return sanitized(settings)
    }

    func save(_ settings: WindowsInputSettings) {
        guard let data = try? JSONEncoder().encode(sanitized(settings)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func sanitized(_ original: WindowsInputSettings) -> WindowsInputSettings {
        var settings = original
        settings.wheelMinimumStep = min(128, max(16, settings.wheelMinimumStep))
        if settings.wheelFeel == "tactile" { settings.wheelFeel = "direct" }
        if !["native", "direct", "smooth"].contains(settings.wheelFeel) { settings.wheelFeel = "direct" }
        return settings
    }
}

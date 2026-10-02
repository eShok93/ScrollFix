import Foundation

enum TerminalHomeEndStrategy: String, Codable, CaseIterable, Sendable {
    case controlAE
    case escapeSequence

    var title: String {
        switch self {
        case .controlAE: "Ctrl+A / Ctrl+E"
        case .escapeSequence: "Escape-Sequenz (tmux / screen)"
        }
    }
}

enum TerminalShiftSelection: String, Codable, CaseIterable, Sendable {
    case native
    case zshRegion

    var title: String {
        switch self {
        case .native: "Unverändert"
        case .zshRegion: "Eingabe markieren (zsh)"
        }
    }
}

struct HomeEndSettings: Codable, Equatable, Sendable {
    var enabled = true
    var terminalStrategy: TerminalHomeEndStrategy = .controlAE
    var terminalShiftSelection: TerminalShiftSelection = .native
    /// Explicit opt-in for applications that cannot report focused text via AX.
    var allowedApps: Set<String> = []
    var excludedApps: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, terminalStrategy, terminalShiftSelection, allowedApps, excludedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        terminalStrategy = try container.decodeIfPresent(TerminalHomeEndStrategy.self, forKey: .terminalStrategy) ?? .controlAE
        terminalShiftSelection = try container.decodeIfPresent(TerminalShiftSelection.self, forKey: .terminalShiftSelection) ?? .native
        allowedApps = try container.decodeIfPresent(Set<String>.self, forKey: .allowedApps) ?? []
        excludedApps = try container.decodeIfPresent(Set<String>.self, forKey: .excludedApps) ?? []
    }
}

struct WindowsHomeEndRule: InputRule {
    static let home: UInt16 = 115
    static let end: UInt16 = 119
    var settings: HomeEndSettings

    func apply(_ input: RuleInput, context: InputContext) -> RuleResult {
        guard settings.enabled, !input.synthetic, !input.isRepeat, input.kind == .down,
              input.keyCode == Self.home || input.keyCode == Self.end,
              !context.bundleID.isEmpty, context.processID > 0,
              !context.secureInput, context.focus != .secure,
              !settings.excludedApps.contains(context.bundleID),
              input.modifiers.intersection([.command, .option]).isEmpty else {
            return .passThrough
        }
        let home = input.keyCode == Self.home
        let shift = input.modifiers.contains(.shift)
        if context.focus == .terminal {
            // Selection is handled by an explicitly installed local zsh widget,
            // not by pretending Ctrl+Shift+A/E is a text-selection command.
            if shift {
                guard settings.terminalShiftSelection == .zshRegion,
                      !input.modifiers.contains(.control) else { return .passThrough }
                return .replace([.terminalSequence(home ? "\u{1b}[1;2H" : "\u{1b}[1;2F")])
            }
            switch settings.terminalStrategy {
            case .controlAE:
                return .replace([.stroke(keyCode: home ? 0 : 14, modifiers: .control)])
            case .escapeSequence:
                return .replace([.terminalSequence(home ? "\u{1b}OH" : "\u{1b}OF")])
            }
        }
        // An allow entry may override missing AX support, never a known
        // non-text target. This prevents accidental Browser Back / Finder Up.
        let allowedUnknown = context.focus == .unknown && settings.allowedApps.contains(context.bundleID)
        guard context.focus == .text || allowedUnknown else { return .passThrough }
        let document = input.modifiers.contains(.control)
        let key: UInt16 = document ? (home ? 126 : 125) : (home ? 123 : 124)
        var modifiers: KeyModifiers = .command
        if shift { modifiers.insert(.shift) }
        return .replace([.stroke(keyCode: key, modifiers: modifiers)])
    }
}

/// Hold the native/captured decision until the original physical key-up.
/// Repeats never switch strategy after a focus or settings change.
struct HomeEndRouting {
    private struct Pair {
        var result: RuleResult
        var target: InputContext
        var cancelled = false
    }
    private var home: Pair?
    private var end: Pair?

    struct Output: Equatable {
        var result: RuleResult
        var target: InputContext
    }

    mutating func receive(_ input: RuleInput, context: InputContext,
                          rule: WindowsHomeEndRule) -> Output {
        guard !input.synthetic,
              input.keyCode == WindowsHomeEndRule.home || input.keyCode == WindowsHomeEndRule.end else {
            return .init(result: .passThrough, target: context)
        }
        let isHome = input.keyCode == WindowsHomeEndRule.home
        let current = isHome ? home : end
        if input.kind == .up {
            if isHome { home = nil } else { end = nil }
            if let current, case .replace = current.result {
                return .init(result: .replace([]), target: current.target)
            }
            return .init(result: .passThrough, target: context)
        }
        if var current {
            // A held key must not continue editing an old app after activation.
            if case .replace = current.result {
                if current.target != context || !rule.settings.enabled
                    || rule.settings.excludedApps.contains(context.bundleID) {
                    current.cancelled = true
                    if isHome { home = current } else { end = current }
                }
                if current.cancelled { return .init(result: .replace([]), target: current.target) }
            }
            return .init(result: current.result, target: current.target)
        }
        let pair = Pair(result: rule.apply(input, context: context), target: context)
        if isHome { home = pair } else { end = pair }
        return .init(result: pair.result, target: pair.target)
    }

    mutating func reset() { home = nil; end = nil }

    mutating func cancelCapturedHolds() {
        if case .replace = home?.result { home?.cancelled = true }
        if case .replace = end?.result { end?.cancelled = true }
    }

    mutating func keepNativeUntilRelease(_ input: RuleInput, context: InputContext) {
        let pair = Pair(result: .passThrough, target: context)
        if input.keyCode == WindowsHomeEndRule.home { home = pair }
        else if input.keyCode == WindowsHomeEndRule.end { end = pair }
    }
}

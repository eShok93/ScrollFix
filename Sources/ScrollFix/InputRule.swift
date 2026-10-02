import Foundation

/// Value-only input to rules. No Accessibility calls or event posting here.
struct RuleInput: Equatable, Sendable {
    enum Kind: Sendable { case down, up }
    var kind: Kind
    var keyCode: UInt16
    var modifiers: KeyModifiers = []
    var synthetic = false
    var isRepeat = false
}

struct KeyModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8
    static let control = Self(rawValue: 1 << 0)
    static let command = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let option = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)
    static let capsLock = Self(rawValue: 1 << 5)
}

struct InputContext: Equatable, Sendable {
    enum Focus: Sendable { case unknown, transitioning, other, text, terminal, secure }
    var bundleID: String = ""
    var processID: Int32 = 0
    var focus: Focus = .unknown
    var secureInput = false
    var focusGeneration: UInt64 = 0
}

/// Each replacement is a complete down/up pair, not a held modifier.
enum KeyReplacement: Equatable, Sendable {
    case stroke(keyCode: UInt16, modifiers: KeyModifiers)
    case terminalSequence(String)
}

enum RuleResult: Equatable, Sendable {
    case passThrough
    case replace([KeyReplacement])
}

protocol InputRule {
    func apply(_ input: RuleInput, context: InputContext) -> RuleResult
}

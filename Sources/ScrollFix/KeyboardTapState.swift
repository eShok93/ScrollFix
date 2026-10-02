struct KeyboardTapState: Sendable {
    var sequence: UInt64
    var running: Bool
    var issue: String?
}

/// MainActor tasks may arrive out of order. The controller separately rejects
/// old worker generations; this inbox rejects old snapshots within a generation.
struct KeyboardStateInbox {
    private var acceptedSequence: UInt64 = 0

    mutating func accept(_ state: KeyboardTapState) -> Bool {
        guard state.sequence > acceptedSequence else { return false }
        acceptedSequence = state.sequence
        return true
    }
}

import Foundation

struct FocusSnapshot: Sendable {
    var context: InputContext
    /// Timestamp before starting AX queries, not after they return.
    var diagnostic: String = "—"
    var sampleStartedAt: UInt64
}

/// A delayed AX reply must not restore an old text focus after a mouse/Tab
/// boundary. Unknown because AX is unsupported and a focus transition are
/// separate states: explicit app allow entries apply only to the former.
struct FocusContextCache {
    private(set) var context = InputContext()
    private(set) var diagnostic = "Noch keine Fokusprüfung"
    private var invalidatedAt: UInt64 = 0
    private var lastSampleAt: UInt64 = 0

    mutating func invalidate(at now: UInt64) {
        invalidatedAt = max(invalidatedAt, now)
        context.focus = .transitioning
    }

    @discardableResult
    mutating func update(_ snapshot: FocusSnapshot) -> Bool {
        guard snapshot.sampleStartedAt > invalidatedAt,
              snapshot.sampleStartedAt >= lastSampleAt else { return false }
        context = snapshot.context
        diagnostic = snapshot.diagnostic
        lastSampleAt = snapshot.sampleStartedAt
        return true
    }

    mutating func setSecureInput(_ secure: Bool) { context.secureInput = secure }
}

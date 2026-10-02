import CoreGraphics

/// Keeps an inventory policy fixed across a direct gesture and its possible
/// momentum. New inventory is adopted at an idle boundary or an explicit reset.
struct TrackpadOnlyFastPath {
    private(set) var selected = false
    private(set) var requested = false
    private var directActive = false
    private var momentumActive = false
    private var pendingMomentumUntil: UInt64?
    private var phaseFreeQuietUntil: UInt64?
    private static let momentumGraceNanoseconds: UInt64 = 1_000_000_000

    @discardableResult
    mutating func request(_ enable: Bool, at now: UInt64) -> Bool {
        requested = enable
        return adoptIfIdle(at: now)
    }

    /// Returns true if a new policy was adopted before this event is rewritten.
    @discardableResult
    mutating func beforeEvent(scrollPhase: Int64, momentumPhase: Int64, at now: UInt64) -> Bool {
        let mayBegin = Int64(CGScrollPhase.mayBegin.rawValue)
        let began = Int64(CGScrollPhase.began.rawValue)
        // A new direct start is a safe boundary even if an older stream lost
        // its terminal phase. Do not mistake mayBegin -> began for two starts.
        if scrollPhase & mayBegin != 0 || (scrollPhase & began != 0 && !directActive) {
            directActive = false
            momentumActive = false
            pendingMomentumUntil = nil
            phaseFreeQuietUntil = nil
        }
        return adoptIfIdle(at: now)
    }

    /// Returns true if the next event should use a newly adopted policy.
    @discardableResult
    mutating func afterEvent(scrollPhase: Int64, momentumPhase: Int64, at now: UInt64) -> Bool {
        let ended = Int64(CGScrollPhase.ended.rawValue)
        let cancelled = Int64(CGScrollPhase.cancelled.rawValue)
        let momentumEnd = Int64(CGMomentumScrollPhase.end.rawValue)

        if momentumPhase != 0 {
            directActive = false
            pendingMomentumUntil = nil
            phaseFreeQuietUntil = nil
            momentumActive = momentumPhase != momentumEnd
        } else if scrollPhase & cancelled != 0 {
            directActive = false
            momentumActive = false
            pendingMomentumUntil = nil
            phaseFreeQuietUntil = nil
        } else if scrollPhase & ended != 0 {
            directActive = false
            phaseFreeQuietUntil = nil
            pendingMomentumUntil = now.addingReportingOverflow(Self.momentumGraceNanoseconds).overflow
                ? UInt64.max : now + Self.momentumGraceNanoseconds
        } else if scrollPhase != 0 {
            directActive = true
            phaseFreeQuietUntil = nil
        } else {
            // There is no documented stream boundary for phase-free input.
            // Preserve direction across a short burst instead of switching
            // between two closely spaced impulses after a device notification.
            phaseFreeQuietUntil = now.addingReportingOverflow(Self.momentumGraceNanoseconds).overflow
                ? UInt64.max : now + Self.momentumGraceNanoseconds
        }
        return adoptIfIdle(at: now)
    }

    @discardableResult
    mutating func reset() -> Bool {
        directActive = false
        momentumActive = false
        pendingMomentumUntil = nil
        phaseFreeQuietUntil = nil
        let changed = selected != requested
        selected = requested
        return changed
    }

    private mutating func adoptIfIdle(at now: UInt64) -> Bool {
        if let deadline = pendingMomentumUntil, now >= deadline {
            pendingMomentumUntil = nil
        }
        if let deadline = phaseFreeQuietUntil, now >= deadline {
            phaseFreeQuietUntil = nil
        }
        guard !directActive, !momentumActive, pendingMomentumUntil == nil,
              phaseFreeQuietUntil == nil,
              selected != requested else { return false }
        selected = requested
        return true
    }
}

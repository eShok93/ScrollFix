import CoreGraphics

/// Classifies a scroll stream from documented Quartz phase fields. These fields
/// do not contain a hardware device ID, so an ambiguous stream stays unknown.
struct ScrollSourceClassifier {
    enum Source: Equatable, Sendable {
        case trackpad
        case mouseWheel
        case unknown
    }

    enum Reason: Equatable, Sendable {
        case onlyInternalTrackpad
        case trackpadMayBegin
        case trackpadPhase
        case trackpadContinuation
        case wheelTick
        case phaseFreePixel
        case momentum
        case missingStart
    }

    struct Decision: Equatable, Sendable {
        let source: Source
        let reason: Reason
    }

    private var directSource: Source?
    private var pendingMomentumSource: Source?
    private var pendingMomentumAt: UInt64?
    private var momentumSource: Source?
    private var awaitingBegin = false
    private static let maxMomentumGap: UInt64 = 1_000_000_000

    mutating func reset() {
        directSource = nil
        pendingMomentumSource = nil
        pendingMomentumAt = nil
        momentumSource = nil
        awaitingBegin = false
    }

    mutating func classify(
        scrollPhase: Int64, momentumPhase: Int64, at timestamp: UInt64,
        isContinuous: Bool = false
    ) -> Decision {
        let mayBegin = Int64(CGScrollPhase.mayBegin.rawValue)
        let began = Int64(CGScrollPhase.began.rawValue)
        let ended = Int64(CGScrollPhase.ended.rawValue)
        let cancelled = Int64(CGScrollPhase.cancelled.rawValue)
        let momentumBegin = Int64(CGMomentumScrollPhase.begin.rawValue)
        let momentumEnd = Int64(CGMomentumScrollPhase.end.rawValue)

        // Momentum belongs to the preceding phased stream. A new phase-free
        // wheel tick can occur in between without stealing that stream. Once
        // begun, momentum keeps its owner until end or a new begin, even if
        // a long pause occurs between events.
        if momentumPhase != 0 {
            if momentumPhase == momentumBegin || momentumSource == nil {
                let pendingIsFresh = pendingMomentumAt.map { timestamp >= $0 && timestamp - $0 <= Self.maxMomentumGap } ?? false
                momentumSource = pendingIsFresh ? pendingMomentumSource : .unknown
                // The completed direct gesture can seed only one momentum
                // stream. A later begin requires its own direct predecessor.
                pendingMomentumSource = nil
                pendingMomentumAt = nil
            }
            let source = momentumSource ?? .unknown
            if momentumPhase == momentumEnd {
                momentumSource = nil
                pendingMomentumSource = nil
                pendingMomentumAt = nil
            }
            return Decision(source: source, reason: source == .unknown ? .missingStart : .momentum)
        }

        if scrollPhase & mayBegin != 0 {
            directSource = .trackpad
            awaitingBegin = true
            pendingMomentumSource = nil
            pendingMomentumAt = nil
            return Decision(source: .trackpad, reason: .trackpadMayBegin)
        }

        if scrollPhase & began != 0 {
            // Apple documents mayBegin -> began/cancelled/ended for a
            // trackpad, but no maximum delay while fingers are resting.
            // Trust the pending phase until its explicit end or a tap reset.
            directSource = awaitingBegin ? .trackpad : .unknown
            awaitingBegin = false
            pendingMomentumSource = nil
            pendingMomentumAt = nil
        }

        if scrollPhase != 0 {
            if awaitingBegin {
                // Some streams omit began. The pending trackpad phase still
                // owns the first changed/end/cancelled event.
                directSource = .trackpad
                awaitingBegin = false
            }
            // An explicit phased gesture keeps its owner until ended or
            // cancelled. A user may pause with fingers resting on the
            // trackpad for more than a second before scrolling again.
            let source = directSource ?? .unknown
            if scrollPhase & ended != 0 {
                pendingMomentumSource = source
                pendingMomentumAt = timestamp
                directSource = nil
                awaitingBegin = false
            } else if scrollPhase & cancelled != 0 {
                directSource = nil
                pendingMomentumSource = nil
                pendingMomentumAt = nil
                awaitingBegin = false
            }
            let reason: Reason = switch source {
            case .trackpad: .trackpadPhase
            case .mouseWheel: .wheelTick
            case .unknown: .missingStart
            }
            return Decision(source: source, reason: reason)
        }

        // Pixel deltas can come from either a trackpad or a high-resolution
        // wheel. Keep a continuous event with an active or pending-start
        // trackpad stream attached to that stream; otherwise its source is
        // ambiguous and it must pass through unchanged.
        if isContinuous {
            if awaitingBegin || directSource == .trackpad {
                return Decision(source: .trackpad, reason: .trackpadContinuation)
            }
            return Decision(source: .unknown, reason: .phaseFreePixel)
        }
        // Phase-free line ticks are likely wheel input, but without a
        // per-event device ID this remains a heuristic rather than proof.
        return Decision(source: .mouseWheel, reason: .wheelTick)
    }
}

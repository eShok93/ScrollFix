import CoreGraphics
import Foundation

/// Mutable scroll-stream state. Its owner must call every method from one thread.
/// The live owner is ScrollEventTapWorker; offline tests use the same logic.
struct ScrollWheelRewriter {
    var reverseTouchSurface: Bool
    private(set) var lastDecision: ScrollSourceClassifier.Decision?
    private(set) var trackpadOnlyFastPath = TrackpadOnlyFastPath()
    private var classifier = ScrollSourceClassifier()
    private var directionTrace = ScrollDirectionTrace()
    private let collectDirectionTrace: Bool

    init(reverseTouchSurface: Bool, collectDirectionTrace: Bool) {
        self.reverseTouchSurface = reverseTouchSurface
        self.collectDirectionTrace = collectDirectionTrace
    }

    var recentDirectionRecords: [ScrollDirectionTrace.Record] {
        collectDirectionTrace ? directionTrace.recent : []
    }

    mutating func clearDirectionTrace() {
        directionTrace = ScrollDirectionTrace()
    }

    mutating func setTrackpadOnlyEligible(
        _ eligible: Bool, at monotonicTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        if trackpadOnlyFastPath.request(eligible, at: monotonicTime) {
            classifier.reset()
            lastDecision = nil
        }
    }

    mutating func resetClassification(reason: ScrollDirectionTrace.ResetReason = .classifier) {
        if collectDirectionTrace && (reason != .classifier || lastDecision != nil) {
            directionTrace.recordReset(reason)
        }
        classifier.reset()
        trackpadOnlyFastPath.reset()
        lastDecision = nil
    }

    mutating func rewriteWheelEvent(
        _ event: CGEvent, at monotonicTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> CGEvent {
        if ScrollFixSyntheticEvent.isGenerated(event) {
            return event
        }
        let gesturePhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if trackpadOnlyFastPath.beforeEvent(scrollPhase: gesturePhase, momentumPhase: momentumPhase, at: monotonicTime) {
            classifier.reset()
        }
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let inferred = classifier.classify(
            scrollPhase: gesturePhase, momentumPhase: momentumPhase,
            at: event.timestamp, isContinuous: isContinuous
        )
        let decision = trackpadOnlyFastPath.selected
            ? ScrollSourceClassifier.Decision(source: .trackpad, reason: .onlyInternalTrackpad)
            : inferred
        lastDecision = decision
        let shouldTrace = collectDirectionTrace
        let verticalInputSign: ScrollDirectionTrace.VerticalInputSign = shouldTrace
            ? .read(from: event) : .none
        var didReverse = false
        defer {
            if trackpadOnlyFastPath.afterEvent(scrollPhase: gesturePhase, momentumPhase: momentumPhase, at: monotonicTime) {
                classifier.reset()
            }
            if shouldTrace {
                directionTrace.record(.init(
                    scrollPhase: gesturePhase,
                    momentumPhase: momentumPhase,
                    isContinuous: isContinuous,
                    verticalInputSign: verticalInputSign,
                    verticalOutputSign: .read(from: event),
                    source: decision.source,
                    reversed: didReverse
                ))
            }
        }
        guard decision.source != .unknown else { return event }
        let isTouchSurface = decision.source == .trackpad
        guard isTouchSurface == reverseTouchSurface else { return event }

        let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let pointDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixedDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let acceleratedDelta = event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1)
        let rawDelta = event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)
        // Other software can emit malformed values. Int64.min cannot be negated.
        guard lineDelta != .min, pointDelta != .min, pointDelta != Int64(Int32.min),
              acceleratedDelta.isFinite, rawDelta.isFinite, fixedDelta.isFinite else { return event }
        guard lineDelta != 0 || pointDelta != 0 || fixedDelta != 0 || acceleratedDelta != 0 || rawDelta != 0 else {
            return event
        }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineDelta)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedDelta)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: -acceleratedDelta)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: -rawDelta)
        didReverse = true
        return event
    }
}

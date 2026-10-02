import CoreGraphics
import XCTest
@testable import ScrollFix

final class ScrollSourceClassifierTests: XCTestCase {
    private let mayBegin = Int64(CGScrollPhase.mayBegin.rawValue)
    private let began = Int64(CGScrollPhase.began.rawValue)
    private let changed = Int64(CGScrollPhase.changed.rawValue)
    private let ended = Int64(CGScrollPhase.ended.rawValue)
    private let momentumBegin = Int64(CGMomentumScrollPhase.begin.rawValue)
    private let momentumContinue: Int64 = 2 // kCGMomentumScrollPhaseContinue

    func testTrackpadStreamKeepsItsMomentum() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: ended, momentumPhase: 0).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin).source, .trackpad)
    }

    func testLineWheelDoesNotInheritTrackpadMomentum() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0)
        _ = classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin)

        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: 0).source, .mouseWheel)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue).source, .trackpad)
    }

    func testPixelWheelDuringTrackpadMomentumRemainsAmbiguousWithoutStealingOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1, isContinuous: true)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2, isContinuous: true)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3, isContinuous: true)
        _ = classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 4, isContinuous: true)

        let pixel = classifier.classify(scrollPhase: 0, momentumPhase: 0, at: 5, isContinuous: true)
        XCTAssertEqual(pixel.source, .unknown)
        XCTAssertEqual(pixel.reason, .phaseFreePixel)
        XCTAssertEqual(
            classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 6, isContinuous: true).source,
            .trackpad
        )
    }

    func testPixelGestureWithoutMayBeginKeepsMissingStartThroughMomentum() {
        var classifier = ScrollSourceClassifier()
        for (offset, phase) in [began, changed, ended].enumerated() {
            let decision = classifier.classify(
                scrollPhase: phase, momentumPhase: 0, at: UInt64(offset + 1), isContinuous: true
            )
            XCTAssertEqual(decision.source, .unknown)
            XCTAssertEqual(decision.reason, .missingStart)
        }
        for (offset, phase) in [momentumBegin, momentumContinue, Int64(CGMomentumScrollPhase.end.rawValue)].enumerated() {
            XCTAssertEqual(
                classifier.classify(scrollPhase: 0, momentumPhase: phase, at: UInt64(offset + 4), isContinuous: true).source,
                .unknown
            )
        }
    }

    func testPhaseFreeContinuousInputKeepsActiveTrackpadOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)

        let decision = classifier.classify(
            scrollPhase: 0, momentumPhase: 0, at: 3, isContinuous: true
        )

        XCTAssertEqual(decision.source, .trackpad)
        XCTAssertEqual(decision.reason, .trackpadContinuation)
    }

    func testPhaseFreeContinuousInputIsAmbiguous() {
        var classifier = ScrollSourceClassifier()

        let decision = classifier.classify(
            scrollPhase: 0, momentumPhase: 0, at: 1, isContinuous: true
        )

        XCTAssertEqual(decision.source, .unknown)
        XCTAssertEqual(decision.reason, .phaseFreePixel)
    }

    func testWheelThenTrackpadStartsNewStream() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: 0).source, .mouseWheel)
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0).source, .trackpad)
    }

    func testWheelTickBetweenTrackpadMayBeginAndBeganKeepsTrackpadOwner() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: 0, at: 2).source, .mouseWheel)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 3).source, .trackpad)
    }

    func testInterleavedWheelDoesNotStealPendingTrackpadBeginAfterLongRest() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: 0, momentumPhase: 0, at: 1_500_000_000)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 3_000_000_000).source, .trackpad)
    }

    func testMissingChangedStartRemainsUnknownAndResetClearsHistory() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0).source, .unknown)
        classifier.reset()
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin).source, .unknown)
    }

    func testPhasedStreamWithoutTrackpadStartStaysUnknown() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0).source, .unknown)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0).source, .unknown)
    }

    func testCancelledMayBeginDoesNotClaimNewPhasedStream() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        XCTAssertEqual(classifier.classify(scrollPhase: Int64(CGScrollPhase.cancelled.rawValue), momentumPhase: 0, at: 2).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 3_000_000_000).source, .unknown)
    }

    func testMissingBeganUsesPendingTrackpadPreludeUntilReset() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3_000_000_000).source, .trackpad)

        classifier.reset()
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3_000_000_000).source, .unknown)
    }

    func testLongRestBeforeTrackpadBeganKeepsSameDirectionUntilEnded() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 10_000_000_000).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 10_000_000_001).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 10_000_000_002).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 10_000_000_003).source, .unknown)
    }

    func testTrackpadGestureKeepsOwnerAcrossLongPauseUntilEnded() {
        var classifier = ScrollSourceClassifier()
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3).source, .trackpad)

        // Fingers can remain on the trackpad while the user pauses. macOS
        // still owns the gesture until its explicit ended/cancelled phase.
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3_000_000_000).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3_000_000_001).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3_000_000_002).source, .unknown)
    }

    func testNewGestureStartReplacesOrphanedTrackpadOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)

        // Even if the old ended event is lost, a new begin without trackpad
        // evidence must not inherit the old owner.
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 3_000_000_000).source, .unknown)
        XCTAssertEqual(classifier.classify(scrollPhase: changed, momentumPhase: 0, at: 3_000_000_001).source, .unknown)
        XCTAssertEqual(classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 4_000_000_000).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: began, momentumPhase: 0, at: 4_000_000_001).source, .trackpad)
    }

    func testOldPendingMomentumDoesNotCrossAnEventGap() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 2_000_000_000).source, .unknown)
    }

    func testActiveTrackpadMomentumKeepsOwnerAfterLongGapAndWheelTick() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 4).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: 0, at: 1_500_000_000).source, .mouseWheel)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 3_000_000_000).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: Int64(CGMomentumScrollPhase.end.rawValue), at: 3_000_000_001).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 3_000_000_002).source, .unknown)
    }

    func testNewMomentumBeginReplacesOrphanedOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        _ = classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 4)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 3_000_000_000).source, .unknown)
    }

    func testSecondMomentumBeginCannotReuseConsumedTrackpadOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 4).source, .trackpad)

        // A fresh momentum begin denotes a new stream. Without another
        // direct ended event, the original owner is no longer evidence.
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 5).source, .unknown)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 6).source, .unknown)
    }

    func testMissingMomentumBeginAlsoConsumesPendingTrackpadOwner() {
        var classifier = ScrollSourceClassifier()
        _ = classifier.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = classifier.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = classifier.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 4).source, .trackpad)
        XCTAssertEqual(classifier.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 5).source, .unknown)
    }
}

private extension ScrollSourceClassifier {
    mutating func classify(scrollPhase: Int64, momentumPhase: Int64) -> Decision {
        classify(scrollPhase: scrollPhase, momentumPhase: momentumPhase, at: 1)
    }
}

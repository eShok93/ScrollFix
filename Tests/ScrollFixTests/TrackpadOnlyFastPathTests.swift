import CoreGraphics
import XCTest
@testable import ScrollFix

final class TrackpadOnlyFastPathTests: XCTestCase {
    private let mayBegin = Int64(CGScrollPhase.mayBegin.rawValue)
    private let began = Int64(CGScrollPhase.began.rawValue)
    private let changed = Int64(CGScrollPhase.changed.rawValue)
    private let ended = Int64(CGScrollPhase.ended.rawValue)
    private let cancelled = Int64(CGScrollPhase.cancelled.rawValue)
    private let momentumBegin = Int64(CGMomentumScrollPhase.begin.rawValue)
    private let momentumEnd = Int64(CGMomentumScrollPhase.end.rawValue)

    func testPolicyWaitsThroughDirectGestureAndMomentum() {
        var path = TrackpadOnlyFastPath()
        XCTAssertTrue(path.request(true, at: 0))
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.afterEvent(scrollPhase: began, momentumPhase: 0, at: 2)
        XCTAssertFalse(path.request(false, at: 3))
        XCTAssertFalse(path.beforeEvent(scrollPhase: changed, momentumPhase: 0, at: 4))
        XCTAssertTrue(path.selected)
        _ = path.afterEvent(scrollPhase: ended, momentumPhase: 0, at: 5)
        XCTAssertFalse(path.beforeEvent(scrollPhase: 0, momentumPhase: momentumBegin, at: 6))
        _ = path.afterEvent(scrollPhase: 0, momentumPhase: momentumBegin, at: 6)
        XCTAssertTrue(path.selected)
        XCTAssertTrue(path.afterEvent(scrollPhase: 0, momentumPhase: momentumEnd, at: 7))
        XCTAssertFalse(path.selected)
    }

    func testNoMomentumAppliesAfterGraceWindow() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.request(false, at: 2)
        _ = path.afterEvent(scrollPhase: ended, momentumPhase: 0, at: 3)
        XCTAssertFalse(path.beforeEvent(scrollPhase: 0, momentumPhase: 0, at: 999_999_999))
        XCTAssertTrue(path.selected)
        XCTAssertTrue(path.beforeEvent(scrollPhase: 0, momentumPhase: 0, at: 1_000_000_003))
        XCTAssertFalse(path.selected)
    }

    func testNewMayBeginReplacesOrphanedGesture() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.request(false, at: 2)
        XCTAssertTrue(path.beforeEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 3))
        XCTAssertFalse(path.selected)
    }

    func testBeganAfterMayBeginDoesNotPrematurelySwitch() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.request(false, at: 2)
        XCTAssertFalse(path.beforeEvent(scrollPhase: began, momentumPhase: 0, at: 3))
        XCTAssertTrue(path.selected)
    }

    func testResetAdoptsPendingPolicy() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.request(false, at: 2)
        XCTAssertTrue(path.reset())
        XCTAssertFalse(path.selected)
    }

    func testPhaseFreeBurstHoldsDirectionUntilQuiet() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: 0, momentumPhase: 0, at: 1)
        XCTAssertFalse(path.request(false, at: 2))
        XCTAssertFalse(path.beforeEvent(scrollPhase: 0, momentumPhase: 0, at: 500_000_000))
        _ = path.afterEvent(scrollPhase: 0, momentumPhase: 0, at: 500_000_000)
        XCTAssertFalse(path.beforeEvent(scrollPhase: 0, momentumPhase: 0, at: 1_200_000_000))
        XCTAssertTrue(path.beforeEvent(scrollPhase: 0, momentumPhase: 0, at: 1_500_000_000))
        XCTAssertFalse(path.selected)
    }

    func testLostTerminalPhaseRetainsPolicyUntilNextExplicitStartOrReset() {
        var path = TrackpadOnlyFastPath()
        _ = path.request(true, at: 0)
        _ = path.afterEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = path.request(false, at: 2)
        XCTAssertFalse(path.beforeEvent(scrollPhase: changed, momentumPhase: 0, at: 20_000_000_000))
        XCTAssertTrue(path.selected)
        XCTAssertTrue(path.beforeEvent(scrollPhase: mayBegin, momentumPhase: 0, at: 20_000_000_001))
        XCTAssertFalse(path.selected)
    }

    func testCancellationReleasesPendingPolicyAfterMomentum() {
        var path = TrackpadOnlyFastPath()
        XCTAssertTrue(path.request(true, at: 0))
        _ = path.afterEvent(scrollPhase: 0, momentumPhase: momentumBegin, at: 1)
        XCTAssertFalse(path.request(false, at: 2))
        XCTAssertTrue(path.selected)

        XCTAssertTrue(path.afterEvent(scrollPhase: cancelled, momentumPhase: 0, at: 3))
        XCTAssertFalse(path.selected)
    }
}

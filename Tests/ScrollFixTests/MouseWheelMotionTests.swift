import XCTest
@testable import ScrollFix

final class MouseWheelMotionTests: XCTestCase {
    func testSmallFirstImpulseHasMinimumDistanceInBothDirections() {
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1), 48)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: -1, lineDelta: -1), -48)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 28, lineDelta: 3), 48)
    }

    func testLargeImpulseRetainsDistance() {
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 120, lineDelta: 12), 120)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: -120, lineDelta: -12), -120)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 0, lineDelta: 10), 100)
    }

    func testMinimumStepIsConfigurableAndValidated() {
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1, minimumStep: 64), 64)
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1, minimumStep: .min))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1, minimumStep: 129))
    }

    func testMalformedAndEmptyInputsAreRejected() {
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: .min, lineDelta: 1))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: .min))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 100_000, lineDelta: 1))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 0, lineDelta: 100))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 0, lineDelta: 0))
        var motion = MouseWheelMotion()
        XCTAssertNil(motion.add(distance: .min, at: 0))
        XCTAssertNil(motion.add(distance: 769, at: 0))
        XCTAssertFalse(motion.isActive)
    }

    func testFirstResponseIsImmediateAndSymmetric() {
        var positive = MouseWheelMotion(), negative = MouseWheelMotion()
        XCTAssertEqual(positive.add(distance: 48, at: 0), 17)
        XCTAssertEqual(negative.add(distance: -48, at: 0), -17)
    }

    func testTotalDistanceIsExactAtDifferentFrameRates() {
        for interval: UInt64 in [4_166_667, 8_333_333, 16_666_667, 33_333_333] {
            for distance: Int64 in [16, 48, 64, 127, 768, -48, -768] {
                var motion = MouseWheelMotion()
                var total = motion.add(distance: distance, at: 0)!
                var time = interval
                while motion.isActive {
                    total += motion.advance(at: time)
                    time += interval
                }
                XCTAssertEqual(total, distance, "interval \(interval), distance \(distance)")
            }
        }
    }

    func testLaterRastesHaveSameDistanceAsFirstRaste() {
        var motion = MouseWheelMotion()
        var total: Int64 = 0
        for i: UInt64 in 0..<5 {
            total += motion.add(distance: 48, at: i * 20_000_000)!
        }
        total += motion.advance(at: 170_000_000)
        XCTAssertEqual(total, 5 * 48)
        XCTAssertFalse(motion.isActive)
    }

    func testReverseStopsOldTailImmediately() {
        var motion = MouseWheelMotion()
        XCTAssertEqual(motion.add(distance: 48, at: 0), 17)
        XCTAssertEqual(motion.add(distance: -48, at: 10_000_000), -17)
        XCTAssertEqual(motion.advance(at: 100_000_000), -31)
    }

    func testCancelDropsTail() {
        var motion = MouseWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        motion.cancel()
        XCTAssertEqual(motion.advance(at: 90_000_000), 0)
        XCTAssertFalse(motion.isActive)
    }

    func testStalledTimerCannotEmitWakeBurst() {
        var motion = MouseWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        XCTAssertEqual(motion.advance(at: 200_000_000), 0)
        XCTAssertFalse(motion.isActive)
        XCTAssertEqual(motion.add(distance: 48, at: 210_000_000), 17)
    }

    func testBackwardsClockCancelsMotion() {
        var motion = MouseWheelMotion()
        _ = motion.add(distance: 48, at: 100)
        XCTAssertEqual(motion.advance(at: 99), 0)
        XCTAssertFalse(motion.isActive)
    }

    func testHighRateStreamIsBoundedAndConservesDistance() {
        var motion = MouseWheelMotion()
        var total: Int64 = 0
        for _ in 0..<1000 {
            let immediate = motion.add(distance: 48, at: 0)!
            XCTAssertLessThanOrEqual(abs(immediate), MouseWheelMotion.maximumInput)
            total += immediate
        }
        total += motion.advance(at: 90_000_000)
        XCTAssertEqual(total, 48_000)
        XCTAssertFalse(motion.isActive)
    }
}

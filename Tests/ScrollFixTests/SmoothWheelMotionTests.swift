import XCTest
@testable import ScrollFix

final class SmoothWheelMotionTests: XCTestCase {
    private func finish(_ motion: inout SmoothWheelMotion, from start: UInt64 = 0,
                        interval: UInt64 = 16_666_667) -> Int64 {
        var time = start
        var total: Int64 = 0
        for _ in 0..<500 {
            guard motion.isActive else { break }
            time += interval
            total += motion.advance(at: time)
        }
        XCTAssertFalse(motion.isActive)
        return total
    }

    func testNewImpulseHasNoImmediateJump() {
        var motion = SmoothWheelMotion()
        XCTAssertEqual(motion.add(distance: 48, at: 0), 48)
        XCTAssertEqual(motion.advance(at: 0), 0)
        XCTAssertEqual(motion.advance(at: 8_333_333), 0)
        XCTAssertTrue(motion.isActive)
    }

    func testTactileAndSmoothAreDifferentResponses() {
        var tactile = MouseWheelMotion(), smooth = SmoothWheelMotion()
        XCTAssertEqual(tactile.add(distance: 48, at: 0), 17)
        XCTAssertEqual(smooth.add(distance: 48, at: 0), 48)
        XCTAssertEqual(smooth.advance(at: 0), 0)
        XCTAssertGreaterThan(smooth.advance(at: 50_000_000), 0)
        XCTAssertTrue(smooth.isActive)
        _ = tactile.advance(at: 90_000_000)
        XCTAssertFalse(tactile.isActive)
        XCTAssertTrue(smooth.isActive)
    }

    func testTotalAcceptedDistanceIsExactAcrossDisplayRates() {
        for interval: UInt64 in [4_166_667, 6_944_444, 8_333_333, 16_666_667, 33_333_333] {
            for distance: Int64 in [16, 48, 128, 768, -48, -768] {
                var motion = SmoothWheelMotion()
                XCTAssertEqual(motion.add(distance: distance, at: 0), distance)
                XCTAssertEqual(finish(&motion, interval: interval), distance)
            }
        }
    }

    func testResponseAtSameTimeDoesNotDependOnDisplayRate() {
        var results: [Int64] = []
        for interval: UInt64 in [4_166_667, 8_333_333, 16_666_667, 33_333_333] {
            var motion = SmoothWheelMotion()
            _ = motion.add(distance: 48, at: 0)
            var time: UInt64 = 0, total: Int64 = 0
            while time < 200_000_000 {
                time = min(time + interval, 200_000_000)
                total += motion.advance(at: time)
            }
            results.append(total)
        }
        XCTAssertTrue(results.allSatisfy { $0 == results[0] })
        XCTAssertTrue((24...27).contains(results[0]))
    }

    func testMovementAcceleratesGentlyAndDoesNotOvershoot() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 128, at: 0)
        var total: Int64 = 0
        var firstFrames: [Int64] = []
        for index: UInt64 in 1...120 {
            let frame = motion.advance(at: index * 16_666_667)
            if index <= 8 { firstFrames.append(frame) }
            XCTAssertGreaterThanOrEqual(frame, 0)
            total += frame
            XCTAssertLessThanOrEqual(total, 128)
        }
        XCTAssertLessThan(firstFrames[0], firstFrames[5])
        XCTAssertLessThanOrEqual(firstFrames.max()!, 10)
        XCTAssertEqual(total, 128)
    }

    func testSuccessiveImpulsesJoinOneContinuousMotion() {
        var motion = SmoothWheelMotion()
        var total: Int64 = 0
        for time: UInt64 in stride(from: 0, through: 400_000_000, by: 10_000_000) {
            if time % 80_000_000 == 0 { XCTAssertEqual(motion.add(distance: 48, at: time), 48) }
            let frame = motion.advance(at: time)
            XCTAssertGreaterThanOrEqual(frame, 0)
            XCTAssertLessThan(frame, 17)
            total += frame
        }
        total += finish(&motion, from: 400_000_000)
        XCTAssertEqual(total, 6 * 48)
    }

    func testInputBetweenFramesDoesNotLoseDistance() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        var total = motion.advance(at: 20_000_000)
        _ = motion.add(distance: 48, at: 25_000_000)
        _ = motion.add(distance: 48, at: 26_000_000)
        total += finish(&motion, from: 26_000_000)
        XCTAssertEqual(total, 144)
    }

    func testReverseDiscardsOldVelocityAndTail() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        XCTAssertGreaterThan(motion.advance(at: 100_000_000), 0)
        XCTAssertEqual(motion.add(distance: -48, at: 110_000_000), -48)
        XCTAssertEqual(motion.advance(at: 110_000_000), 0)
        let firstCounter = motion.advance(at: 118_333_333)
        XCTAssertLessThan(firstCounter, 0)
        let total = firstCounter + finish(&motion, from: 118_333_333)
        // The responsive cutoff discards residual movement. At this 60-Hz
        // sampling phase, up to three pixels of this 48-pixel counter remain.
        XCTAssertTrue((-48 ... -45).contains(total), "Unexpected counter distance: \(total)")
    }

    func testJitteredFramesConserveDistance() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        var now: UInt64 = 0, total: Int64 = 0
        let intervals: [UInt64] = [8_000_000, 23_000_000, 11_000_000, 17_000_000]
        for index in 0..<200 {
            guard motion.isActive else { break }
            now += intervals[index % intervals.count]
            total += motion.advance(at: now)
        }
        XCTAssertEqual(total, 48)
        XCTAssertFalse(motion.isActive)
    }

    func testCancelDropsBothResponseStates() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        motion.cancel()
        XCTAssertEqual(motion.advance(at: 100_000_000), 0)
        XCTAssertFalse(motion.isActive)
    }

    func testStalledOrBackwardsClockCannotReplayTail() {
        for time: UInt64 in [99, 200_000_101] {
            var motion = SmoothWheelMotion()
            _ = motion.add(distance: 48, at: 100)
            XCTAssertEqual(motion.advance(at: time), 0)
            XCTAssertFalse(motion.isActive)
        }
    }

    func testRepeatedInputsDoNotConcealMissingFrameClock() {
        var motion = SmoothWheelMotion()
        for time: UInt64 in stride(from: 0, through: 150_000_000, by: 5_000_000) {
            _ = motion.add(distance: 48, at: time)
        }
        XCTAssertEqual(motion.advance(at: 200_000_000), 0)
        XCTAssertFalse(motion.isActive)
        XCTAssertEqual(motion.add(distance: 48, at: 210_000_000), 48)
        XCTAssertEqual(finish(&motion, from: 210_000_000), 48)
    }

    func testExtremeInputSaturatesInsteadOfCreatingUnboundedReplay() {
        var motion = SmoothWheelMotion()
        var accepted: Int64 = 0
        for _ in 0..<10_000 { accepted += motion.add(distance: 48, at: 0)! }
        XCTAssertEqual(accepted, Int64(SmoothWheelMotion.maximumPending))
        XCTAssertEqual(finish(&motion), accepted)
    }

    func testMalformedInputIsRejectedWithoutStartingMotion() {
        var motion = SmoothWheelMotion()
        for value: Int64 in [.min, .max, 0, 769] { XCTAssertNil(motion.add(distance: value, at: 0)) }
        XCTAssertFalse(motion.isActive)
    }

    func testResponsiveCounterStartsOnNext120HzFrameWithoutImmediateJump() {
        for sign: Int64 in [-1, 1] {
            var motion = SmoothWheelMotion()
            _ = motion.add(distance: sign * 768, at: 0)
            _ = motion.advance(at: 100_000_000)
            _ = motion.add(distance: -sign * 48, at: 110_000_000)
            XCTAssertEqual(motion.advance(at: 110_000_000), 0)
            XCTAssertEqual(motion.advance(at: 118_333_333), -sign)
            for index: UInt64 in 2...40 {
                let frame = motion.advance(at: 110_000_000 + index * 8_333_333)
                XCTAssertGreaterThanOrEqual(frame * -sign, 0)
            }
            XCTAssertFalse(motion.isActive)
        }
    }

    func testDenseTailStopsAt220msWithoutFinalBacklogFlush() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 768, at: 0, responsive: true)
        var total: Int64 = 0
        for time: UInt64 in stride(from: 10_000_000, through: 210_000_000, by: 10_000_000) {
            total += motion.advance(at: time)
        }
        XCTAssertEqual(motion.advance(at: SmoothWheelMotion.responsiveTail), 0)
        XCTAssertFalse(motion.isActive)
        XCTAssertGreaterThan(total, 700)
        XCTAssertLessThan(total, 768)
        XCTAssertEqual(motion.advance(at: 400_000_000), 0)
    }

    func testResponsiveProfileLatchesUntilExplicitNewGesture() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0, responsive: true)
        _ = motion.advance(at: 10_000_000)
        _ = motion.add(distance: 48, at: 20_000_000)
        XCTAssertTrue(motion.isResponsive)
        _ = motion.advance(at: 100_000_000)
        _ = motion.add(distance: 48, at: 170_000_000, startsNewGesture: true)
        XCTAssertFalse(motion.isResponsive)
        XCTAssertEqual(motion.advance(at: 178_333_333), 0)
    }

    func testOppositeNewGestureStillStopsActiveOldTailWithFastCounter() {
        for sign: Int64 in [-1, 1] {
            var motion = SmoothWheelMotion()
            _ = motion.add(distance: sign * 48, at: 0, responsive: true)
            _ = motion.advance(at: 100_000_000)
            _ = motion.add(distance: -sign * 48, at: 150_000_000,
                           responsive: false, startsNewGesture: true)
            XCTAssertTrue(motion.isResponsive)
            XCTAssertEqual(motion.advance(at: 158_333_333), -sign)
            _ = motion.add(distance: -sign * 48, at: 300_000_000, startsNewGesture: true)
            XCTAssertFalse(motion.isResponsive)
            XCTAssertEqual(motion.advance(at: 308_333_333), 0)
        }
    }

    func testProfileTransitionDoesNotCauseAnImmediateFrameOrDirectionChange() {
        var motion = SmoothWheelMotion()
        _ = motion.add(distance: 48, at: 0)
        _ = motion.advance(at: 40_000_000)
        _ = motion.add(distance: 1, at: 40_000_000, responsive: true)
        XCTAssertEqual(motion.advance(at: 40_000_000), 0)
        XCTAssertTrue(motion.isResponsive)
        var total: Int64 = 0
        for index: UInt64 in 1...30 {
            let frame = motion.advance(at: 40_000_000 + index * 8_333_333)
            XCTAssertGreaterThanOrEqual(frame, 0)
            XCTAssertLessThan(frame, 5)
            total += frame
        }
        XCTAssertLessThanOrEqual(total, 49)
    }

    func testResponsiveInputDoesNotHideAStalledClock() {
        var motion = SmoothWheelMotion()
        for time: UInt64 in stride(from: 0, through: 150_000_000, by: 5_000_000) {
            _ = motion.add(distance: 1, at: time, responsive: true)
        }
        XCTAssertEqual(motion.advance(at: 200_000_000), 0)
        XCTAssertFalse(motion.isActive)
    }
}

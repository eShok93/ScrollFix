import XCTest
@testable import ScrollFix

final class WheelInputCadenceTests: XCTestCase {
    func testFiveFastInputsEnterDenseStream() {
        var cadence = WheelInputCadence()
        for index: UInt64 in 0..<5 {
            let sample = cadence.observe(distance: 1, at: index * 10_000_000)
            XCTAssertEqual(sample.isDense, index == 4)
            XCTAssertEqual(sample.startsNewGesture, index == 0)
        }
    }

    func testSlowInputsAndSameTimestampCannotClaimDenseStream() {
        for interval: UInt64 in [0, 36_000_000, 80_000_000] {
            var cadence = WheelInputCadence()
            for index: UInt64 in 0..<20 {
                XCTAssertFalse(cadence.observe(distance: 1, at: index * interval).isDense)
            }
        }
    }

    func testDenseStateSurvivesDecelerationAndReversal() {
        var cadence = WheelInputCadence()
        for index: UInt64 in 0..<5 { _ = cadence.observe(distance: 1, at: index * 10_000_000) }
        XCTAssertTrue(cadence.observe(distance: 1, at: 100_000_000).isDense)
        let reverse = cadence.observe(distance: -1, at: 180_000_000)
        XCTAssertTrue(reverse.isDense)
        XCTAssertTrue(reverse.reversed)
        XCTAssertFalse(reverse.startsNewGesture)
    }

    func testQuietGapBackwardsTimeAndCancelResetClassification() {
        for reset in 0..<3 {
            var cadence = WheelInputCadence()
            for index: UInt64 in 0..<5 { _ = cadence.observe(distance: 1, at: index * 10_000_000) }
            if reset == 2 { cadence.cancel() }
            let time: UInt64 = reset == 0 ? 190_000_000 : (reset == 1 ? 39_000_000 : 50_000_000)
            let sample = cadence.observe(distance: -1, at: time)
            XCTAssertFalse(sample.isDense)
            XCTAssertTrue(sample.startsNewGesture)
            XCTAssertFalse(sample.reversed)
        }
    }

    func testMalformedInputsResetWithoutOverflow() {
        for value: Int64 in [.min, .max, 0, 769] {
            var cadence = WheelInputCadence()
            for index: UInt64 in 0..<5 { _ = cadence.observe(distance: 1, at: index * 10_000_000) }
            XCTAssertFalse(cadence.observe(distance: value, at: 50_000_000).isDense)
            XCTAssertTrue(cadence.observe(distance: 1, at: 60_000_000).startsNewGesture)
        }
    }

    func testProportionalNormalizationRetainsNumericAndPreferenceGuards() {
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1, applyMinimum: false), 1)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: -1, lineDelta: -1, applyMinimum: false), -1)
        XCTAssertEqual(MouseWheelMotion.normalizedDistance(pointDelta: 0, lineDelta: -1, applyMinimum: false), -10)
        for value: Int64 in [.min, .max, 769] {
            XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: value, lineDelta: 1, applyMinimum: false))
            XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: value, applyMinimum: false))
        }
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 0, lineDelta: 77, applyMinimum: false))
        XCTAssertNil(MouseWheelMotion.normalizedDistance(pointDelta: 1, lineDelta: 1, minimumStep: .max, applyMinimum: false))
    }
}

import XCTest
@testable import ScrollFix

final class MouseWheelFrameClockTests: XCTestCase {
    func testSelectsPointerDisplayAndIgnoresOtherPulses() {
        let first = Driver(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = Driver(id: 2, bounds: CGRect(x: -100, y: 0, width: 100, height: 100))
        var frames = 0
        let clock = MouseWheelFrameClock(drivers: [first, second]) { frames += 1 }
        XCTAssertTrue(clock.resume(at: CGPoint(x: -50, y: 50)))
        XCTAssertEqual(first.starts, 0)
        XCTAssertEqual(second.starts, 1)
        clock.receivePulse(from: 1)
        XCTAssertEqual(frames, 0)
        clock.receivePulse(from: 2)
        XCTAssertEqual(frames, 1)
        XCTAssertTrue(clock.resume(at: CGPoint(x: -50, y: 50)))
        XCTAssertEqual(second.starts, 1)
        clock.invalidate()
    }

    func testChangingDisplayPausesOldDriver() {
        let first = Driver(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = Driver(id: 2, bounds: CGRect(x: 100, y: 0, width: 100, height: 100))
        let clock = MouseWheelFrameClock(drivers: [first, second]) {}
        XCTAssertTrue(clock.resume(at: CGPoint(x: 50, y: 50)))
        XCTAssertTrue(clock.resume(at: CGPoint(x: 150, y: 50)))
        XCTAssertEqual(first.pauses, 1)
        XCTAssertEqual(second.starts, 1)
        clock.invalidate()
    }

    func testPauseAndInvalidationRejectLatePulses() {
        let driver = Driver(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        var frames = 0
        let clock = MouseWheelFrameClock(drivers: [driver]) { frames += 1 }
        XCTAssertTrue(clock.resume(at: .zero))
        clock.pause()
        clock.receivePulse(from: 1)
        XCTAssertEqual(frames, 0)
        XCTAssertTrue(clock.resume(at: .zero))
        clock.invalidate()
        clock.receivePulse(from: 1)
        XCTAssertFalse(clock.resume(at: .zero))
        XCTAssertEqual(driver.invalidations, 1)
        XCTAssertEqual(frames, 0)
    }

    func testFailedDriverCannotClaimActiveClock() {
        let driver = Driver(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        driver.canStart = false
        var frames = 0
        let clock = MouseWheelFrameClock(drivers: [driver]) { frames += 1 }
        XCTAssertFalse(clock.resume(at: .zero))
        clock.receivePulse(from: 1)
        XCTAssertEqual(frames, 0)
        clock.invalidate()
    }

    func testHealthRequiresRealPulsesRatherThanMoreInputs() {
        var health = WheelFrameClockHealth()
        health.start(at: 0)
        health.start(at: 90_000_000)
        XCTAssertTrue(health.isStalled(at: 101_000_000))
        health.pulse(at: 95_000_000)
        XCTAssertFalse(health.isStalled(at: 101_000_000))
        XCTAssertTrue(health.isStalled(at: 200_000_000))
        health.reset()
        XCTAssertFalse(health.isStalled(at: 900_000_000))
    }

    private final class Driver: WheelDisplayPulseDriver {
        let displayID: UInt32
        let bounds: CGRect
        var starts = 0, pauses = 0, invalidations = 0
        var canStart = true
        init(id: UInt32, bounds: CGRect) { displayID = id; self.bounds = bounds }
        func resume() -> Bool { starts += 1; return canStart }
        func pause() { pauses += 1 }
        func invalidate() { invalidations += 1 }
    }
}

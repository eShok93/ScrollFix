import CoreGraphics
import XCTest
@testable import ScrollFix

final class AutoScrollPhysicsTests: XCTestCase {
    func testRadialDeadZone() {
        var physics = AutoScrollPhysics()

        XCTAssertNil(physics.tick(offset: CGVector(dx: 8, dy: 8)))
        XCTAssertNil(physics.tick(offset: CGVector(dx: 0, dy: 12)))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: 22)), .init(vertical: 2, horizontal: 0))
    }

    func testAxesFollowAppKitAndWheelConventions() {
        var physics = AutoScrollPhysics()

        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: 22)), .init(vertical: 2, horizontal: 0))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: -22)), .init(vertical: -2, horizontal: 0))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: 22, dy: 0)), .init(vertical: 0, horizontal: -2))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: -22, dy: 0)), .init(vertical: 0, horizontal: 2))
    }

    func testFractionalPixelsCarryBetweenTicks() {
        var physics = AutoScrollPhysics()
        let offset = CGVector(dx: 0, dy: 14.5) // (14.5 - 12) * 0.2 = 0.5 pixel

        XCTAssertNil(physics.tick(offset: offset))
        XCTAssertEqual(physics.tick(offset: offset), .init(vertical: 1, horizontal: 0))
    }

    func testDeadZoneAndResetDiscardOldRemainder() {
        var physics = AutoScrollPhysics()
        let offset = CGVector(dx: 0, dy: 14.5)

        XCTAssertNil(physics.tick(offset: offset))
        XCTAssertNil(physics.tick(offset: .zero))
        XCTAssertNil(physics.tick(offset: offset))
        physics.reset()
        XCTAssertNil(physics.tick(offset: offset))
    }

    func testReversalDoesNotInheritOppositeRemainder() {
        var physics = AutoScrollPhysics()

        XCTAssertNil(physics.tick(offset: CGVector(dx: 0, dy: 14.5)))
        XCTAssertNil(physics.tick(offset: CGVector(dx: 0, dy: -14.5)))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: -14.5)), .init(vertical: -1, horizontal: 0))
    }

    func testSpeedAndExtremeOffsetsAreBounded() {
        var physics = AutoScrollPhysics()

        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: 10_000), speed: 3), .init(vertical: 240, horizontal: 0))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: 0, dy: -10_000), speed: 100), .init(vertical: -240, horizontal: 0))
        XCTAssertEqual(physics.tick(offset: CGVector(dx: CGFloat.greatestFiniteMagnitude, dy: 0)), .init(vertical: 0, horizontal: -80))
    }

    func testInvalidInputFailsClosedAndClearsRemainder() {
        var physics = AutoScrollPhysics()
        let offset = CGVector(dx: 0, dy: 14.5)

        XCTAssertNil(physics.tick(offset: offset))
        XCTAssertNil(physics.tick(offset: CGVector(dx: CGFloat.nan, dy: 0)))
        XCTAssertNil(physics.tick(offset: offset))
        XCTAssertNil(physics.tick(offset: offset, speed: .infinity))
        XCTAssertNil(physics.tick(offset: offset))
        XCTAssertNil(physics.tick(offset: offset, speed: 0))
        XCTAssertNil(physics.tick(offset: offset))
    }

    func testElapsedTimeKeepsDistanceStableWhenTimerCadenceChanges() {
        let offset = CGVector(dx: 0, dy: 22)
        var regular = AutoScrollPhysics()
        var delayed = AutoScrollPhysics()
        let regularPixels = (0..<60).reduce(0) { total, _ in
            total + Int(regular.tick(offset: offset, elapsedSeconds: 0.016)?.vertical ?? 0)
        }
        let delayedPixels = (0..<30).reduce(0) { total, _ in
            total + Int(delayed.tick(offset: offset, elapsedSeconds: 0.032)?.vertical ?? 0)
        }
        XCTAssertEqual(regularPixels, 120)
        XCTAssertEqual(delayedPixels, regularPixels)
    }

    func testLongTimerPauseIsCappedAndInvalidElapsedTimeClearsRemainder() {
        var physics = AutoScrollPhysics()
        XCTAssertEqual(
            physics.tick(offset: CGVector(dx: 0, dy: 22), elapsedSeconds: 0.25),
            .init(vertical: 5, horizontal: 0)
        )
        let slow = CGVector(dx: 0, dy: 14.5)
        XCTAssertNil(physics.tick(offset: slow))
        XCTAssertNil(physics.tick(offset: slow, elapsedSeconds: .nan))
        XCTAssertNil(physics.tick(offset: slow))
    }
}

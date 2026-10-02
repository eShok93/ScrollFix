import CoreGraphics
import XCTest
@testable import ScrollFix

final class MiddleClickRoutingTests: XCTestCase {
    func testCommandControlOptionShiftRemainNativeButCapsLockDoesNot() {
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift, [.maskCommand, .maskShift]] {
            XCTAssertTrue(MiddleClickRouting.preservesNativeModifiers(flags))
        }
        XCTAssertFalse(MiddleClickRouting.preservesNativeModifiers([]))
        XCTAssertFalse(MiddleClickRouting.preservesNativeModifiers(.maskAlphaShift))
    }

    func testAnchorUsesQuartzDownCoordinatesIncludingOtherScreens() {
        XCTAssertEqual(MiddleClickRouting.appKitAnchor(from: CGPoint(x: 320, y: 400), primaryDisplayHeight: 1440),
                       CGPoint(x: 320, y: 1040))
        XCTAssertEqual(MiddleClickRouting.appKitAnchor(from: CGPoint(x: -100, y: -500), primaryDisplayHeight: 1440),
                       CGPoint(x: -100, y: 1940))
        XCTAssertEqual(MiddleClickRouting.appKitAnchor(from: CGPoint(x: 2000, y: 2000), primaryDisplayHeight: 1440),
                       CGPoint(x: 2000, y: -560))
    }

    func testInvalidAnchorOrDisplayHeightCannotBeCaptured() {
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 0, y: -CGFloat.infinity)] {
            XCTAssertNil(MiddleClickRouting.appKitAnchor(from: point, primaryDisplayHeight: 1440))
        }
        for height: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertNil(MiddleClickRouting.appKitAnchor(from: .zero, primaryDisplayHeight: height))
        }
        XCTAssertNil(MiddleClickRouting.appKitAnchor(from: CGPoint(x: 0, y: -CGFloat.greatestFiniteMagnitude),
                                                   primaryDisplayHeight: CGFloat.greatestFiniteMagnitude))
    }

    func testLinkDownAndUpPassNativelyWithoutCapture() {
        var routing = MiddleClickRouting()
        XCTAssertEqual(routing.down { MiddleClickTarget.link.route }, .native)
        XCTAssertFalse(routing.isCapturing)
        XCTAssertEqual(routing.up(), .native)
        XCTAssertNil(routing.heldRoute)
    }

    func testContentDownAndUpAreBothCaptured() {
        var routing = MiddleClickRouting()
        XCTAssertEqual(routing.down { MiddleClickTarget.content.route }, .captured)
        XCTAssertTrue(routing.isCapturing)
        XCTAssertEqual(routing.up(), .captured)
        XCTAssertFalse(routing.isCapturing)
    }

    func testUnknownAndControlsPassNatively() {
        for target in [MiddleClickTarget.unknown, .nativeControl] {
            var routing = MiddleClickRouting()
            XCTAssertEqual(routing.down { target.route }, .native)
            XCTAssertEqual(routing.up(), .native)
        }
    }

    func testNativeDuplicateNeverQueriesNewContentTarget() {
        var routing = MiddleClickRouting()
        _ = routing.down { .native }
        for _ in 0..<4 {
            XCTAssertEqual(routing.down { XCTFail("Must not reclassify a native pair"); return .captured }, .native)
        }
        XCTAssertEqual(routing.dragRoute, .native)
        XCTAssertEqual(routing.up(), .native)
    }

    func testCapturedDuplicateAndDragNeverLeakToLinkUnderPointer() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        XCTAssertEqual(routing.down { XCTFail("Must not reclassify a captured pair"); return .native }, .captured)
        XCTAssertEqual(routing.dragRoute, .captured)
        XCTAssertEqual(routing.up(), .captured)
    }

    func testAlternatingTargetsUseNewDecisionAfterEachRelease() {
        var routing = MiddleClickRouting()
        for target in [MiddleClickTarget.link, .content, .unknown, .content, .nativeControl, .link] {
            XCTAssertEqual(routing.down { target.route }, target.route)
            XCTAssertEqual(routing.up(), target.route)
        }
    }

    func testOrphanUpAndDragPassThrough() {
        var routing = MiddleClickRouting()
        XCTAssertEqual(routing.dragRoute, .native)
        XCTAssertEqual(routing.up(), .native)
        XCTAssertEqual(routing.up(), .native)
    }

    func testCapturedLostReleaseDropsOnlyOneLateUp() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        routing.expireCapturedRelease()
        XCTAssertFalse(routing.isCapturing)
        XCTAssertTrue(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.dragRoute, .captured)
        XCTAssertEqual(routing.up(), .captured)
        XCTAssertEqual(routing.dragRoute, .native)
        XCTAssertEqual(routing.up(), .native)
    }

    func testFreshNativePairClearsOldCapturedLateUpSuppression() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        routing.expireCapturedRelease()
        XCTAssertEqual(routing.down { .native }, .native)
        XCTAssertFalse(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.up(), .native)
    }

    func testFreshCaptureSupersedesOldCapturedLostRelease() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        routing.expireCapturedRelease()
        _ = routing.down { .captured }
        XCTAssertFalse(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.up(), .captured)
        XCTAssertEqual(routing.up(), .native)
    }

    func testCapturedWatchdogCannotExpireNativeHold() {
        var routing = MiddleClickRouting()
        _ = routing.down { .native }
        routing.expireCapturedRelease()
        XCTAssertEqual(routing.heldRoute, .native)
        XCTAssertFalse(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.up(), .native)
    }

    func testStopRestartRetainsNativeDecisionAndIgnoresDropRequest() {
        var routing = MiddleClickRouting()
        _ = routing.down { .native }
        routing.resetAfterTapRemoval(dropLateCapturedUp: true)
        XCTAssertEqual(routing.down { XCTFail("Already native before restart"); return .captured }, .native)
        XCTAssertFalse(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.dragRoute, .native)
        XCTAssertEqual(routing.up(), .native)
    }

    func testNativeReleaseLostWhileTapOffPassesAtMostNextFullClick() {
        var routing = MiddleClickRouting()
        _ = routing.down { .native }
        routing.resetAfterTapRemoval()
        XCTAssertEqual(routing.down { .captured }, .native)
        XCTAssertEqual(routing.up(), .native)
        XCTAssertEqual(routing.down { .captured }, .captured)
        XCTAssertEqual(routing.up(), .captured)
    }

    func testStoppedConsumedPairCanDrainLateUpAfterRestart() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        routing.resetAfterTapRemoval(dropLateCapturedUp: true)
        XCTAssertNil(routing.heldRoute)
        XCTAssertEqual(routing.up(), .captured)
        XCTAssertEqual(routing.up(), .native)
    }

    func testOrdinaryTeardownDoesNotLeaveCapturedState() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        routing.resetAfterTapRemoval()
        XCTAssertNil(routing.heldRoute)
        XCTAssertFalse(routing.dropsLateCapturedUp)
        XCTAssertEqual(routing.up(), .native)
    }

    func testNativeDownDuringDeferredConsumedPairStopSurvivesRestart() {
        var routing = MiddleClickRouting()
        _ = routing.down { .captured }
        XCTAssertEqual(routing.up(), .captured)
        // The old tap is still draining; its deferred finish has not run.
        XCTAssertEqual(routing.down { .native }, .native)
        routing.resetAfterTapRemoval()
        XCTAssertEqual(routing.down { XCTFail("Drain down was already native"); return .captured }, .native)
        XCTAssertEqual(routing.up(), .native)
    }
}

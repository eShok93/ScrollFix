import XCTest
@testable import ScrollFix

final class MiddleClickTargetProbeTests: XCTestCase {
    private func probe(_ roles: [String], own: Bool? = false) -> MiddleClickTarget {
        MiddleClickTargetProbe.resolve(
            hitTest: { roles.isEmpty ? nil : 0 }, isOwnElement: { _ in own },
            readRole: { roles[$0] }, readParent: { $0 + 1 < roles.count ? $0 + 1 : nil },
            now: { 0 }
        )
    }

    func testDirectLinkAndNestedTextOrImageAreLinks() {
        XCTAssertEqual(probe(["AXLink"]), .link)
        XCTAssertEqual(probe(["AXStaticText", "AXLink", "AXWebArea"]), .link)
        XCTAssertEqual(probe(["AXImage", "AXGroup", "AXLink", "AXWebArea"]), .link)
    }

    func testKnownContentBoundariesCaptureBlankSpace() {
        for role in ["AXWebArea", "AXScrollArea", "AXTextArea", "AXOutline", "AXTable", "AXList", "AXWindow"] {
            XCTAssertEqual(probe(["AXGroup", role, "AXWindow"]), .content, role)
        }
    }

    func testContentContainersInsideLinkDoNotHideItsAncestor() {
        for role in ["AXScrollArea", "AXTextArea", "AXOutline", "AXTable", "AXList"] {
            XCTAssertEqual(probe(["AXStaticText", role, "AXLink", "AXWebArea"]), .link, role)
            XCTAssertEqual(probe([role]), .unknown, "An incomplete container is not proof of a blank target")
        }
    }

    func testNativeControlsAndTabBarKeepTheirMiddleClick() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
                     "AXMenu", "AXMenuBar", "AXToolbar", "AXTabGroup", "AXTextField", "AXComboBox", "AXSlider", "AXIncrementor"] {
            XCTAssertEqual(probe(["AXStaticText", role, "AXWindow"]), .nativeControl, role)
        }
    }

    func testFailedHitOrUnexposedAncestryUsesNativeFallback() {
        XCTAssertEqual(probe([]), .unknown)
        XCTAssertEqual(probe(["AXStaticText"]), .unknown)
        XCTAssertEqual(probe(["AXUnknown"]), .unknown)
        XCTAssertEqual(probe(["AXApplication"]), .unknown)
        XCTAssertEqual(MiddleClickTarget.unknown.route, .native)
    }

    func testOwnOverlayAndOwnUIKeepOriginalClick() {
        XCTAssertEqual(probe(["AXImage", "AXWindow"], own: true), .nativeControl)
        XCTAssertEqual(probe(["AXWebArea"], own: true), .nativeControl)
        XCTAssertEqual(probe(["AXLink"], own: nil), .unknown)
    }

    func testFailedRoleAndParentReadsUseNativeFallback() {
        let roleFailure = MiddleClickTargetProbe.resolve(hitTest: { 1 }, isOwnElement: { _ in false },
            readRole: { _ in nil }, readParent: { _ in XCTFail("No parent read after failed role"); return 2 }, now: { 0 })
        XCTAssertEqual(roleFailure, .unknown)
        XCTAssertEqual(probe(["AXImage"]), .unknown)
    }

    func testCyclicParentIsBoundedToEightRoleReads() {
        var roleReads = 0
        var parentReads = 0
        let target = MiddleClickTargetProbe.resolve(hitTest: { 1 }, isOwnElement: { _ in false },
            readRole: { _ in roleReads += 1; return "AXGroup" },
            readParent: { _ in parentReads += 1; return 1 }, now: { 0 })
        XCTAssertEqual(target, .unknown)
        XCTAssertEqual(roleReads, 8)
        XCTAssertEqual(parentReads, 7)
    }

    func testLinkWithinLimitIsFoundAndBeyondLimitIsNotGuessed() {
        XCTAssertEqual(probe(Array(repeating: "AXGroup", count: 7) + ["AXLink"]), .link)
        XCTAssertEqual(probe(Array(repeating: "AXGroup", count: 8) + ["AXLink"]), .unknown)
    }

    func testSlowHitDoesNotTriggerRoleReads() {
        var time: UInt64 = 0
        let target = MiddleClickTargetProbe.resolve(hitTest: { time = 30_000_000; return 1 },
            isOwnElement: { _ in XCTFail("Budget exhausted"); return false },
            readRole: { _ in XCTFail("Budget exhausted"); return "AXWebArea" }, readParent: { _ in nil }, now: { time })
        XCTAssertEqual(target, .unknown)
    }

    func testSlowRoleDoesNotBecomeContentOrLinkAfterDeadline() {
        for role in ["AXLink", "AXWebArea"] {
            var time: UInt64 = 0
            let target = MiddleClickTargetProbe.resolve(hitTest: { 1 }, isOwnElement: { _ in false },
                readRole: { _ in time = 30_000_000; return role }, readParent: { _ in nil }, now: { time })
            XCTAssertEqual(target, .unknown)
        }
    }

    func testCumulativeParentCallsRespectTotalBudget() {
        var time: UInt64 = 0
        var roleReads = 0
        let target = MiddleClickTargetProbe.resolve(hitTest: { 1 }, isOwnElement: { _ in false },
            readRole: { _ in time += 6_000_000; roleReads += 1; return "AXGroup" },
            readParent: { _ in time += 6_000_000; return 1 }, now: { time })
        XCTAssertEqual(target, .unknown)
        XCTAssertEqual(roleReads, 3)
    }

    func testBackwardClockFallsBackWithoutUnsignedUnderflow() {
        var time: UInt64 = 10
        let target = MiddleClickTargetProbe.resolve(hitTest: { time = 9; return 1 }, isOwnElement: { _ in false },
            readRole: { _ in "AXWebArea" }, readParent: { _ in nil }, now: { time })
        XCTAssertEqual(target, .unknown)
    }
}

import XCTest
@testable import ScrollFix

final class AutoScrollDiagnosticsTests: XCTestCase {
    func testMiddleClickReadoutKeepsOnlyLatestTargetAndTimingMaximum() {
        var diagnostics = AutoScrollDiagnostics()
        diagnostics.recordMiddleClick(target: .link, milliseconds: 1.2)
        diagnostics.recordMiddleClick(target: .unknown, milliseconds: 31.5)
        diagnostics.recordMiddleClick(target: .content, milliseconds: 0.4)
        XCTAssertEqual(diagnostics.lastMiddleClickTarget, .content)
        XCTAssertEqual(diagnostics.lastMiddleClickMilliseconds, 0.4)
        XCTAssertEqual(diagnostics.maxMiddleClickMilliseconds, 31.5)
    }

    func testInvalidMiddleClickTimingDoesNotChangeReadout() {
        var diagnostics = AutoScrollDiagnostics()
        diagnostics.recordMiddleClick(target: .link, milliseconds: 1)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            diagnostics.recordMiddleClick(target: .content, milliseconds: invalid)
        }
        XCTAssertEqual(diagnostics.lastMiddleClickTarget, .link)
        XCTAssertEqual(diagnostics.lastMiddleClickMilliseconds, 1)
        XCTAssertEqual(diagnostics.maxMiddleClickMilliseconds, 1)
    }

    func testNewAnchorResetsScrollCountersAndRetainsClickDecision() {
        var diagnostics = AutoScrollDiagnostics()
        diagnostics.recordMiddleClick(target: .content, milliseconds: 2.3)
        diagnostics.recordTick(milliseconds: 40)
        diagnostics.recordPosted(.init(vertical: 5, horizontal: 0))
        diagnostics.resetScrollMetrics()
        XCTAssertNil(diagnostics.lastTickMilliseconds)
        XCTAssertNil(diagnostics.maxTickMilliseconds)
        XCTAssertEqual(diagnostics.delayedTicks, 0)
        XCTAssertEqual(diagnostics.postedEvents, 0)
        XCTAssertNil(diagnostics.lastPostedDelta)
        XCTAssertEqual(diagnostics.lastMiddleClickTarget, .content)
        XCTAssertEqual(diagnostics.lastMiddleClickMilliseconds, 2.3)
        XCTAssertEqual(diagnostics.maxMiddleClickMilliseconds, 2.3)
    }

    func testTickTimingTracksLatestMaximumAndDelayedCount() {
        var diagnostics = AutoScrollDiagnostics()

        diagnostics.recordTick(milliseconds: 16)
        diagnostics.recordTick(milliseconds: 24)
        diagnostics.recordTick(milliseconds: 41)
        diagnostics.recordTick(milliseconds: 30)

        XCTAssertEqual(diagnostics.lastTickMilliseconds, 30)
        XCTAssertEqual(diagnostics.maxTickMilliseconds, 41)
        XCTAssertEqual(diagnostics.delayedTicks, 2)
    }

    func testInvalidTimingsDoNotChangeMetrics() {
        var diagnostics = AutoScrollDiagnostics()
        diagnostics.recordTick(milliseconds: 18)

        diagnostics.recordTick(milliseconds: -.infinity)
        diagnostics.recordTick(milliseconds: -1)
        diagnostics.recordTick(milliseconds: .nan)
        diagnostics.recordTick(milliseconds: .infinity)

        XCTAssertEqual(diagnostics.lastTickMilliseconds, 18)
        XCTAssertEqual(diagnostics.maxTickMilliseconds, 18)
        XCTAssertEqual(diagnostics.delayedTicks, 0)
    }

    func testPostedEventsCountAndKeepLastDelta() {
        var diagnostics = AutoScrollDiagnostics()
        XCTAssertEqual(diagnostics.postedEvents, 0)
        XCTAssertNil(diagnostics.lastPostedDelta)

        diagnostics.recordPosted(.init(vertical: 3, horizontal: -1))
        diagnostics.recordPosted(.init(vertical: -4, horizontal: 2))

        XCTAssertEqual(diagnostics.postedEvents, 2)
        XCTAssertEqual(diagnostics.lastPostedDelta, .init(vertical: -4, horizontal: 2))
    }
}

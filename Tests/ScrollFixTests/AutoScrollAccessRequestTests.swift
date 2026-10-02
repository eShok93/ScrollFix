import XCTest
@testable import ScrollFix

final class AutoScrollAccessRequestTests: XCTestCase {
    @MainActor
    func testGrantedAccessDoesNotPromptOrOpenSettings() {
        var requests = 0
        var openings = 0
        let result = AutoScrollAccessRequest.perform(
            interceptionAllowed: true,
            preflight: { true },
            request: { requests += 1; return false },
            openSettings: { openings += 1 }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(openings, 0)
    }

    @MainActor
    func testSuccessfulSystemRequestDoesNotOpenSettings() {
        var requests = 0
        var openings = 0
        let result = AutoScrollAccessRequest.perform(
            interceptionAllowed: true,
            preflight: { false },
            request: { requests += 1; return true },
            openSettings: { openings += 1 }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(openings, 0)
    }

    @MainActor
    func testDeclinedOrSilentRequestOpensSettings() {
        var requests = 0
        var openings = 0
        let result = AutoScrollAccessRequest.perform(
            interceptionAllowed: true,
            preflight: { false },
            request: { requests += 1; return false },
            openSettings: { openings += 1 }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(openings, 1)
    }

    @MainActor
    func testMissingInterceptionAccessOpensSettingsWithoutQueryingPostAccess() {
        var preflights = 0
        var requests = 0
        var openings = 0
        let result = AutoScrollAccessRequest.perform(
            interceptionAllowed: false,
            preflight: { preflights += 1; return true },
            request: { requests += 1; return true },
            openSettings: { openings += 1 }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(preflights, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(openings, 1)
    }

    @MainActor
    func testPeriodicCheckWaitsForInterceptionAccess() {
        var preflights = 0
        let result = AutoScrollAccessRequest.check(
            interceptionAllowed: false,
            preflight: { preflights += 1; return true }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(preflights, 0)
    }

    @MainActor
    func testFirstGrantThenChecksFreshPostAccess() {
        var preflights = 0
        XCTAssertFalse(AutoScrollAccessRequest.check(
            interceptionAllowed: false,
            preflight: { preflights += 1; return false }
        ))
        XCTAssertTrue(AutoScrollAccessRequest.check(
            interceptionAllowed: true,
            preflight: { preflights += 1; return true }
        ))
        XCTAssertEqual(preflights, 1)
    }

    @MainActor
    func testInterceptionAccessDoesNotOverrideDeniedPostAccess() {
        XCTAssertFalse(AutoScrollAccessRequest.check(
            interceptionAllowed: true,
            preflight: { false }
        ))
    }
}

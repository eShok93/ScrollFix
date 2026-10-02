import XCTest
@testable import ScrollFix

final class MouseWheelUIStateTests: XCTestCase {
    private func readyState() -> ScrollFixStatusSnapshot {
        .init(directionEnabled: true, directionRunning: true, directionStarting: false,
              directionPausedByUserInput: false, directionIssue: nil, permissionGranted: true,
              autoScrollEnabled: false, autoScrollRunning: false, wheelRequiresPosting: true)
    }

    func testActiveRequiresPostingPermissionForSmoothWheel() {
        var state = readyState()
        state.wheelCanPost = false
        XCTAssertFalse(state.allEnabledFeaturesActive)
        XCTAssertTrue(state.needsFeatureRecovery)
        XCTAssertEqual(state.featureRecoveryTitle, "Zugriff erlauben")
        state.wheelCanPost = true
        XCTAssertTrue(state.allEnabledFeaturesActive)
        XCTAssertFalse(state.needsFeatureRecovery)
    }

    func testNativeAndDirectWheelDoNotRequirePosting() {
        var state = readyState()
        state.wheelRequiresPosting = false
        state.wheelCanPost = false
        XCTAssertTrue(state.allEnabledFeaturesActive)
        XCTAssertFalse(state.wheelNeedsAccess)
    }

    func testBothPostingFeaturesShareOneRecoveryState() {
        let state = ScrollFixStatusSnapshot(
            directionEnabled: true, directionRunning: true, directionStarting: false,
            directionPausedByUserInput: false, directionIssue: nil, permissionGranted: true,
            autoScrollEnabled: true, autoScrollRunning: false, wheelRequiresPosting: true,
            wheelCanPost: false, autoScrollCanPost: false, autoScrollHasIssue: true
        )
        XCTAssertTrue(state.needsFeatureRecovery)
        XCTAssertEqual(state.featureRecoveryTitle, "Zugriff erlauben")
    }

    func testPausedTapOffersRestartWhenPermissionsArePresent() {
        let state = ScrollFixStatusSnapshot(
            directionEnabled: true, directionRunning: false, directionStarting: false,
            directionPausedByUserInput: false, directionIssue: "Filter pausiert", permissionGranted: true,
            autoScrollEnabled: false, autoScrollRunning: false,
            wheelRequiresPosting: true, wheelCanPost: true
        )
        XCTAssertTrue(state.needsFeatureRecovery)
        XCTAssertEqual(state.featureRecoveryTitle, "Erneut starten")
    }
}

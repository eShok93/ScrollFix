import XCTest
@testable import ScrollFix

final class ScrollFixStatusSnapshotTests: XCTestCase {
    func testOverallActiveRequiresEveryEnabledFeatureToRun() {
        let failedDirection = status(directionRunning: false, autoScrollEnabled: true, autoScrollRunning: true)
        XCTAssertTrue(failedDirection.anyFeatureEnabled)
        XCTAssertFalse(failedDirection.allEnabledFeaturesActive)
        XCTAssertEqual(failedDirection.overallAccessibilityState, "prüfen")

        let failedAutoScroll = status(directionRunning: true, autoScrollEnabled: true, autoScrollRunning: false)
        XCTAssertFalse(failedAutoScroll.allEnabledFeaturesActive)

        let bothRunning = status(directionRunning: true, autoScrollEnabled: true, autoScrollRunning: true)
        XCTAssertTrue(bothRunning.allEnabledFeaturesActive)
        XCTAssertEqual(bothRunning.overallAccessibilityState, "aktiv")

        let autoScrollOnly = status(directionEnabled: false, autoScrollEnabled: true, autoScrollRunning: true)
        XCTAssertTrue(autoScrollOnly.allEnabledFeaturesActive)

        let allOff = status(directionEnabled: false)
        XCTAssertFalse(allOff.anyFeatureEnabled)
        XCTAssertFalse(allOff.allEnabledFeaturesActive)
        XCTAssertEqual(allOff.overallAccessibilityState, "nicht aktiv")
    }

    func testFailureDetailShowsWorkerIssue() {
        let failure = status(directionIssue: "Der Scrollfilter-Thread konnte nicht starten.")
        XCTAssertEqual(failure.directionHeadline, "Filter prüfen")
        XCTAssertEqual(failure.directionDetail, "Der Scrollfilter-Thread konnte nicht starten.")

        let denied = status(directionIssue: "macOS hat den Scrollfilter abgewiesen.", permissionGranted: false)
        XCTAssertEqual(denied.directionDetail, "macOS hat den Scrollfilter abgewiesen.")
    }

    func testStartingAndUserPauseRetainTheirSpecificMessages() {
        let starting = status(directionStarting: true, directionIssue: "Alter Fehler")
        XCTAssertEqual(starting.directionHeadline, "Filter startet")
        XCTAssertEqual(starting.directionDetail, "macOS startet den Scrollfilter.")

        let paused = status(directionPausedByUserInput: true, directionIssue: "Alter Fehler")
        XCTAssertEqual(paused.directionHeadline, "Filter pausiert")
        XCTAssertTrue(paused.directionDetail.contains("Erneut prüfen"))
    }

    private func status(
        directionEnabled: Bool = true,
        directionRunning: Bool = false,
        directionStarting: Bool = false,
        directionPausedByUserInput: Bool = false,
        directionIssue: String? = nil,
        permissionGranted: Bool = true,
        autoScrollEnabled: Bool = false,
        autoScrollRunning: Bool = false
    ) -> ScrollFixStatusSnapshot {
        .init(
            directionEnabled: directionEnabled,
            directionRunning: directionRunning,
            directionStarting: directionStarting,
            directionPausedByUserInput: directionPausedByUserInput,
            directionIssue: directionIssue,
            permissionGranted: permissionGranted,
            autoScrollEnabled: autoScrollEnabled,
            autoScrollRunning: autoScrollRunning
        )
    }
}

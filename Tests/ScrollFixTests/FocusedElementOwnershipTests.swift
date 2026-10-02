import XCTest
@testable import ScrollFix

final class FocusedElementOwnershipTests: XCTestCase {
    func testSameLiveProcessAccepted() {
        XCTAssertTrue(FocusedElementOwnership.accepts(expectedPID: 42, elementPID: 42))
    }

    func testAnotherAppRejected() {
        XCTAssertFalse(FocusedElementOwnership.accepts(expectedPID: 42, elementPID: 43))
    }

    func testInvalidIdentitiesRejectedEvenWhenEqual() {
        for invalid in [Int32(-1), 0] {
            XCTAssertFalse(FocusedElementOwnership.accepts(expectedPID: invalid, elementPID: invalid))
            XCTAssertFalse(FocusedElementOwnership.accepts(expectedPID: 42, elementPID: invalid))
            XCTAssertFalse(FocusedElementOwnership.accepts(expectedPID: invalid, elementPID: 42))
        }
    }
}

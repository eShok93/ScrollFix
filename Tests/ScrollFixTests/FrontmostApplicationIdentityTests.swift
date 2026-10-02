import XCTest
@testable import ScrollFix

final class FrontmostApplicationIdentityTests: XCTestCase {
    func testValidWorkspacePIDKeepsExistingRoute() {
        XCTAssertEqual(FrontmostApplicationIdentity.resolve(workspacePID: 42, focusedPID: 0,
            expectedExecutable: nil, actualExecutable: nil), 42)
    }

    func testMissingWorkspacePIDRequiresMatchingFocusedExecutable() {
        for invalid in [Int32(-1), 0] {
            XCTAssertEqual(FrontmostApplicationIdentity.resolve(workspacePID: invalid, focusedPID: 71,
                expectedExecutable: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
                actualExecutable: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"), 71)
        }
    }

    func testDifferentProcessCannotBeSubstituted() {
        XCTAssertNil(FrontmostApplicationIdentity.resolve(workspacePID: -1, focusedPID: 71,
            expectedExecutable: "/TextEdit", actualExecutable: "/OtherApp"))
    }

    func testMissingIdentityFailsClosed() {
        for pid in [Int32(-1), 0] {
            XCTAssertNil(FrontmostApplicationIdentity.resolve(workspacePID: -1, focusedPID: pid,
                expectedExecutable: "/TextEdit", actualExecutable: "/TextEdit"))
        }
        for missing in [String?.none, ""] {
            XCTAssertNil(FrontmostApplicationIdentity.resolve(workspacePID: -1, focusedPID: 71,
                expectedExecutable: missing, actualExecutable: "/TextEdit"))
            XCTAssertNil(FrontmostApplicationIdentity.resolve(workspacePID: -1, focusedPID: 71,
                expectedExecutable: "/TextEdit", actualExecutable: missing))
        }
    }
}

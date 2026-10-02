import Foundation
import XCTest
@testable import ScrollFix

final class ScrollEventAccessTests: XCTestCase {
    @MainActor
    func testDetachedCheckReturnsGrantedResultOnCallingThread() {
        XCTAssertTrue(ScrollEventAccess.evaluate { Thread.isMainThread })
    }

    @MainActor
    func testDetachedCheckPreservesDeniedResult() {
        XCTAssertFalse(ScrollEventAccess.evaluate { false })
    }
}

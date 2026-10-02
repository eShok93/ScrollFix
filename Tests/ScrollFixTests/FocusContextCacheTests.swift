import XCTest
@testable import ScrollFix

final class FocusContextCacheTests: XCTestCase {
    private let text = InputContext(bundleID: "com.apple.Safari", processID: 42, focus: .text)

    func testAXQueryStartedBeforeClickCannotRestoreTextFocus() {
        var cache = FocusContextCache()
        XCTAssertTrue(cache.update(.init(context: text, sampleStartedAt: 100)))
        cache.invalidate(at: 200)
        XCTAssertEqual(cache.context.focus, .transitioning)
        XCTAssertFalse(cache.update(.init(context: text, sampleStartedAt: 150)))
        XCTAssertFalse(cache.update(.init(context: text, sampleStartedAt: 200)))
        XCTAssertEqual(cache.context.focus, .transitioning)
        var page = text; page.focus = .other
        XCTAssertTrue(cache.update(.init(context: page, sampleStartedAt: 201)))
        XCTAssertEqual(cache.context.focus, .other)
        XCTAssertFalse(cache.update(.init(context: text, sampleStartedAt: 150)))
        XCTAssertEqual(cache.context.focus, .other)
    }

    func testAllowedAppCannotOverrideFocusTransition() {
        var cache = FocusContextCache()
        _ = cache.update(.init(context: text, sampleStartedAt: 100))
        cache.invalidate(at: 200)
        var settings = HomeEndSettings(); settings.allowedApps.insert(text.bundleID)
        XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(
            .init(kind: .down, keyCode: 115), context: cache.context), .passThrough)
    }

    func testOrderedSamplesAndSecureState() {
        var cache = FocusContextCache()
        _ = cache.update(.init(context: text, sampleStartedAt: 300))
        var stale = text; stale.focus = .other
        XCTAssertFalse(cache.update(.init(context: stale, sampleStartedAt: 299)))
        cache.setSecureInput(true)
        XCTAssertTrue(cache.context.secureInput)
        cache.invalidate(at: 400)
        cache.invalidate(at: 350)
        XCTAssertFalse(cache.update(.init(context: text, sampleStartedAt: 390)))
        XCTAssertTrue(cache.context.secureInput)
        XCTAssertTrue(cache.update(.init(context: text, sampleStartedAt: 401)))
        XCTAssertFalse(cache.context.secureInput)
    }
}

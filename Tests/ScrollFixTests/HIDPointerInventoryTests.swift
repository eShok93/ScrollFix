import CoreGraphics
import XCTest
@testable import ScrollFix

final class HIDPointerInventoryTests: XCTestCase {
    private let mouse = HIDPointerRecord.Usage(page: 1, value: 2)
    private let pointer = HIDPointerRecord.Usage(page: 1, value: 1)
    private let touchPad = HIDPointerRecord.Usage(page: 13, value: 5)

    func testCompositeDeviceUsesSecondaryTouchPadPair() {
        let pairs: [[String: Any]] = [
            ["DeviceUsagePage": 1, "DeviceUsage": 2],
            ["DeviceUsagePage": 13, "DeviceUsage": 5]
        ]
        XCTAssertEqual(HIDPointerRecord.usages(pairs: pairs, primaryPage: 1, primaryUsage: 2), [mouse, touchPad])
        XCTAssertEqual(HIDPointerRecord.usages(pairs: nil, primaryPage: 1, primaryUsage: 2), [mouse])
    }

    func testOnlyOneNonVirtualBuiltInTrackpadQualifies() {
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            record(1, true, false, [mouse, pointer, touchPad])
        ]), .internalTrackpadOnly)
        // macOS need not publish HIDVirtualDevice for real internal hardware.
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            record(1, true, nil, [mouse, touchPad])
        ]), .internalTrackpadOnly)
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            record(1, true, true, [mouse, touchPad])
        ]), .unknown)
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            record(1, true, false, [mouse])
        ]), .unknown)
    }

    func testExternalMousePointerOrTouchPadDisablesFastPath() {
        let internalTrackpad = record(1, true, false, [mouse, touchPad])
        for externalUsage in [mouse, pointer, touchPad] {
            XCTAssertEqual(HIDPointerInventoryProbe.classify([
                internalTrackpad, record(2, false, false, [externalUsage])
            ]), .externalPointerPresent)
        }
    }

    func testMissingBuiltInOrAdditionalInternalPointerIsUnknown() {
        let internalTrackpad = record(1, true, false, [mouse, touchPad])
        XCTAssertEqual(HIDPointerInventoryProbe.classify([]), .unknown)
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            internalTrackpad, record(2, nil, false, [mouse])
        ]), .unknown)
        XCTAssertEqual(HIDPointerInventoryProbe.classify([
            internalTrackpad, record(2, true, false, [pointer])
        ]), .unknown)
    }

    func testSnapshotPreservesRegistryIDToDeviceCategory() {
        let snapshot = HIDPointerInventorySnapshot(records: [
            record(11, true, nil, [mouse, touchPad]),
            record(22, false, false, [mouse]),
            record(33, true, false, [.init(page: 1, value: 6)])
        ])
        XCTAssertEqual(snapshot.category(for: 11), .internalTrackpad)
        XCTAssertEqual(snapshot.category(for: 22), .externalPointingInterface)
        XCTAssertEqual(snapshot.category(for: 33), .otherOrUnknown)
        XCTAssertNil(snapshot.category(for: 44))
        XCTAssertEqual(snapshot.state, .externalPointerPresent)
    }

    func testRetryBackoffCapsAtThirtySecondsAndResetsAfterSuccess() {
        var retry = HIDPointerInventoryRetry()
        var now: TimeInterval = 100
        for expectedDelay: TimeInterval in [1.5, 3, 6, 12, 24, 30, 30] {
            retry.recordFailure(at: now)
            XCTAssertEqual(retry.nextAttemptUptime, now + expectedDelay)
            XCTAssertFalse(retry.isDue(at: now + expectedDelay - 0.01))
            XCTAssertTrue(retry.isDue(at: now + expectedDelay))
            now += expectedDelay
            retry.beginAttempt()
        }
        retry.reset()
        XCTAssertNil(retry.nextAttemptUptime)
        XCTAssertEqual(retry.nextDelay, 1.5)
        retry.recordFailure(at: now)
        XCTAssertEqual(retry.nextAttemptUptime, now + 1.5)
    }

    func testNotificationFailureDoesNotPostponePendingRetry() {
        var retry = HIDPointerInventoryRetry()
        retry.recordFailure(at: 10)
        retry.recordFailure(at: 11)
        XCTAssertEqual(retry.nextAttemptUptime, 11.5)
        XCTAssertEqual(retry.nextDelay, 3)
        retry.beginAttempt()
        retry.recordFailure(at: 12)
        XCTAssertEqual(retry.nextAttemptUptime, 15)
    }

    @MainActor
    func testSuccessfulServiceChangeKeepsTrackpadPolicyAndPhaseFreeDirection() throws {
        let internalTrackpad = HIDPointerInventorySnapshot(records: [
            record(1, true, false, [mouse, touchPad])
        ])
        let monitor = HIDPointerInventoryMonitor(
            snapshotProvider: { internalTrackpad }, observeServices: false
        )
        let engine = ScrollEventEngine(reverseTouchSurface: true)
        var states: [HIDPointerInventoryState] = []
        monitor.onChange = { state in
            states.append(state)
            engine.setTrackpadOnlyEligible(state == .internalTrackpadOnly, at: UInt64(states.count))
        }

        monitor.start()
        XCTAssertEqual(states, [.internalTrackpadOnly])
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)

        // This exercises the same method as an IOKit arrival or removal
        // callback, with a stable inventory and no hardware dependency.
        monitor.serviceDidChange()
        XCTAssertEqual(states, [.internalTrackpadOnly])
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let phaseFree = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
            wheel1: 4, wheel2: 0, wheel3: 0
        ))
        _ = engine.rewriteWheelEvent(phaseFree, at: 3)
        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(phaseFree.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)
    }

    @MainActor
    func testServiceChangePublishesExternalPointerAndEnumerationFailure() {
        let internalTrackpad = HIDPointerInventorySnapshot(records: [
            record(1, true, false, [mouse, touchPad])
        ])
        let withExternal = HIDPointerInventorySnapshot(records: [
            record(1, true, false, [mouse, touchPad]),
            record(2, false, false, [mouse])
        ])
        let source = SnapshotSource(.success(internalTrackpad))
        let monitor = HIDPointerInventoryMonitor(
            snapshotProvider: source.snapshot, observeServices: false
        )
        let engine = ScrollEventEngine()
        var states: [HIDPointerInventoryState] = []
        monitor.onChange = { state in
            states.append(state)
            engine.setTrackpadOnlyEligible(state == .internalTrackpadOnly, at: UInt64(states.count))
        }

        monitor.start()
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)

        source.result = .success(withExternal)
        monitor.serviceDidChange()
        XCTAssertEqual(monitor.state, .externalPointerPresent)
        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)

        source.result = .success(internalTrackpad)
        monitor.serviceDidChange()
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)

        source.result = .failure(NSError(domain: "HIDPointerInventoryTests", code: 1))
        monitor.serviceDidChange()
        XCTAssertNil(monitor.snapshot)
        XCTAssertEqual(monitor.state, .unknown)
        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(states, [
            .internalTrackpadOnly, .externalPointerPresent,
            .internalTrackpadOnly, .unknown
        ])
    }

    private func record(_ id: UInt64, _ builtIn: Bool?, _ virtual: Bool?,
                        _ usages: Set<HIDPointerRecord.Usage>) -> HIDPointerRecord {
        .init(registryID: id, builtIn: builtIn, virtual: virtual, usages: usages)
    }

    @MainActor
    private final class SnapshotSource {
        var result: Result<HIDPointerInventorySnapshot, Error>

        init(_ result: Result<HIDPointerInventorySnapshot, Error>) {
            self.result = result
        }

        func snapshot() throws -> HIDPointerInventorySnapshot {
            try result.get()
        }
    }
}

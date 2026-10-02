import Foundation
import XCTest
@testable import ScrollFix

final class ScrollEventTapWorkerTests: XCTestCase {
    func testSnapshotGateRejectsReorderedAndOldLifecycleUpdates() {
        var gate = ScrollEventSnapshotGate()
        XCTAssertTrue(gate.accepts(snapshot(sequence: 3, generation: 8), generation: 8))
        XCTAssertFalse(gate.accepts(snapshot(sequence: 2, generation: 8), generation: 8))
        XCTAssertFalse(gate.accepts(snapshot(sequence: 4, generation: 7), generation: 8))
        XCTAssertTrue(gate.accepts(snapshot(sequence: 5, generation: 8), generation: 8))
        gate.reset()
        XCTAssertTrue(gate.accepts(snapshot(sequence: 1, generation: 9), generation: 9))
    }

    func testBootstrapFailureRepliesEvenWhenStartArrivesAfterThreadExits() {
        let arrived = expectation(description: "terminal failure")
        let probe = SnapshotProbe(expectedGeneration: 23, expectation: arrived)
        let worker = ScrollEventTapWorker(
            reverseTouchSurface: true,
            collectDirectionTrace: false,
            simulateBootstrapFailureForTesting: true
        ) { snapshot in
            probe.record(snapshot, onMainThread: Thread.isMainThread)
        }
        XCTAssertTrue(worker.waitForShutdownForTesting(timeout: .now() + 2))
        worker.enqueue(.start(generation: 23, reverseTouchSurface: true))
        wait(for: [arrived], timeout: 2)

        let observed = probe.observed?.snapshot
        XCTAssertEqual(observed?.generation, 23)
        XCTAssertEqual(observed?.isRunning, false)
        XCTAssertEqual(observed?.isTerminal, true)
        XCTAssertNotNil(observed?.issue)
    }

    func testMailboxPublishesValuesFromDedicatedThreadWithoutCreatingTap() {
        let arrived = expectation(description: "worker snapshot")
        let probe = SnapshotProbe(expectedGeneration: 17, expectation: arrived)
        let worker = ScrollEventTapWorker(reverseTouchSurface: true, collectDirectionTrace: true) { snapshot in
            probe.record(snapshot, onMainThread: Thread.isMainThread)
        }

        worker.enqueue(.setTrackpadOnlyEligible(true, at: 1))
        worker.enqueue(.snapshot(generation: 17))
        wait(for: [arrived], timeout: 2)

        let observed = probe.observed
        XCTAssertEqual(observed?.snapshot.generation, 17)
        XCTAssertEqual(observed?.snapshot.usingTrackpadOnlyFastPath, true)
        XCTAssertEqual(observed?.snapshot.isRunning, false)
        XCTAssertEqual(observed?.snapshot.tapTimeoutCount, 0)
        XCTAssertEqual(observed?.snapshot.maxCallbackDurationNanoseconds, 0)
        XCTAssertEqual(observed?.onMainThread, false)
        worker.shutdown()
        XCTAssertTrue(worker.waitForShutdownForTesting(timeout: .now() + 2))
    }

    func testMailboxOrdersPolicyChangeAfterStopWithoutCreatingTap() {
        let arrived = expectation(description: "post-stop snapshot")
        let probe = SnapshotProbe(expectedGeneration: 9, expectation: arrived)
        let worker = ScrollEventTapWorker(reverseTouchSurface: false, collectDirectionTrace: false) { snapshot in
            probe.record(snapshot, onMainThread: Thread.isMainThread)
        }

        worker.enqueue(.setTrackpadOnlyEligible(true, at: 1))
        worker.enqueue(.stop(generation: 8))
        worker.enqueue(.setTrackpadOnlyEligible(false, at: 2))
        worker.enqueue(.snapshot(generation: 9))
        wait(for: [arrived], timeout: 2)

        let observed = probe.observed?.snapshot
        XCTAssertEqual(observed?.generation, 9)
        XCTAssertEqual(observed?.usingTrackpadOnlyFastPath, false)
        XCTAssertEqual(observed?.isRunning, false)
        XCTAssertNil(observed?.issue)
        worker.shutdown()
        XCTAssertTrue(worker.waitForShutdownForTesting(timeout: .now() + 2))
    }

    func testExplicitStopClearsDirectionTraceWithoutCreatingTap() {
        let beforeStop = expectation(description: "reset remains visible before stop")
        let afterStop = expectation(description: "cleared post-stop snapshot")
        let beforeProbe = SnapshotProbe(expectedGeneration: 0, expectation: beforeStop)
        let afterProbe = SnapshotProbe(expectedGeneration: 8, expectation: afterStop)
        let worker = ScrollEventTapWorker(reverseTouchSurface: false, collectDirectionTrace: true) { snapshot in
            beforeProbe.record(snapshot, onMainThread: Thread.isMainThread)
            afterProbe.record(snapshot, onMainThread: Thread.isMainThread)
        }

        worker.enqueue(.resetClassification(.tapTimeout))
        wait(for: [beforeStop], timeout: 2)
        XCTAssertEqual(beforeProbe.observed?.snapshot.directionRecords, [.reset(.tapTimeout)])

        worker.enqueue(.stop(generation: 8))
        wait(for: [afterStop], timeout: 2)

        let observed = afterProbe.observed?.snapshot
        XCTAssertTrue(observed?.directionRecords.isEmpty == true)
        XCTAssertEqual(observed?.tapTimeoutCount, 0)
        XCTAssertEqual(observed?.maxCallbackDurationNanoseconds, 0)
        XCTAssertEqual(observed?.isRunning, false)
        worker.shutdown()
        XCTAssertTrue(worker.waitForShutdownForTesting(timeout: .now() + 2))
    }

    func testDiagnosticCountersResetForNewSession() {
        var counters = ScrollTapDiagnosticCounters()
        counters.recordTimeout()
        counters.recordTimeout()
        counters.recordCallbackDuration(45_000)
        counters.recordCallbackDuration(12_000)
        XCTAssertEqual(counters.tapTimeoutCount, 2)
        XCTAssertEqual(counters.maxCallbackDurationNanoseconds, 45_000)

        counters.reset()
        XCTAssertEqual(counters.tapTimeoutCount, 0)
        XCTAssertEqual(counters.maxCallbackDurationNanoseconds, 0)
    }

    private func snapshot(sequence: UInt64, generation: UInt64) -> ScrollEventTapWorker.Snapshot {
        .init(
            sequence: sequence, generation: generation, isRunning: false,
            isPausedByUserInput: false, isTerminal: false, issue: nil,
            usingTrackpadOnlyFastPath: false, lastDecision: nil,
            directionRecords: [], tapTimeoutCount: 0,
            maxCallbackDurationNanoseconds: 0
        )
    }
}

private final class SnapshotProbe: @unchecked Sendable {
    struct Observation {
        let snapshot: ScrollEventTapWorker.Snapshot
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private let expectedGeneration: UInt64
    private let expectation: XCTestExpectation
    private var stored: Observation?

    init(expectedGeneration: UInt64, expectation: XCTestExpectation) {
        self.expectedGeneration = expectedGeneration
        self.expectation = expectation
    }

    func record(_ snapshot: ScrollEventTapWorker.Snapshot, onMainThread: Bool) {
        guard snapshot.generation == expectedGeneration else { return }
        lock.lock()
        stored = Observation(snapshot: snapshot, onMainThread: onMainThread)
        lock.unlock()
        expectation.fulfill()
    }

    var observed: Observation? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

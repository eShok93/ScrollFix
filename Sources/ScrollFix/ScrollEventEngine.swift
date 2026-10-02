@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// Applies only the newest snapshot from the current tap lifecycle.
struct ScrollEventSnapshotGate {
    private(set) var lastSequence: UInt64 = 0

    mutating func accepts(
        _ snapshot: ScrollEventTapWorker.Snapshot, generation: UInt64
    ) -> Bool {
        guard snapshot.generation == generation,
              snapshot.sequence > lastSequence else { return false }
        lastSequence = snapshot.sequence
        return true
    }

    mutating func reset() { lastSequence = 0 }
}

/// Makes trackpad scrolling natural and discrete mouse-wheel scrolling classic.
@MainActor
final class ScrollEventEngine {
    /// Called on the MainActor after a worker snapshot has been applied.
    var onRunningChange: (@MainActor (Bool, String?) -> Void)?
    private(set) var lastDecision: ScrollSourceClassifier.Decision?
    private(set) var isPausedByUserInput = false

    private let collectDirectionTrace: Bool
    private var offlineRewriter: ScrollWheelRewriter
    private var worker: ScrollEventTapWorker?
    private var workerEpoch: UInt64 = 0
    private var snapshotGate = ScrollEventSnapshotGate()
    private var reverseTouchSurface: Bool
    private var generation: UInt64 = 0
    private var desiredRunning = false
    private var starting = false
    private var running = false
    private var usingFastPath = false
    private var trackpadOnlyEligible = false
    private var directionRecords: [ScrollDirectionTrace.Record] = []
    private var wheelConfiguration = MouseWheelConfiguration()
    private let offlineWheel: MouseWheelPipeline
    private(set) var wheelSamples: [MouseWheelSample] = []
    private(set) var wheelPostedFrames: UInt64 = 0
    private(set) var wheelMaxTickGapNanoseconds: UInt64 = 0
    private(set) var wheelFrameClock: MouseWheelFrameClockKind = .idle
    private(set) var tapTimeoutCount: UInt64 = 0
    private(set) var maxCallbackDurationNanoseconds: UInt64 = 0

    init(reverseTouchSurface: Bool = false, collectDirectionTrace: Bool = false) {
        self.reverseTouchSurface = reverseTouchSurface
        self.collectDirectionTrace = collectDirectionTrace
        offlineWheel = MouseWheelPipeline(collectDiagnostics: collectDirectionTrace)
        offlineRewriter = ScrollWheelRewriter(
            reverseTouchSurface: reverseTouchSurface,
            collectDirectionTrace: collectDirectionTrace
        )
    }

    isolated deinit {
        worker?.shutdown()
    }

    var recentDirectionRecords: [ScrollDirectionTrace.Record] { directionRecords }
    /// Last worker-confirmed state; it changes asynchronously after start/stop.
    var isRunning: Bool { running }
    var isStarting: Bool { starting }
    var usingTrackpadOnlyFastPath: Bool { usingFastPath }

    func setTrackpadOnlyEligible(
        _ eligible: Bool, at monotonicTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        trackpadOnlyEligible = eligible
        offlineRewriter.setTrackpadOnlyEligible(eligible, at: monotonicTime)
        if let worker {
            worker.enqueue(.setTrackpadOnlyEligible(eligible, at: monotonicTime))
        } else {
            usingFastPath = offlineRewriter.trackpadOnlyFastPath.selected
            lastDecision = offlineRewriter.lastDecision
        }
    }

    func configureWheel(_ configuration: MouseWheelConfiguration) {
        guard wheelConfiguration != configuration else { return }
        wheelConfiguration = configuration
        offlineWheel.configure(configuration)
        worker?.enqueue(.setWheelConfiguration(configuration))
    }

    func cancelWheelMotion() {
        offlineWheel.cancel()
        worker?.enqueue(.cancelWheelMotion)
    }

    func refreshWheelFrameClock() { worker?.enqueue(.refreshWheelFrameClock) }

    func start(reverseTouchSurface: Bool) {
        let changedReverse = self.reverseTouchSurface != reverseTouchSurface
        self.reverseTouchSurface = reverseTouchSurface
        offlineRewriter.reverseTouchSurface = reverseTouchSurface
        guard !isPausedByUserInput else { return }

        if !desiredRunning {
            desiredRunning = true
            generation &+= 1
            starting = true
            running = false
            directionRecords = []
            tapTimeoutCount = 0
            maxCallbackDurationNanoseconds = 0
            makeWorker().enqueue(.start(
                generation: generation, reverseTouchSurface: reverseTouchSurface
            ))
            return
        }

        if changedReverse {
            worker?.enqueue(.setReverseTouchSurface(reverseTouchSurface))
        }
        if starting { return }
        if running {
            worker?.enqueue(.verify(generation: generation))
        } else {
            starting = true
            makeWorker().enqueue(.start(
                generation: generation, reverseTouchSurface: reverseTouchSurface
            ))
        }
    }

    /// A periodic check runs on the worker thread, never from the UI thread.
    func verify() {
        guard desiredRunning, !isPausedByUserInput else { return }
        worker?.enqueue(.verify(generation: generation))
    }

    func rebuild() {
        let shouldReverseTouchSurface = reverseTouchSurface
        stop()
        start(reverseTouchSurface: shouldReverseTouchSurface)
    }

    func resetClassification(reason: ScrollDirectionTrace.ResetReason = .classifier) {
        offlineWheel.cancel()
        offlineRewriter.resetClassification(reason: reason)
        lastDecision = nil
        if let worker {
            worker.enqueue(.resetClassification(reason))
        } else {
            usingFastPath = offlineRewriter.trackpadOnlyFastPath.selected
            directionRecords = offlineRewriter.recentDirectionRecords
        }
    }

    func resumeAfterUserInputDisable() {
        // A disable callback can still be in transit when the user toggles the
        // feature. Send resume even if the last main-thread snapshot missed it.
        isPausedByUserInput = false
        worker?.enqueue(.resumeAfterUserInputDisable)
    }

    func stop() {
        guard desiredRunning || starting || running else { return }
        desiredRunning = false
        generation &+= 1
        starting = false
        running = false
        lastDecision = nil
        directionRecords = []
        tapTimeoutCount = 0
        maxCallbackDurationNanoseconds = 0
        offlineWheel.cancel(clearDiagnostics: true)
        wheelSamples = []
        wheelPostedFrames = 0
        wheelMaxTickGapNanoseconds = 0
        wheelFrameClock = .idle
        worker?.enqueue(.stop(generation: generation))
    }

    func shutdown() {
        generation &+= 1
        workerEpoch &+= 1
        snapshotGate.reset()
        desiredRunning = false
        starting = false
        running = false
        worker?.shutdown()
        worker = nil
    }

    /// Offline regression hook. The live event tap exclusively uses its own
    /// rewriter on the worker thread; no CGEvent crosses the thread boundary.
    func rewriteWheelEvent(
        _ event: CGEvent, at monotonicTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> CGEvent? {
        let result = offlineRewriter.rewriteWheelEvent(event, at: monotonicTime)
        let output = offlineWheel.process(result, source: offlineRewriter.lastDecision?.source, at: monotonicTime)
        if worker == nil {
            lastDecision = offlineRewriter.lastDecision
            usingFastPath = offlineRewriter.trackpadOnlyFastPath.selected
            directionRecords = offlineRewriter.recentDirectionRecords
            wheelSamples = offlineWheel.samples
        }
        return output
    }

    private func makeWorker() -> ScrollEventTapWorker {
        if let worker { return worker }
        workerEpoch &+= 1
        let epoch = workerEpoch
        snapshotGate.reset()
        let worker = ScrollEventTapWorker(
            reverseTouchSurface: reverseTouchSurface,
            collectDirectionTrace: collectDirectionTrace
        ) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.applySnapshot(snapshot, from: epoch)
            }
        }
        self.worker = worker
        worker.enqueue(.setWheelConfiguration(wheelConfiguration))
        // Inventory can report the sole internal trackpad before the first
        // start. Apply that policy before any live event reaches the new tap.
        worker.enqueue(.setTrackpadOnlyEligible(
            trackpadOnlyEligible, at: DispatchTime.now().uptimeNanoseconds
        ))
        return worker
    }

    private func applySnapshot(_ snapshot: ScrollEventTapWorker.Snapshot, from epoch: UInt64) {
        guard epoch == workerEpoch,
              snapshotGate.accepts(snapshot, generation: generation) else { return }
        starting = false
        running = snapshot.isRunning
        isPausedByUserInput = snapshot.isPausedByUserInput
        usingFastPath = snapshot.usingTrackpadOnlyFastPath
        lastDecision = snapshot.lastDecision
        directionRecords = snapshot.directionRecords
        tapTimeoutCount = snapshot.tapTimeoutCount
        maxCallbackDurationNanoseconds = snapshot.maxCallbackDurationNanoseconds
        wheelSamples = snapshot.wheelSamples
        wheelPostedFrames = snapshot.wheelPostedFrames
        wheelMaxTickGapNanoseconds = snapshot.wheelMaxTickGapNanoseconds
        wheelFrameClock = snapshot.wheelFrameClock
        if snapshot.isTerminal { worker = nil }
        onRunningChange?(running, snapshot.issue)
    }
}

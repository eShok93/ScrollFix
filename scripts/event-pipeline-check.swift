import AppKit
import CoreGraphics
import Dispatch
import Foundation

/// An offline check of the fields emitted by autoscroll and the direction
/// filter's loop guard. It does not post an event or install an event tap.
@main
struct EventPipelineCheck {
    @MainActor
    static func main() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fatalError("Could not create a Quartz event source")
        }
        source.localEventsSuppressionInterval = 0

        var physics = AutoScrollPhysics()
        guard let delta = physics.tick(
            offset: CGVector(dx: 80, dy: -50), elapsedSeconds: 0.016
        ) else {
            fatalError("Physics did not produce a delta")
        }
        precondition(delta == .init(vertical: -8, horizontal: -13))

        let now = DispatchTime.now().uptimeNanoseconds
        guard let synthetic = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: delta.vertical,
            wheel2: delta.horizontal,
            wheel3: 0
        ) else {
            fatalError("Could not create a Quartz scroll event")
        }
        synthetic.timestamp = now
        synthetic.location = CGPoint(x: -200, y: -300)
        synthetic.setIntegerValueField(
            .eventSourceUserData,
            value: ScrollFixSyntheticEvent.autoScrollMarker
        )

        guard let bridged = NSEvent(cgEvent: synthetic),
              let emittedSource = CGEventSource(event: synthetic) else {
            fatalError("Could not inspect the scroll event")
        }
        precondition(emittedSource.sourceStateID == .combinedSessionState)
        precondition(emittedSource.localEventsSuppressionInterval == 0)
        precondition(synthetic.timestamp == now)
        precondition(synthetic.location == CGPoint(x: -200, y: -300))
        precondition(synthetic.getIntegerValueField(.eventSourceUserData) == ScrollFixSyntheticEvent.autoScrollMarker)
        precondition(bridged.hasPreciseScrollingDeltas)
        precondition(bridged.scrollingDeltaY == CGFloat(delta.vertical))
        precondition(bridged.scrollingDeltaX == CGFloat(delta.horizontal))

        var engine = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: false)
        let before = synthetic.data as Data?
        let passed = engine.rewriteWheelEvent(synthetic)
        precondition(passed === synthetic)
        precondition((passed.data as Data?) == before)
        precondition(engine.lastDecision == nil)

        guard let ordinaryWheel = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: delta.vertical,
            wheel2: delta.horizontal,
            wheel3: 0
        ) else {
            fatalError("Could not create a comparison scroll event")
        }
        ordinaryWheel.flags = [.maskShift, .maskCommand]
        ordinaryWheel.timestamp = now
        ordinaryWheel.location = CGPoint(x: -200, y: -300)
        ordinaryWheel.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: -0.5)
        ordinaryWheel.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: -8.5)
        ordinaryWheel.setDoubleValueField(.scrollWheelEventRawDeltaAxis2, value: 2.5)
        ordinaryWheel.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2, value: 13.5)
        let verticalPointsBefore = ordinaryWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let horizontalPointsBefore = ordinaryWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        _ = engine.rewriteWheelEvent(ordinaryWheel)
        precondition(engine.lastDecision?.source == .mouseWheel)
        precondition(ordinaryWheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -Int64(delta.vertical))
        precondition(ordinaryWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -verticalPointsBefore)
        precondition(ordinaryWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == horizontalPointsBefore)
        precondition(ordinaryWheel.getDoubleValueField(.scrollWheelEventRawDeltaAxis1) == 0.5)
        precondition(ordinaryWheel.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1) == 8.5)
        precondition(ordinaryWheel.getDoubleValueField(.scrollWheelEventRawDeltaAxis2) == 2.5)
        precondition(ordinaryWheel.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2) == 13.5)
        precondition(ordinaryWheel.flags == [.maskShift, .maskCommand])
        precondition(ordinaryWheel.timestamp == now)
        precondition(ordinaryWheel.location == CGPoint(x: -200, y: -300))

        // Pixel payloads can be produced by a high-resolution wheel or a
        // trackpad. The current policy preserves an unowned pixel event.
        // This checks preservation, not successful high-resolution wheel correction.
        guard let highResolutionWheel = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: 4,
            wheel2: 7,
            wheel3: 0
        ) else {
            fatalError("Could not create a high-resolution wheel event")
        }
        highResolutionWheel.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        highResolutionWheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 4)
        highResolutionWheel.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4.5)
        precondition(NSEvent(cgEvent: highResolutionWheel)?.scrollingDeltaY == 4)
        precondition(NSEvent(cgEvent: highResolutionWheel)?.scrollingDeltaX == 7)
        let pixelBefore = highResolutionWheel.data as Data?
        _ = engine.rewriteWheelEvent(highResolutionWheel)
        precondition(engine.lastDecision?.source == .unknown)
        precondition(highResolutionWheel.data as Data? == pixelBefore)
        precondition(highResolutionWheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
        precondition(highResolutionWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 4)
        precondition(highResolutionWheel.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == 4.5)
        precondition(highResolutionWheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 7)
        precondition(NSEvent(cgEvent: highResolutionWheel)?.scrollingDeltaY == 4)
        precondition(NSEvent(cgEvent: highResolutionWheel)?.scrollingDeltaX == 7)

        // A wheel tick can arrive between a trackpad's mayBegin and began.
        // It must be reversed without stealing the pending trackpad stream.
        var handoffEngine = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: false)
        func wheel(_ phase: Int64, units: CGScrollEventUnit = .pixel, at timestamp: UInt64) -> CGEvent {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: units,
                wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0
            ) else { fatalError("Could not create a handoff event") }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.timestamp = timestamp
            return event
        }
        let trackpadMayBegin = wheel(Int64(CGScrollPhase.mayBegin.rawValue), at: 1)
        _ = handoffEngine.rewriteWheelEvent(trackpadMayBegin)
        precondition(handoffEngine.lastDecision?.source == .trackpad)
        let interleavedWheel = wheel(0, units: .line, at: 2)
        _ = handoffEngine.rewriteWheelEvent(interleavedWheel)
        precondition(handoffEngine.lastDecision?.source == .mouseWheel)
        precondition(interleavedWheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -4)
        let trackpadBegan = wheel(Int64(CGScrollPhase.began.rawValue), at: 3_000_000_000)
        _ = handoffEngine.rewriteWheelEvent(trackpadBegan)
        precondition(handoffEngine.lastDecision?.source == .trackpad)
        precondition(trackpadBegan.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 4)

        var diagnostics = AutoScrollDiagnostics()
        diagnostics.recordTick(milliseconds: 16)
        diagnostics.recordTick(milliseconds: 41)
        diagnostics.recordTick(milliseconds: .nan)
        diagnostics.recordPosted(.init(vertical: 3, horizontal: -1))
        precondition(diagnostics.lastTickMilliseconds == 41)
        precondition(diagnostics.maxTickMilliseconds == 41)
        precondition(diagnostics.delayedTicks == 1)
        precondition(diagnostics.postedEvents == 1)
        precondition(diagnostics.lastPostedDelta == .init(vertical: 3, horizontal: -1))

        print("ScrollFix offline event pipeline check passed: line-wheel inversion, pixel preservation, synthetic guard and handoff. Pixel-wheel correction remains unresolved.")
    }
}

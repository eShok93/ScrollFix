import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import ScrollFix

final class ScrollEventEngineTests: XCTestCase {
    @MainActor
    func testSyntheticMarkerPassesThroughWithoutClassification() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let event = try wheel(source: source, vertical: 4, horizontal: 7)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollFixSyntheticEvent.autoScrollMarker)
        let original = event.data as Data?
        let engine = ScrollEventEngine()
        engine.setTrackpadOnlyEligible(true, at: 1)

        let result = try XCTUnwrap(engine.rewriteWheelEvent(event))

        XCTAssertTrue(result === event)
        XCTAssertEqual(result.data as Data?, original)
        XCTAssertNil(engine.lastDecision)
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)
    }

    @MainActor
    func testAmbiguousHighResolutionWheelPassesThroughWithNaturalBaseline() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let event = try wheel(source: source, vertical: 4, horizontal: 7)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4.5)
        // CoreGraphics recalculates the point delta when the line delta is
        // changed, so set the desired high-resolution point payload last.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 4)
        event.flags = [.maskShift, .maskCommand]
        event.timestamp = 42
        event.location = CGPoint(x: -200, y: -300)
        let horizontalPoint = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let horizontalFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let engine = ScrollEventEngine(collectDirectionTrace: true)
        XCTAssertNotEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 0)

        let result = try XCTUnwrap(engine.rewriteWheelEvent(event))

        XCTAssertTrue(result === event)
        XCTAssertEqual(engine.lastDecision?.source, .unknown)
        XCTAssertEqual(engine.lastDecision?.reason, .phaseFreePixel)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 4)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 4.5)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventAcceleratedDeltaAxis1), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventRawDeltaAxis1), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), horizontalPoint)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), horizontalFixed)
        XCTAssertEqual(event.flags, [.maskShift, .maskCommand])
        XCTAssertEqual(event.timestamp, 42)
        XCTAssertEqual(event.location, CGPoint(x: -200, y: -300))
        XCTAssertEqual(NSEvent(cgEvent: event)?.scrollingDeltaY, 4)
        XCTAssertEqual(NSEvent(cgEvent: event)?.scrollingDeltaX, 7)
        guard case let .scroll(sample)? = engine.recentDirectionRecords.last else {
            return XCTFail("Expected an ambiguity sample")
        }
        XCTAssertTrue(sample.isContinuous)
        XCTAssertEqual(sample.source, .unknown)
        XCTAssertFalse(sample.reversed)
    }

    @MainActor
    func testTrackpadDirectionRemainsConsistentAfterGesturePause() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)

        func send(_ phase: CGScrollPhase, at timestamp: UInt64, delta: Int32) throws -> CGEvent {
            let event = try wheel(source: source, vertical: delta, horizontal: 0)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.timestamp = timestamp
            return try XCTUnwrap(engine.rewriteWheelEvent(event))
        }

        _ = try send(.mayBegin, at: 1, delta: 0)
        let first = try send(.began, at: 2, delta: 4)
        XCTAssertEqual(first.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)

        let resumed = try send(.changed, at: 3_000_000_000, delta: 4)
        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(resumed.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)

        _ = try send(.ended, at: 3_000_000_001, delta: 0)
        let wheelTick = try wheel(source: source, vertical: 4, horizontal: 0, units: .line)
        wheelTick.timestamp = 3_000_000_002
        _ = engine.rewriteWheelEvent(wheelTick)
        XCTAssertEqual(engine.lastDecision?.source, .mouseWheel)
        XCTAssertEqual(wheelTick.getIntegerValueField(.scrollWheelEventDeltaAxis1), 4)
    }

    @MainActor
    func testTrackpadDirectionAfterLongRestBeforeGestureBegins() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)

        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue)
        )
        prelude.timestamp = 1
        _ = engine.rewriteWheelEvent(prelude)

        let began = try wheel(source: source, vertical: 4, horizontal: 0)
        began.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue)
        )
        began.timestamp = 10_000_000_000
        _ = engine.rewriteWheelEvent(began)

        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(began.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)
    }

    @MainActor
    func testPreciseTrackpadScrollKeepsVerticalFieldsAndAppKitDirectionAligned() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)

        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue)
        )
        _ = engine.rewriteWheelEvent(prelude)

        let gesture = try wheel(source: source, vertical: 4, horizontal: 7)
        gesture.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        gesture.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4.5)
        gesture.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 4)
        gesture.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue)
        )
        XCTAssertEqual(NSEvent(cgEvent: gesture)?.scrollingDeltaY, 4)
        XCTAssertEqual(NSEvent(cgEvent: gesture)?.scrollingDeltaX, 7)

        _ = engine.rewriteWheelEvent(gesture)

        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(gesture.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(gesture.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)
        XCTAssertEqual(gesture.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -4.5)
        XCTAssertEqual(NSEvent(cgEvent: gesture)?.scrollingDeltaY, -4)
        XCTAssertEqual(NSEvent(cgEvent: gesture)?.scrollingDeltaX, 7)
    }

    @MainActor
    func testOnlyTrackpadFastPathKeepsPhaseFreeInputConsistentWithNaturalBaseline() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        engine.setTrackpadOnlyEligible(true, at: 1)

        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
        _ = engine.rewriteWheelEvent(prelude, at: 2)
        let phaseFree = try wheel(source: source, vertical: 4, horizontal: 7)
        _ = engine.rewriteWheelEvent(phaseFree, at: 3)

        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(engine.lastDecision?.reason, .onlyInternalTrackpad)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaY, 4)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaX, 7)
    }

    @MainActor
    func testOnlyTrackpadFastPathInvertsPhaseFreeInputWithClassicBaseline() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)
        engine.setTrackpadOnlyEligible(true, at: 1)

        let phaseFree = try wheel(source: source, vertical: 4, horizontal: 7)
        _ = engine.rewriteWheelEvent(phaseFree, at: 2)

        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaY, -4)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaX, 7)
    }

    @MainActor
    func testOnlyTrackpadDirectionSurvivesClassifierReset() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)
        engine.setTrackpadOnlyEligible(true, at: 1)

        let first = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(first, at: 2)
        engine.resetClassification(reason: .tapTimeout)
        let continued = try wheel(source: source, vertical: 4, horizontal: 0)
        continued.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        _ = engine.rewriteWheelEvent(continued, at: 3)

        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(NSEvent(cgEvent: first)?.scrollingDeltaY, -4)
        XCTAssertEqual(NSEvent(cgEvent: continued)?.scrollingDeltaY, -4)
    }

    @MainActor
    func testPhaseFreePixelWithinTrackpadGestureKeepsDirection() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true)

        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
        prelude.timestamp = 1
        _ = engine.rewriteWheelEvent(prelude)

        let began = try wheel(source: source, vertical: 4, horizontal: 0)
        began.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        began.timestamp = 2
        _ = engine.rewriteWheelEvent(began)

        let missingPhase = try wheel(source: source, vertical: 4, horizontal: 0)
        missingPhase.timestamp = 3
        _ = engine.rewriteWheelEvent(missingPhase)

        XCTAssertEqual(engine.lastDecision?.source, .trackpad)
        XCTAssertEqual(engine.lastDecision?.reason, .trackpadContinuation)
        XCTAssertEqual(missingPhase.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)
        XCTAssertEqual(NSEvent(cgEvent: missingPhase)?.scrollingDeltaY, -4)
    }

    @MainActor
    func testExternalPointerLeavesPhaseFreePixelAmbiguous() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        engine.setTrackpadOnlyEligible(true, at: 1)
        engine.setTrackpadOnlyEligible(false, at: 2)

        let pixel = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(pixel, at: 3)

        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(engine.lastDecision?.source, .unknown)
        XCTAssertEqual(engine.lastDecision?.reason, .phaseFreePixel)
        XCTAssertEqual(NSEvent(cgEvent: pixel)?.scrollingDeltaY, 4)

        let lineWheel = try wheel(source: source, vertical: 4, horizontal: 0, units: .line)
        _ = engine.rewriteWheelEvent(lineWheel, at: 4)
        XCTAssertEqual(engine.lastDecision?.source, .mouseWheel)
        XCTAssertEqual(engine.lastDecision?.reason, .wheelTick)
        XCTAssertEqual(lineWheel.getIntegerValueField(.scrollWheelEventDeltaAxis1), -4)
    }

    @MainActor
    func testHotplugDefersPolicyUntilMomentumEnds() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        engine.setTrackpadOnlyEligible(true, at: 1)

        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
        _ = engine.rewriteWheelEvent(prelude, at: 2)
        engine.setTrackpadOnlyEligible(false, at: 3)

        let phaseFree = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(phaseFree, at: 4)
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaY, 4)

        let ended = try wheel(source: source, vertical: 0, horizontal: 0)
        ended.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
        _ = engine.rewriteWheelEvent(ended, at: 5)
        let momentum = try wheel(source: source, vertical: 4, horizontal: 0)
        momentum.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.begin.rawValue))
        _ = engine.rewriteWheelEvent(momentum, at: 6)
        XCTAssertEqual(NSEvent(cgEvent: momentum)?.scrollingDeltaY, 4)

        let momentumEnd = try wheel(source: source, vertical: 0, horizontal: 0)
        momentumEnd.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.end.rawValue))
        _ = engine.rewriteWheelEvent(momentumEnd, at: 7)
        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)

        let laterWheel = try wheel(source: source, vertical: 4, horizontal: 0, units: .line)
        _ = engine.rewriteWheelEvent(laterWheel, at: 8)
        XCTAssertEqual(engine.lastDecision?.source, .mouseWheel)
        XCTAssertEqual(NSEvent(cgEvent: laterWheel)?.scrollingDeltaY, -4)
    }

    @MainActor
    func testResetAdoptsPendingInventoryPolicy() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        engine.setTrackpadOnlyEligible(true, at: 1)
        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
        _ = engine.rewriteWheelEvent(prelude, at: 2)
        engine.setTrackpadOnlyEligible(false, at: 3)

        engine.resetClassification(reason: .tapTimeout)

        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)
        let phaseFree = try wheel(source: source, vertical: 4, horizontal: 0, units: .line)
        _ = engine.rewriteWheelEvent(phaseFree, at: 4)
        XCTAssertEqual(engine.lastDecision?.source, .mouseWheel)
        XCTAssertEqual(NSEvent(cgEvent: phaseFree)?.scrollingDeltaY, -4)
    }

    @MainActor
    func testPhaseFreeInputRemainsAmbiguousAfterInventoryQuietWindow() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        engine.setTrackpadOnlyEligible(true, at: 1)
        let first = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(first, at: 2)
        engine.setTrackpadOnlyEligible(false, at: 3)

        let second = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(second, at: 100_000_000)

        XCTAssertEqual(NSEvent(cgEvent: first)?.scrollingDeltaY, 4)
        XCTAssertEqual(NSEvent(cgEvent: second)?.scrollingDeltaY, 4)
        XCTAssertTrue(engine.usingTrackpadOnlyFastPath)

        let afterQuiet = try wheel(source: source, vertical: 4, horizontal: 0)
        _ = engine.rewriteWheelEvent(afterQuiet, at: 1_100_000_000)
        XCTAssertEqual(NSEvent(cgEvent: afterQuiet)?.scrollingDeltaY, 4)
        XCTAssertFalse(engine.usingTrackpadOnlyFastPath)
        XCTAssertEqual(engine.lastDecision?.source, .unknown)
        XCTAssertEqual(engine.lastDecision?.reason, .phaseFreePixel)
    }


    @MainActor
    func testNaturalBaselineProtectsPixelGestureWithoutPreludeAcrossLineWheelHandoff() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for wheelFirst in [false, true] {
            for sign: Int32 in [-1, 1] {
                let engine = ScrollEventEngine(reverseTouchSurface: false)
                engine.setTrackpadOnlyEligible(false, at: 1)

                func sendWheel(at timestamp: UInt64) throws {
                    let event = try wheel(source: source, vertical: 4 * sign, horizontal: 7, units: .line)
                    event.timestamp = timestamp
                    _ = engine.rewriteWheelEvent(event, at: timestamp)
                    XCTAssertEqual(engine.lastDecision?.source, .mouseWheel)
                    XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -4 * Int64(sign))
                    XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 7)
                }
                if wheelFirst { try sendWheel(at: 2) }
                let fields: [(Int64, Int64)] = [
                    (Int64(CGScrollPhase.began.rawValue), 0),
                    (Int64(CGScrollPhase.changed.rawValue), 0),
                    (Int64(CGScrollPhase.ended.rawValue), 0),
                    (0, Int64(CGMomentumScrollPhase.begin.rawValue)),
                    (0, Int64(CGMomentumScrollPhase.continuous.rawValue)),
                    (0, Int64(CGMomentumScrollPhase.end.rawValue))
                ]
                for (offset, phases) in fields.enumerated() {
                    let timestamp = UInt64(offset + 3)
                    let event = try wheel(source: source, vertical: 4 * sign, horizontal: 7)
                    event.timestamp = timestamp
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.0)
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.1)
                    let before = event.data as Data?
                    _ = engine.rewriteWheelEvent(event, at: timestamp)
                    XCTAssertEqual(engine.lastDecision?.source, .unknown)
                    XCTAssertEqual(event.data as Data?, before)
                    if !wheelFirst && offset == 3 { try sendWheel(at: timestamp) }
                }
            }
        }
    }

    @MainActor
    func testPixelWheelCannotStealRecognizedTrackpadMomentumInEitherBaseline() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for reverseTouchSurface in [false, true] {
            let engine = ScrollEventEngine(reverseTouchSurface: reverseTouchSurface)
            for (offset, phase) in [CGScrollPhase.mayBegin, .began, .ended].enumerated() {
                let event = try wheel(source: source, vertical: 4, horizontal: 7)
                event.timestamp = UInt64(offset + 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                _ = engine.rewriteWheelEvent(event)
            }
            for (offset, phase) in [CGMomentumScrollPhase.begin, .continuous, .end].enumerated() {
                let timestamp = UInt64(offset + 4)
                let momentum = try wheel(source: source, vertical: 4, horizontal: 7)
                momentum.timestamp = timestamp
                momentum.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(phase.rawValue))
                _ = engine.rewriteWheelEvent(momentum)
                XCTAssertEqual(engine.lastDecision?.source, .trackpad)
                XCTAssertEqual(momentum.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), reverseTouchSurface ? -4 : 4)
                XCTAssertEqual(momentum.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 7)

                // This simulates a phase-free pixel wheel, which Quartz cannot
                // distinguish from an unowned pixel trackpad event. Passing it
                // unchanged is a safety policy, not successful wheel correction.
                if phase != .end {
                    let pixel = try wheel(source: source, vertical: 4, horizontal: 7)
                    pixel.timestamp = timestamp
                    let before = pixel.data as Data?
                    _ = engine.rewriteWheelEvent(pixel)
                    XCTAssertEqual(engine.lastDecision?.source, .unknown)
                    XCTAssertEqual(pixel.data as Data?, before)
                }
            }
        }
    }

    @MainActor
    func testPixelWheelThenTrackpadKeepsGestureAndMomentumOwnerInBothBaselines() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for reverseTouchSurface in [false, true] {
            for sign: Int32 in [-1, 1] {
                let engine = ScrollEventEngine(reverseTouchSurface: reverseTouchSurface)
                let pixelWheel = try wheel(source: source, vertical: 4 * sign, horizontal: 7)
                pixelWheel.timestamp = 1
                let pixelBefore = pixelWheel.data as Data?
                _ = engine.rewriteWheelEvent(pixelWheel)
                // Source inference remains unavailable for this pixel impulse.
                // Its preservation does not prove the intended mouse direction.
                XCTAssertEqual(engine.lastDecision?.source, .unknown)
                XCTAssertEqual(pixelWheel.data as Data?, pixelBefore)

                let phases: [(Int64, Int64)] = [
                    (Int64(CGScrollPhase.mayBegin.rawValue), 0),
                    (Int64(CGScrollPhase.began.rawValue), 0),
                    (Int64(CGScrollPhase.changed.rawValue), 0),
                    (Int64(CGScrollPhase.ended.rawValue), 0),
                    (0, Int64(CGMomentumScrollPhase.begin.rawValue)),
                    (0, Int64(CGMomentumScrollPhase.continuous.rawValue)),
                    (0, Int64(CGMomentumScrollPhase.end.rawValue))
                ]
                for (offset, fields) in phases.enumerated() {
                    let event = try wheel(source: source, vertical: 4 * sign, horizontal: 7)
                    event.timestamp = UInt64(offset + 2)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: fields.0)
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: fields.1)
                    _ = engine.rewriteWheelEvent(event)
                    XCTAssertEqual(engine.lastDecision?.source, .trackpad)
                    XCTAssertEqual(
                        event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                        Int64(4 * sign) * (reverseTouchSurface ? -1 : 1)
                    )
                    XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 7)
                }
            }
        }
    }

    @MainActor
    func testNaturalBaselineKeepsPixelGestureUnchangedAfterTapReset() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: false)
        let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
        prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
        _ = engine.rewriteWheelEvent(prelude)
        engine.resetClassification(reason: .tapTimeout)
        for phase in [CGScrollPhase.changed, .ended] {
            let event = try wheel(source: source, vertical: 4, horizontal: 7)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            let before = event.data as Data?
            _ = engine.rewriteWheelEvent(event)
            XCTAssertEqual(event.data as Data?, before)
        }
    }

    @MainActor
    func testFractionalRawAndAcceleratedFieldsReverseAndPreserveHorizontalPayload() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for reverseTouchSurface in [false, true] {
            for sign: Int32 in [-1, 1] {
                var rewriter = ScrollWheelRewriter(reverseTouchSurface: reverseTouchSurface,
                                                   collectDirectionTrace: true)
                if reverseTouchSurface {
                    let prelude = try wheel(source: source, vertical: 0, horizontal: 0)
                    prelude.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.mayBegin.rawValue))
                    _ = rewriter.rewriteWheelEvent(prelude)
                }
                let event = try wheel(source: source, vertical: sign * 4, horizontal: 7,
                                      units: reverseTouchSurface ? .pixel : .line)
                if reverseTouchSurface {
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
                }
                event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: Double(sign) * 0.5)
                event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: Double(sign) * 12.5)
                event.setDoubleValueField(.scrollWheelEventRawDeltaAxis2, value: -2.5)
                event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2, value: 8.5)
                event.flags = .maskAlphaShift
                event.timestamp = 123_456
                event.location = CGPoint(x: 120, y: 240)
                let originalPoint = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let originalHorizontalPoint = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                _ = rewriter.rewriteWheelEvent(event)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1), -Double(sign) * 0.5)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1), -Double(sign) * 12.5)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -originalPoint)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), originalHorizontalPoint)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis2), -2.5)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2), 8.5)
                XCTAssertEqual(event.flags, .maskAlphaShift)
                XCTAssertEqual(event.timestamp, 123_456)
                XCTAssertEqual(event.location, CGPoint(x: 120, y: 240))
            }
        }
    }

    @MainActor
    func testNonfiniteRawAndAcceleratedFieldsCannotPartiallyReverseVerticalInput() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for field: CGEventField in [.scrollWheelEventRawDeltaAxis1, .scrollWheelEventAcceleratedDeltaAxis1] {
            for value: Double in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
                var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: true)
                let event = try wheel(source: source, vertical: 4, horizontal: 7, units: .line)
                event.setDoubleValueField(field, value: value)
                let stored = event.getDoubleValueField(field)
                if value.isFinite && stored.isFinite { continue }
                XCTAssertFalse(stored.isFinite)
                let original = event.data as Data?
                XCTAssertTrue(rewriter.rewriteWheelEvent(event) === event)
                XCTAssertEqual(event.data as Data?, original)
                guard case let .scroll(sample)? = rewriter.recentDirectionRecords.last else {
                    return XCTFail("Missing diagnostic sample")
                }
                XCTAssertFalse(sample.reversed)
            }
        }
    }

    @MainActor
    func testAmbiguousPixelPreservesFractionalRawAndAcceleratedFields() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: true)
        let event = try wheel(source: source, vertical: 4, horizontal: 7)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: 0.5)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: 12.5)
        let original = event.data as Data?
        _ = rewriter.rewriteWheelEvent(event)
        XCTAssertEqual(rewriter.lastDecision?.source, .unknown)
        XCTAssertEqual(event.data as Data?, original)
    }

    @MainActor
    private func wheel(
        source: CGEventSource, vertical: Int32, horizontal: Int32,
        units: CGScrollEventUnit = .pixel
    ) throws -> CGEvent {
        try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ))
    }
}

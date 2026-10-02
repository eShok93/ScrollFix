import AppKit
import XCTest
@testable import ScrollFix

final class MouseWheelPipelineTests: XCTestCase {
    private func wheel(point: Int64 = 10, line: Int64 = 1) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: 1, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(line))
        event.location = CGPoint(x: 120, y: 240)
        event.timestamp = 123_456
        return event
    }

    private func pipeline(_ feel: MouseWheelFeel = .tactile, canPost: Bool = true,
                          diagnostics: Bool = true) -> MouseWheelPipeline {
        let pipeline = MouseWheelPipeline(collectDiagnostics: diagnostics)
        pipeline.configure(.init(feel: feel, canPost: canPost))
        return pipeline
    }

    func testNativeKeepsEveryOriginalField() throws {
        let pipeline = pipeline(.native), event = wheel()
        let output = try XCTUnwrap(pipeline.process(event, source: .mouseWheel, at: 0))
        XCTAssertTrue(output === event)
        XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
        XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
        XCTAssertEqual(output.getIntegerValueField(.eventSourceUserData), 0)
        XCTAssertNil(pipeline.nextFrame(at: 90_000_000))
    }

    func testDirectDeliversMinimumDistanceWithoutTail() {
        let pipeline = pipeline(.direct), event = wheel()
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 48)
        XCTAssertEqual(NSEvent(cgEvent: event)?.scrollingDeltaY, 48)
        XCTAssertFalse(pipeline.isActive)
        XCTAssertNil(pipeline.nextFrame(at: 10_000_000))
    }

    func testTactileImmediateAndTailConserveDistance() {
        let pipeline = pipeline(), event = wheel()
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 17)
        let tail = pipeline.nextFrame(at: 90_000_000)!
        XCTAssertEqual(tail.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 31)
        XCTAssertFalse(pipeline.isActive)
        XCTAssertNil(pipeline.nextFrame(at: 100_000_000))
    }

    func testFirstFiveSmallImpulsesPlanEqualDistances() {
        let pipeline = pipeline()
        for index: UInt64 in 0..<5 {
            _ = pipeline.process(wheel(point: Int64(index + 1)), source: .mouseWheel, at: index * 20_000_000)
        }
        XCTAssertEqual(pipeline.samples.map(\.plannedDistance), Array(repeating: 48, count: 5))
        XCTAssertEqual(pipeline.samples[0].gapMilliseconds, nil)
        XCTAssertEqual(pipeline.samples[1].gapMilliseconds, 20)
    }

    func testPostingPermissionCannotBeAssumedFromInterception() {
        let pipeline = pipeline(canPost: false), event = wheel()
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
        XCTAssertFalse(pipeline.isActive)
        XCTAssertEqual(pipeline.samples.last?.feel, .native)
    }

    func testUnavailableTimerFallsBackToOriginalImpulse() {
        let pipeline = pipeline(), event = wheel()
        _ = pipeline.process(event, source: .mouseWheel, at: 0, canAnimate: false)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
        XCTAssertFalse(pipeline.isActive)
    }

    func testTrackpadAndAmbiguousInputAreUntouchedAndCancelWheelTail() {
        for source: ScrollSourceClassifier.Source in [.trackpad, .unknown] {
            let pipeline = pipeline()
            _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
            let touch = wheel(point: 23)
            touch.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            _ = pipeline.process(touch, source: source, at: 5_000_000)
            XCTAssertEqual(touch.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 23)
            XCTAssertFalse(pipeline.isActive)
        }
    }

    func testPreciseWheelCannotEnterLineSmoothingHeuristic() {
        let pipeline = pipeline(), event = wheel(point: 23)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 23)
        XCTAssertFalse(pipeline.isActive)
    }

    func testPhasesAndMomentumArePreserved() {
        for field: CGEventField in [.scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase] {
            let pipeline = pipeline(), event = wheel(point: 22)
            event.setIntegerValueField(field, value: 1)
            _ = pipeline.process(event, source: .mouseWheel, at: 0)
            XCTAssertEqual(event.getIntegerValueField(field), 1)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 22)
            XCTAssertFalse(pipeline.isActive)
        }
    }

    func testModifiedZoomOrShiftScrollingStaysNative() {
        for flag: CGEventFlags in [.maskControl, .maskAlternate, .maskCommand, .maskShift] {
            let pipeline = pipeline(), event = wheel()
            event.flags = flag
            _ = pipeline.process(event, source: .mouseWheel, at: 0)
            XCTAssertEqual(event.flags, flag)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
            XCTAssertFalse(pipeline.isActive)
        }
    }

    func testHorizontalAndDiagonalInputRemainNative() {
        let pipeline = pipeline(), event = wheel()
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 11)
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 11)
        XCTAssertFalse(pipeline.isActive)
    }

    func testRawAndAcceleratedHorizontalPayloadPassesThroughWithoutVerticalRewrite() {
        for feel: MouseWheelFeel in MouseWheelFeel.allCases {
            for field: CGEventField in [.scrollWheelEventRawDeltaAxis2, .scrollWheelEventAcceleratedDeltaAxis2] {
                for value: Double in [-1, 1, -0.5, 0.5, Double(Int32.min), Double(Float.greatestFiniteMagnitude), .infinity, -.infinity, .nan] {
                    let pipeline = pipeline(feel)
                    _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
                    let event = wheel()
                    event.setDoubleValueField(field, value: value)
                    let stored = event.getDoubleValueField(field)
                    if value.isNaN { XCTAssertTrue(stored.isNaN) } else { XCTAssertEqual(stored, value) }
                    let original = event.data as Data?
                    XCTAssertTrue(pipeline.process(event, source: .mouseWheel, at: 20_000_000) === event)
                    XCTAssertEqual(event.data as Data?, original)
                    XCTAssertFalse(pipeline.isActive)
                    XCTAssertNil(pipeline.nextFrame(at: 40_000_000))
                }
            }
        }
    }

    func testUnsafeRawAndAcceleratedVerticalFieldsPassThroughAndCancelTail() {
        for feel: MouseWheelFeel in [.direct, .tactile, .smooth] {
            for field: CGEventField in [.scrollWheelEventRawDeltaAxis1, .scrollWheelEventAcceleratedDeltaAxis1] {
                for value: Double in [769, -769, .greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
                    let pipeline = pipeline(feel)
                    _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
                    let event = wheel()
                    event.setDoubleValueField(field, value: value)
                    let stored = event.getDoubleValueField(field)
                    if value.isNaN {
                        XCTAssertTrue(stored.isNaN)
                    } else if value == .greatestFiniteMagnitude {
                        // Quartz can store these fields as Float: test the
                        // actual stored value, not an assumed Double round-trip.
                        XCTAssertTrue(!stored.isFinite || abs(stored) > 768)
                    } else {
                        XCTAssertEqual(stored, value)
                    }
                    let original = event.data as Data?
                    XCTAssertTrue(pipeline.process(event, source: .mouseWheel, at: 20_000_000) === event)
                    XCTAssertEqual(event.data as Data?, original)
                    XCTAssertFalse(pipeline.isActive)
                }
            }
        }
    }

    func testAcceptedRawAndAcceleratedVerticalFieldsAreClearedUsingDoubleAccessor() {
        for feel: MouseWheelFeel in [.direct, .tactile, .smooth] {
            let pipeline = pipeline(feel), event = wheel()
            event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: 2.5)
            event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: 12.5)
            let original = event.data as Data?
            let result = pipeline.process(event, source: .mouseWheel, at: 0)
            XCTAssertEqual(pipeline.samples.last?.rawDelta, 2.5)
            if feel == .smooth {
                XCTAssertNil(result)
                XCTAssertEqual(event.data as Data?, original)
                let frame = pipeline.nextFrame(at: 50_000_000)!
                XCTAssertEqual(frame.getDoubleValueField(.scrollWheelEventRawDeltaAxis1), 0)
                XCTAssertEqual(frame.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1), 0)
            } else {
                XCTAssertTrue(result === event)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1), 0)
                XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1), 0)
            }
        }
    }

    func testUnsafeNumericInputsPassThrough() {
        let pipeline = pipeline()
        let oversized = wheel(point: 100_000)
        // The raw field does not round-trip Int64.min on this public API;
        // use a representable, oversized point delta to exercise the guard.
        XCTAssertEqual(oversized.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 100_000)
        _ = pipeline.process(oversized, source: .mouseWheel, at: 0)
        XCTAssertEqual(oversized.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 100_000)
        let conflicting = wheel(point: -10, line: 1)
        _ = pipeline.process(conflicting, source: .mouseWheel, at: 1)
        XCTAssertEqual(conflicting.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -10)
        XCTAssertFalse(pipeline.isActive)
    }

    func testRealPointMinimumCannotPartiallyReverseOtherVerticalFields() {
        let event = wheel(point: Int64(Int32.min))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(Int32.min))
        let originalLine = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let originalFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: true)
        _ = rewriter.rewriteWheelEvent(event, at: 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(Int32.min))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), originalLine)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), originalFixed)
        guard case let .scroll(sample)? = rewriter.recentDirectionRecords.last else {
            return XCTFail("Expected a direction sample")
        }
        XCTAssertFalse(sample.reversed)
    }

    func testFramesRetainRoutingAndMetadata() {
        let pipeline = pipeline(), event = wheel()
        event.flags = .maskAlphaShift
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 123)
        _ = pipeline.process(event, source: .mouseWheel, at: 0)
        XCTAssertEqual(event.timestamp, 123_456)
        XCTAssertEqual(event.location, CGPoint(x: 120, y: 240))
        XCTAssertEqual(event.flags, .maskAlphaShift)
        let frame = pipeline.nextFrame(at: 90_000_000)!
        XCTAssertEqual(frame.location, event.location)
        XCTAssertEqual(frame.flags, event.flags)
        XCTAssertEqual(frame.getIntegerValueField(.eventTargetUnixProcessID), 123)
        XCTAssertEqual(frame.getIntegerValueField(.eventSourceUserData), ScrollFixSyntheticEvent.wheelSmoothMarker)
        XCTAssertEqual(frame.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
        XCTAssertEqual(frame.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
    }

    func testChangeOfTargetOrPointerStartsFresh() {
        let pipeline = pipeline()
        _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
        let next = wheel()
        next.location = CGPoint(x: 320, y: 440)
        _ = pipeline.process(next, source: .mouseWheel, at: 20_000_000)
        XCTAssertEqual(next.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 17)
        XCTAssertEqual(pipeline.nextFrame(at: 110_000_000)?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 31)
    }

    func testSyntheticFramesBypassDirectionAndSmoothingAgain() {
        let pipeline = pipeline(), frame = MouseWheelPipeline.makeFrame(pixels: 5, template: wheel())!
        var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: true)
        _ = rewriter.rewriteWheelEvent(frame, at: 0)
        _ = pipeline.process(frame, source: .mouseWheel, at: 0)
        XCTAssertEqual(frame.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 5)
        XCTAssertTrue(rewriter.recentDirectionRecords.isEmpty)
        XCTAssertTrue(pipeline.samples.isEmpty)
    }

    func testAutoscrollStopsIndependentWheelTail() {
        let pipeline = pipeline()
        _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
        let auto = wheel()
        auto.setIntegerValueField(.eventSourceUserData, value: ScrollFixSyntheticEvent.autoScrollMarker)
        _ = pipeline.process(auto, source: .mouseWheel, at: 10_000_000)
        XCTAssertFalse(pipeline.isActive)
        XCTAssertNil(pipeline.nextFrame(at: 90_000_000))
        XCTAssertEqual(auto.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
    }

    func testConfigurationChangesClearTailAndClampStep() {
        let pipeline = pipeline()
        _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
        pipeline.configure(.init(feel: .direct, canPost: false, minimumStep: .max))
        XCTAssertFalse(pipeline.isActive)
        XCTAssertEqual(pipeline.configuration.minimumStep, 128)
        let event = wheel()
        _ = pipeline.process(event, source: .mouseWheel, at: 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 128)
    }

    func testUnchangedConfigurationDoesNotRestartTail() {
        let pipeline = pipeline()
        _ = pipeline.process(wheel(), source: .mouseWheel, at: 0)
        pipeline.configure(pipeline.configuration)
        XCTAssertTrue(pipeline.isActive)
        XCTAssertEqual(pipeline.nextFrame(at: 90_000_000)?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 31)
    }

    func testDiagnosticsAreBoundedAndDisabledInProduction() {
        let qa = pipeline(.direct), production = pipeline(.direct, diagnostics: false)
        for index: UInt64 in 0..<100 {
            _ = qa.process(wheel(), source: .mouseWheel, at: index)
            _ = production.process(wheel(), source: .mouseWheel, at: index)
        }
        XCTAssertEqual(qa.samples.count, 16)
        XCTAssertEqual(production.samples.count, 0)
        production.recordPostedFrame()
        XCTAssertEqual(production.postedFrames, 0)
        qa.cancel(clearDiagnostics: true)
        XCTAssertTrue(qa.samples.isEmpty)
    }

    func testSmoothConsumesInputWithoutChangingItOrEmittingImmediateJump() {
        let pipeline = pipeline(.smooth), event = wheel()
        let before = event.data as Data?
        XCTAssertNil(pipeline.process(event, source: .mouseWheel, at: 0))
        XCTAssertEqual(event.data as Data?, before)
        XCTAssertEqual(pipeline.samples.last?.immediateDistance, 0)
        XCTAssertEqual(pipeline.samples.last?.plannedDistance, 48)
        XCTAssertNil(pipeline.nextFrame(at: 8_333_333))
        XCTAssertTrue(pipeline.isActive)
    }

    func testSmoothDisplayFramesConserveDistanceAndMetadata() throws {
        let pipeline = pipeline(.smooth), event = wheel()
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 123)
        event.flags = .maskAlphaShift
        XCTAssertNil(pipeline.process(event, source: .mouseWheel, at: 0))
        var total: Int64 = 0
        var frames = 0
        for index: UInt64 in 1...120 {
            guard let frame = pipeline.nextFrame(at: index * 16_666_667) else { continue }
            total += frame.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            frames += 1
            XCTAssertEqual(frame.location, CGPoint(x: 120, y: 240))
            XCTAssertEqual(frame.flags, .maskAlphaShift)
            XCTAssertEqual(frame.getIntegerValueField(.eventTargetUnixProcessID), 123)
            XCTAssertEqual(frame.getIntegerValueField(.eventSourceUserData), ScrollFixSyntheticEvent.wheelSmoothMarker)
            XCTAssertTrue(try XCTUnwrap(NSEvent(cgEvent: frame)).hasPreciseScrollingDeltas)
            XCTAssertGreaterThan(frame.timestamp, 123_456)
        }
        XCTAssertGreaterThan(frames, 10)
        XCTAssertEqual(total, 48)
        XCTAssertFalse(pipeline.isActive)
    }

    func testBothAnimatedModesRequirePostingAccessAndClock() {
        for feel: MouseWheelFeel in [.tactile, .smooth] {
            for deniedAccess in [true, false] {
                let pipeline = pipeline(feel, canPost: !deniedAccess), event = wheel()
                XCTAssertTrue(pipeline.process(event, source: .mouseWheel, at: 0,
                                               canAnimate: deniedAccess) === event)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 10)
                XCTAssertFalse(pipeline.isActive)
            }
        }
    }

    func testModeSwitchDropsSmoothTailBeforeTactileResponse() {
        let pipeline = pipeline(.smooth)
        XCTAssertNil(pipeline.process(wheel(), source: .mouseWheel, at: 0))
        _ = pipeline.nextFrame(at: 40_000_000)
        pipeline.configure(.init(feel: .tactile, canPost: true))
        let event = wheel()
        XCTAssertTrue(pipeline.process(event, source: .mouseWheel, at: 50_000_000) === event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 17)
        XCTAssertEqual(pipeline.nextFrame(at: 140_000_000)?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 31)
        XCTAssertFalse(pipeline.isActive)
    }

    func testSmoothBypassesTrackpadPixelsPhasesModifiersAndHorizontalInput() {
        for variant in 0..<5 {
            let pipeline = pipeline(.smooth)
            XCTAssertNil(pipeline.process(wheel(), source: .mouseWheel, at: 0))
            let event = wheel(point: 23)
            let source: ScrollSourceClassifier.Source
            switch variant {
            case 0: source = .trackpad
            case 1: source = .mouseWheel; event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            case 2: source = .mouseWheel; event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
            case 3: source = .mouseWheel; event.flags = .maskControl
            default: source = .mouseWheel; event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 5)
            }
            let original = event.data as Data?
            XCTAssertTrue(pipeline.process(event, source: source, at: 10_000_000) === event)
            XCTAssertEqual(event.data as Data?, original)
            XCTAssertFalse(pipeline.isActive)
        }
    }

    func testSmoothSyntheticFrameBypassesRewriterAndActiveMotion() throws {
        let pipeline = pipeline(.smooth)
        XCTAssertNil(pipeline.process(wheel(), source: .mouseWheel, at: 0))
        let frame = try XCTUnwrap(pipeline.nextFrame(at: 50_000_000))
        let original = frame.data as Data?
        var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: true)
        _ = rewriter.rewriteWheelEvent(frame, at: 50_000_000)
        XCTAssertTrue(pipeline.process(frame, source: .mouseWheel, at: 50_000_000) === frame)
        XCTAssertEqual(frame.data as Data?, original)
        XCTAssertTrue(pipeline.isActive)
        XCTAssertEqual(pipeline.samples.count, 1)
        XCTAssertTrue(rewriter.recentDirectionRecords.isEmpty)
    }

    func testModeNamesDescribeFourDistinctBehaviors() {
        XCTAssertEqual(MouseWheelFeel.allCases.map(\.title), ["macOS", "Direkt (Windows)", "Kurz", "Weich"])
        XCTAssertFalse(MouseWheelFeel.native.requiresPosting)
        XCTAssertFalse(MouseWheelFeel.direct.requiresPosting)
        XCTAssertTrue(MouseWheelFeel.tactile.requiresPosting)
        XCTAssertTrue(MouseWheelFeel.smooth.requiresPosting)
    }

    func testDenseSmoothInputUsesNativeDistanceInsteadOfRepeatedMinimum() {
        let pipeline = pipeline(.smooth)
        for index: UInt64 in 0..<8 {
            XCTAssertNil(pipeline.process(wheel(point: 1), source: .mouseWheel, at: index * 10_000_000))
            _ = pipeline.nextFrame(at: index * 10_000_000)
        }
        XCTAssertEqual(pipeline.samples.map(\.plannedDistance), [48, 48, 48, 48, 1, 1, 1, 1])
        XCTAssertEqual(pipeline.samples.map(\.denseInput), [false, false, false, false, true, true, true, true])
        XCTAssertTrue(pipeline.samples.allSatisfy { $0.immediateDistance == 0 })
    }

    func testDenseCounterDiscardsOldTailAndKeepsFirstCounterVisible() {
        for sign: Int64 in [-1, 1] {
            let pipeline = pipeline(.smooth)
            for index: UInt64 in 0..<100 {
                _ = pipeline.process(wheel(point: sign, line: sign), source: .mouseWheel, at: index * 10_000_000)
                _ = pipeline.nextFrame(at: index * 10_000_000)
            }
            XCTAssertNil(pipeline.process(wheel(point: -sign, line: -sign), source: .mouseWheel, at: 1_000_000_000))
            XCTAssertEqual(pipeline.samples.last?.plannedDistance, -sign * 48)
            XCTAssertEqual(pipeline.samples.last?.denseInput, true)
            XCTAssertNil(pipeline.nextFrame(at: 1_000_000_000))
            XCTAssertEqual(pipeline.nextFrame(at: 1_008_333_333)?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -sign)
            for index: UInt64 in 2...40 {
                let frame = pipeline.nextFrame(at: 1_000_000_000 + index * 8_333_333)
                XCTAssertGreaterThanOrEqual((frame?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) ?? 0) * -sign, 0)
            }
            XCTAssertFalse(pipeline.isActive)
        }
    }

    func testDenseSmoothTailEndsWithoutLateJump() {
        let pipeline = pipeline(.smooth)
        for index: UInt64 in 0..<100 {
            _ = pipeline.process(wheel(point: 1), source: .mouseWheel, at: index * 10_000_000)
            _ = pipeline.nextFrame(at: index * 10_000_000)
        }
        for time: UInt64 in stride(from: 1_000_000_000, through: 1_200_000_000, by: 10_000_000) {
            _ = pipeline.nextFrame(at: time)
        }
        XCTAssertNil(pipeline.nextFrame(at: 1_210_000_000))
        XCTAssertFalse(pipeline.isActive)
        XCTAssertNil(pipeline.nextFrame(at: 1_500_000_000))
    }

    func testSlowSmoothInputsKeepMinimumAndDenseLineFallbackIsProportional() {
        let slow = pipeline(.smooth), dense = pipeline(.smooth)
        for index: UInt64 in 0..<8 {
            _ = slow.process(wheel(point: 1), source: .mouseWheel, at: index * 80_000_000)
            _ = slow.nextFrame(at: index * 80_000_000)
            _ = dense.process(wheel(point: 0), source: .mouseWheel, at: index * 10_000_000)
            _ = dense.nextFrame(at: index * 10_000_000)
        }
        XCTAssertEqual(slow.samples.map(\.plannedDistance), Array(repeating: 48, count: 8))
        XCTAssertEqual(dense.samples.map(\.plannedDistance), [48, 48, 48, 48, 10, 10, 10, 10])
    }

    func testDenseAdaptationDoesNotChangeOtherModes() {
        for feel: MouseWheelFeel in [.native, .direct, .tactile] {
            let pipeline = pipeline(feel)
            for index: UInt64 in 0..<8 {
                _ = pipeline.process(wheel(point: 1), source: .mouseWheel, at: index * 10_000_000)
                _ = pipeline.nextFrame(at: index * 10_000_000)
            }
            XCTAssertTrue(pipeline.samples.allSatisfy { !$0.denseInput })
            XCTAssertTrue(pipeline.samples.allSatisfy { $0.plannedDistance == (feel == .native ? nil : 48) })
        }
    }

    func testPassThroughAndExplicitCancelResetDenseState() {
        for variant in 0..<6 {
            let pipeline = pipeline(.smooth)
            for index: UInt64 in 0..<5 {
                _ = pipeline.process(wheel(point: 1), source: .mouseWheel, at: index * 10_000_000)
                _ = pipeline.nextFrame(at: index * 10_000_000)
            }
            let event = wheel(point: 23)
            var source: ScrollSourceClassifier.Source = .mouseWheel
            switch variant {
            case 0: source = .trackpad
            case 1: source = .unknown
            case 2: event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            case 3: event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
            case 4: event.flags = .maskControl
            default: pipeline.cancel()
            }
            if variant != 5 {
                let original = event.data as Data?
                XCTAssertTrue(pipeline.process(event, source: source, at: 50_000_000) === event)
                XCTAssertEqual(event.data as Data?, original)
            }
            _ = pipeline.process(wheel(point: 1), source: .mouseWheel, at: 60_000_000)
            XCTAssertEqual(pipeline.samples.last?.plannedDistance, 48)
            XCTAssertEqual(pipeline.samples.last?.denseInput, false)
        }
    }

    func testQuietGapAndContextChangeRestartIsolatedSmoothResponse() {
        for variant in 0..<3 {
            let pipeline = pipeline(.smooth)
            for index: UInt64 in 0..<5 {
                _ = pipeline.process(wheel(point: 1), source: .mouseWheel, at: index * 10_000_000)
                _ = pipeline.nextFrame(at: index * 10_000_000)
            }
            let event = wheel(point: 1)
            let now: UInt64 = variant == 0 ? 190_000_000 : 50_000_000
            if variant == 1 { event.location.x += 10 }
            if variant == 2 { event.setIntegerValueField(.eventTargetUnixProcessID, value: 123) }
            XCTAssertNil(pipeline.process(event, source: .mouseWheel, at: now))
            XCTAssertEqual(pipeline.samples.last?.plannedDistance, 48)
            XCTAssertEqual(pipeline.samples.last?.denseInput, false)
            XCTAssertNil(pipeline.nextFrame(at: now + 8_333_333))
        }
    }

    func testDenseWheelHandoffPreservesRecognizedTrackpadAndItsMomentum() {
        for trackpadFirst in [false, true] {
            let pipeline = pipeline(.smooth)
            var rewriter = ScrollWheelRewriter(reverseTouchSurface: false, collectDirectionTrace: false)
            func trackpad(phase: Int64 = 0, momentum: Int64 = 0, at now: UInt64) {
                let event = wheel(point: 23)
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                let original = event.data as Data?
                _ = rewriter.rewriteWheelEvent(event, at: now)
                XCTAssertEqual(rewriter.lastDecision?.source, .trackpad)
                XCTAssertTrue(pipeline.process(event, source: rewriter.lastDecision?.source, at: now) === event)
                XCTAssertEqual(event.data as Data?, original)
                XCTAssertFalse(pipeline.isActive)
            }
            func beginTrackpad(at now: UInt64) {
                trackpad(phase: Int64(CGScrollPhase.mayBegin.rawValue), at: now)
                trackpad(phase: Int64(CGScrollPhase.began.rawValue), at: now + 1)
                trackpad(phase: Int64(CGScrollPhase.ended.rawValue), at: now + 2)
                trackpad(momentum: Int64(CGMomentumScrollPhase.begin.rawValue), at: now + 3)
            }
            if trackpadFirst { beginTrackpad(at: 1) }
            for index: UInt64 in 0..<8 {
                let event = wheel(point: 1), now = 100_000_000 + index * 10_000_000
                _ = rewriter.rewriteWheelEvent(event, at: now)
                XCTAssertEqual(rewriter.lastDecision?.source, .mouseWheel)
                XCTAssertNil(pipeline.process(event, source: rewriter.lastDecision?.source, at: now))
                _ = pipeline.nextFrame(at: now)
            }
            XCTAssertTrue(pipeline.samples.last!.denseInput)
            if !trackpadFirst { beginTrackpad(at: 180_000_000) }
            trackpad(momentum: 2, at: 190_000_000) // public momentum continue value
            trackpad(momentum: Int64(CGMomentumScrollPhase.end.rawValue), at: 200_000_000)
            let next = wheel(point: 1)
            _ = rewriter.rewriteWheelEvent(next, at: 210_000_000)
            XCTAssertNil(pipeline.process(next, source: rewriter.lastDecision?.source, at: 210_000_000))
            XCTAssertEqual(pipeline.samples.last?.plannedDistance, -48)
            XCTAssertEqual(pipeline.samples.last?.denseInput, false)
        }
    }
}

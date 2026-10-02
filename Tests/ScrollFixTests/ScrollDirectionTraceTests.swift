import CoreGraphics
import XCTest
@testable import ScrollFix

final class ScrollDirectionTraceTests: XCTestCase {
    func testRecordsOnlyTheLastSixteenDecisionsInOrder() {
        var trace = ScrollDirectionTrace()
        XCTAssertTrue(trace.recent.isEmpty)

        for phase in 0..<20 {
            trace.record(.init(
                scrollPhase: Int64(phase),
                momentumPhase: Int64(phase % 3),
                isContinuous: phase.isMultiple(of: 2),
                verticalInputSign: phase.isMultiple(of: 2) ? .positive : .negative,
                source: phase.isMultiple(of: 2) ? .trackpad : .mouseWheel,
                reversed: phase.isMultiple(of: 3)
            ))
        }

        let samples = trace.recent.compactMap { record -> ScrollDirectionTrace.Sample? in
            if case let .scroll(sample) = record { return sample }
            return nil
        }
        XCTAssertEqual(samples.count, ScrollDirectionTrace.capacity)
        XCTAssertEqual(samples.map(\.scrollPhase), Array(4..<20).map(Int64.init))
        XCTAssertEqual(samples.first?.momentumPhase, 1)
        XCTAssertEqual(samples.last?.isContinuous, false)
        XCTAssertEqual(samples.last?.verticalInputSign, .negative)
        XCTAssertEqual(samples.last?.source, .mouseWheel)
        XCTAssertEqual(samples.last?.reversed, false)

        trace.record(.init(
            scrollPhase: 19, momentumPhase: 1,
            isContinuous: false, verticalInputSign: .negative,
            source: .mouseWheel, reversed: false
        ))
        guard case let .scroll(coalescedAtCapacity)? = trace.recent.last else {
            return XCTFail("Expected the last full-ring record")
        }
        XCTAssertEqual(coalescedAtCapacity.repetitions, 2)
        XCTAssertEqual(trace.recent.count, ScrollDirectionTrace.capacity)

        trace.recordReset(.tapTimeout)
        XCTAssertEqual(trace.recent.last, .reset(.tapTimeout))
        XCTAssertEqual(trace.recent.count, ScrollDirectionTrace.capacity)
    }

    func testRepeatedStateUsesOneSlotAndResetBreaksTheRun() {
        var trace = ScrollDirectionTrace()
        let state = ScrollDirectionTrace.Sample(
            scrollPhase: 2, momentumPhase: 0,
            isContinuous: true, verticalInputSign: .positive,
            source: .trackpad, reversed: true
        )
        for _ in 0..<100 { trace.record(state) }
        XCTAssertEqual(trace.recent.count, 1)
        guard case let .scroll(first)? = trace.recent.last else {
            return XCTFail("Expected a coalesced scroll run")
        }
        XCTAssertEqual(first.repetitions, 100)

        trace.recordReset(.tapTimeout)
        trace.record(state)
        trace.record(state)
        XCTAssertEqual(trace.recent.count, 3)
        XCTAssertEqual(trace.recent[1], .reset(.tapTimeout))
        guard case let .scroll(afterReset)? = trace.recent.last else {
            return XCTFail("Expected a new run after reset")
        }
        XCTAssertEqual(afterReset.repetitions, 2)
    }

    func testOppositeInputSignsDoNotCoalesceWithinSameScrollState() {
        var trace = ScrollDirectionTrace()
        func sample(_ sign: ScrollDirectionTrace.VerticalInputSign) -> ScrollDirectionTrace.Sample {
            .init(scrollPhase: 2, momentumPhase: 0, isContinuous: true,
                  verticalInputSign: sign, source: .trackpad, reversed: true)
        }

        trace.record(sample(.positive))
        trace.record(sample(.positive))
        trace.record(sample(.negative))
        trace.record(sample(.negative))
        trace.record(sample(.none))
        trace.record(sample(.zero))

        let samples = trace.recent.compactMap { record -> ScrollDirectionTrace.Sample? in
            if case let .scroll(value) = record { return value }
            return nil
        }
        XCTAssertEqual(samples.map(\.verticalInputSign), [.positive, .negative, .none, .zero])
        XCTAssertEqual(samples.map(\.repetitions), [2, 2, 1, 1])
    }

    func testReadsOnlyInputSignAcrossQuartzVerticalFields() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        func event(_ delta: Int32) throws -> CGEvent {
            try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        }

        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.read(from: try event(4)), .positive)
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.read(from: try event(-4)), .negative)
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.read(from: try event(0)), .none)

        let highResolution = try event(0)
        highResolution.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.25)
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.read(from: highResolution), .positive)

        // CGEvent setters can normalize the other fields, so exercise an
        // inconsistent payload in the scalar classifier directly.
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.from(
            line: 4, point: 4, fixed: 4, accelerated: 0, raw: -1
        ), .zero)
    }

    func testFractionalRawAndAcceleratedInputSignsUseDoubleAccessors() throws {
        for field: CGEventField in [.scrollWheelEventRawDeltaAxis1, .scrollWheelEventAcceleratedDeltaAxis1] {
            for value: Double in [-0.5, 0.5] {
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
                event.setDoubleValueField(field, value: value)
                XCTAssertEqual(event.getDoubleValueField(field), value)
                XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.read(from: event), value < 0 ? .negative : .positive)
            }
        }
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.from(
            line: 4, point: 4, fixed: 4, accelerated: 0, raw: -0.5
        ), .zero)
        XCTAssertEqual(ScrollDirectionTrace.VerticalInputSign.from(
            line: 4, point: 4, fixed: 4, accelerated: .nan, raw: 0
        ), .zero)
    }

    @MainActor
    func testEngineSeparatesOppositeInputTicksBeforeRewritingThem() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true, collectDirectionTrace: true)
        func event(_ phase: CGScrollPhase, delta: Int32) throws -> CGEvent {
            let wheel = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: source, units: .pixel,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
            ))
            wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return wheel
        }

        _ = engine.rewriteWheelEvent(try event(.mayBegin, delta: 0))
        _ = engine.rewriteWheelEvent(try event(.began, delta: 4))
        let positive = try event(.changed, delta: 4)
        _ = engine.rewriteWheelEvent(positive)
        _ = engine.rewriteWheelEvent(try event(.changed, delta: 4))
        let negative = try event(.changed, delta: -4)
        _ = engine.rewriteWheelEvent(negative)

        let records = engine.recentDirectionRecords
        guard records.count == 4,
              case let .scroll(firstChanged) = records[2],
              case let .scroll(lastChanged) = records[3] else {
            return XCTFail("Expected separate changed-phase input signs")
        }
        XCTAssertEqual(firstChanged.scrollPhase, lastChanged.scrollPhase)
        XCTAssertEqual(firstChanged.source, lastChanged.source)
        XCTAssertEqual(firstChanged.verticalInputSign, .positive)
        XCTAssertEqual(firstChanged.repetitions, 2)
        XCTAssertEqual(lastChanged.verticalInputSign, .negative)
        XCTAssertEqual(lastChanged.repetitions, 1)
        XCTAssertTrue(firstChanged.reversed)
        XCTAssertTrue(lastChanged.reversed)
        XCTAssertEqual(positive.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)
        XCTAssertEqual(negative.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 4)
    }

    @MainActor
    func testEngineRecordsActualDirectionDecisionOnlyWhenEnabled() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let engine = ScrollEventEngine(reverseTouchSurface: true, collectDirectionTrace: true)
        let productionEngine = ScrollEventEngine(reverseTouchSurface: true)

        func event(_ phase: CGScrollPhase, delta: Int32) throws -> CGEvent {
            let wheel = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
            ))
            wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return wheel
        }

        let mayBegin = try event(.mayBegin, delta: 0)
        _ = engine.rewriteWheelEvent(mayBegin)
        let began = try event(.began, delta: 4)
        _ = engine.rewriteWheelEvent(began)

        let records = engine.recentDirectionRecords
        XCTAssertEqual(records.count, 2)
        guard case let .scroll(first) = records[0],
              case let .scroll(second) = records[1] else {
            return XCTFail("Expected two scroll samples")
        }
        XCTAssertEqual(first.scrollPhase, Int64(CGScrollPhase.mayBegin.rawValue))
        XCTAssertEqual(first.verticalInputSign, .none)
        XCTAssertEqual(first.verticalOutputSign, .none)
        XCTAssertEqual(first.source, .trackpad)
        XCTAssertFalse(first.reversed)
        XCTAssertEqual(second.scrollPhase, Int64(CGScrollPhase.began.rawValue))
        XCTAssertEqual(second.momentumPhase, 0)
        XCTAssertEqual(second.source, .trackpad)
        XCTAssertEqual(second.verticalInputSign, .positive)
        XCTAssertEqual(second.verticalOutputSign, .negative)
        XCTAssertTrue(second.isContinuous)
        XCTAssertTrue(second.reversed)
        XCTAssertEqual(began.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -4)

        _ = productionEngine.rewriteWheelEvent(try event(.mayBegin, delta: 0))
        XCTAssertTrue(productionEngine.recentDirectionRecords.isEmpty)

        let synthetic = try event(.began, delta: 4)
        synthetic.setIntegerValueField(
            .eventSourceUserData, value: ScrollFixSyntheticEvent.autoScrollMarker
        )
        _ = engine.rewriteWheelEvent(synthetic)
        XCTAssertEqual(engine.recentDirectionRecords.count, 2)

        engine.resetClassification(reason: .tapTimeout)
        XCTAssertEqual(engine.recentDirectionRecords.last, .reset(.tapTimeout))
        let incomplete = try event(.changed, delta: 4)
        _ = engine.rewriteWheelEvent(incomplete)
        guard case let .scroll(afterReset)? = engine.recentDirectionRecords.last else {
            return XCTFail("Expected a scroll sample after reset")
        }
        XCTAssertEqual(afterReset.source, .unknown)
        XCTAssertEqual(afterReset.verticalInputSign, .positive)
        XCTAssertEqual(afterReset.verticalOutputSign, .positive)
        XCTAssertFalse(afterReset.reversed)
        engine.resetClassification(reason: .userInput)
        XCTAssertEqual(engine.recentDirectionRecords.last, .reset(.userInput))
    }
}

import CoreGraphics

/// Short, memory-only QA history of direction decisions. The event tap writes
/// fixed-size scalar records; UI snapshots allocate only when read.
struct ScrollDirectionTrace {
    enum VerticalInputSign: Equatable, Sendable {
        case negative
        case zero
        case positive
        case none

        /// Quartz exposes several representations of the same vertical impulse.
        /// Keep only their sign before the event is changed. Opposing nonzero
        /// fields are recorded as zero to flag an inconsistent input payload.
        static func read(from event: CGEvent) -> Self {
            from(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                accelerated: event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1),
                raw: event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)
            )
        }

        static func from(
            line: Int64, point: Int64, fixed: Double, accelerated: Double, raw: Double
        ) -> Self {
            guard fixed.isFinite, accelerated.isFinite, raw.isFinite else { return .zero }
            let hasPositive = line > 0 || point > 0 || fixed > 0 || accelerated > 0 || raw > 0
            let hasNegative = line < 0 || point < 0 || fixed < 0 || accelerated < 0 || raw < 0

            if hasPositive && hasNegative { return .zero }
            if hasPositive { return .positive }
            if hasNegative { return .negative }
            return .none
        }
    }

    struct Sample: Equatable, Sendable {
        let scrollPhase: Int64
        let momentumPhase: Int64
        let isContinuous: Bool
        let verticalInputSign: VerticalInputSign
        var verticalOutputSign: VerticalInputSign = .none
        let source: ScrollSourceClassifier.Source
        let reversed: Bool
        var repetitions: UInt32 = 1

        func hasSameState(as other: Sample) -> Bool {
            scrollPhase == other.scrollPhase
                && momentumPhase == other.momentumPhase
                && isContinuous == other.isContinuous
                && verticalInputSign == other.verticalInputSign
                && verticalOutputSign == other.verticalOutputSign
                && source == other.source
                && reversed == other.reversed
        }
    }

    enum ResetReason: Equatable, Sendable {
        case tapTimeout
        case userInput
        case classifier
    }

    enum Record: Equatable, Sendable {
        case scroll(Sample)
        case reset(ResetReason)
    }

    static let capacity = 16

    private var slots = Array<Record?>(repeating: nil, count: capacity)
    private var nextIndex = 0
    private var count = 0

    mutating func record(_ sample: Sample) {
        if count > 0 {
            let previousIndex = (nextIndex + Self.capacity - 1) % Self.capacity
            if case var .scroll(previous)? = slots[previousIndex],
               previous.hasSameState(as: sample) {
                if previous.repetitions < .max { previous.repetitions += 1 }
                slots[previousIndex] = .scroll(previous)
                return
            }
        }
        append(.scroll(sample))
    }

    mutating func recordReset(_ reason: ResetReason) {
        append(.reset(reason))
    }

    private mutating func append(_ record: Record) {
        slots[nextIndex] = record
        nextIndex = (nextIndex + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    var recent: [Record] {
        let oldest = count == Self.capacity ? nextIndex : 0
        return (0..<count).compactMap { slots[(oldest + $0) % Self.capacity] }
    }
}

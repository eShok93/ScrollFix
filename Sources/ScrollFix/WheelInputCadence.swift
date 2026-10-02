import Foundation

/// Timing of already validated line-wheel input, not a physical device or mode detector.
struct WheelInputCadence {
    static let fastGap: UInt64 = 35_000_000
    static let quietGap: UInt64 = 150_000_000
    static let fastIntervalsRequired = 4

    struct Sample: Equatable {
        let isDense: Bool
        let reversed: Bool
        let startsNewGesture: Bool
    }

    private var lastInput: UInt64?
    private var lastNegative: Bool?
    private var fastIntervals = 0
    private var dense = false

    mutating func cancel() { self = WheelInputCadence() }

    mutating func observe(distance: Int64, at now: UInt64) -> Sample {
        guard distance != 0, distance != .min,
              abs(distance) <= MouseWheelMotion.maximumInput else {
            cancel()
            return .init(isDense: false, reversed: false, startsNewGesture: true)
        }
        let gap = lastInput.flatMap { now >= $0 ? now - $0 : nil }
        let startsNewGesture = gap.map { $0 >= Self.quietGap } ?? true
        if startsNewGesture { cancel() }
        let reversed = lastNegative.map { $0 != (distance < 0) } ?? false
        if let gap, !startsNewGesture {
            if gap > 0 && gap <= Self.fastGap {
                fastIntervals = min(Self.fastIntervalsRequired, fastIntervals + 1)
            } else {
                fastIntervals = 0
            }
            if fastIntervals == Self.fastIntervalsRequired { dense = true }
        }
        lastInput = now
        lastNegative = distance < 0
        return .init(isDense: dense, reversed: reversed, startsNewGesture: startsNewGesture)
    }
}

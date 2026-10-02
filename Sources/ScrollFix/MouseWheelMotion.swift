import Foundation

enum MouseWheelFeel: String, CaseIterable, Sendable {
    case native
    case direct
    case tactile
    case smooth

    // Retain tactile only for legacy decoding and offline engine coverage.
    static var selectableCases: [Self] { [.native, .direct, .smooth] }

    var title: String {
        switch self {
        case .native: "macOS"
        case .direct: "Direkt (Windows)"
        case .tactile: "Kurz"
        case .smooth: "Weich"
        }
    }

    var requiresPosting: Bool { self == .tactile || self == .smooth }
}

/// Integer point deltas, independent of the display refresh rate or event frequency.
/// The first part is immediate; the remainder finishes within a short, finite tail.
/// This contains no CoreGraphics objects and never posts events.
struct MouseWheelMotion {
    static let minimumStep: Int64 = 48
    static let maximumInput: Int64 = 768
    static let tailDuration: UInt64 = 90_000_000
    static let staleGap: UInt64 = 180_000_000
    private static let timeConstant = 0.024

    private var remaining = 0.0
    private var fractionalOutput = 0.0
    private var lastAdvance: UInt64?
    private var lastInput: UInt64?

    var isActive: Bool { lastInput != nil }

    mutating func cancel() { self = MouseWheelMotion() }

    /// A small wheel impulse gets a predictable minimum distance. Larger macOS
    /// deltas retain their distance; no event is assumed to equal one physical notch.
    static func normalizedDistance(pointDelta: Int64, lineDelta: Int64,
                                   minimumStep: Int64 = Self.minimumStep,
                                   applyMinimum: Bool = true) -> Int64? {
        guard pointDelta != .min, lineDelta != .min,
              (16...128).contains(minimumStep),
              abs(pointDelta) <= maximumInput, abs(lineDelta) <= maximumInput else { return nil }
        let signed = pointDelta != 0 ? pointDelta : lineDelta
        guard signed != 0 else { return nil }
        guard pointDelta != 0 || abs(lineDelta) <= maximumInput / 10 else { return nil }
        let native = pointDelta != 0 ? abs(pointDelta) : abs(lineDelta) * 10
        let distance = applyMinimum ? max(minimumStep, native) : native
        return signed < 0 ? -distance : distance
    }

    mutating func add(distance: Int64, at now: UInt64) -> Int64? {
        guard distance != .min, distance != 0, abs(distance) <= Self.maximumInput else { return nil }
        // An opposite wheel tick stops the previous tail before moving the page.
        if isActive && ((remaining + fractionalOutput < 0) != (distance < 0)) { cancel() }
        let due = advance(at: now)
        let leading = Int64((Double(distance) * 0.35).rounded())
        remaining += Double(distance - leading)
        // Bound work and accumulated motion under a malformed/high-rate stream.
        // Excess is delivered now, preserving distance rather than building a queue.
        let limit = Double(Self.maximumInput) * 4
        var overflow: Int64 = 0
        if abs(remaining) > limit {
            overflow = Int64(remaining - (remaining < 0 ? -limit : limit))
            remaining -= Double(overflow)
        }
        lastInput = now
        lastAdvance = now
        return due + leading + overflow
    }

    mutating func advance(at now: UInt64) -> Int64 {
        guard let input = lastInput, let previous = lastAdvance else { return 0 }
        guard now >= previous, now >= input, now - previous <= Self.staleGap else {
            cancel()
            return 0
        }
        if now - input >= Self.tailDuration {
            let final = Int64((remaining + fractionalOutput).rounded())
            cancel()
            return final
        }
        let elapsed = Double(now - previous) / 1_000_000_000
        let movement = remaining * -expm1(-elapsed / Self.timeConstant)
        remaining -= movement
        fractionalOutput += movement
        let pixels = Int64(fractionalOutput.rounded(.towardZero))
        fractionalOutput -= Double(pixels)
        lastAdvance = now
        return pixels
    }
}

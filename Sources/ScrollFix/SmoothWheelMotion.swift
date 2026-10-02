import Foundation

/// Two continuous exponential responses: one accumulates wheel input, the
/// other softens the onset. This is independent of the display callback rate.
/// Unlike the tactile response, no part of a new impulse is emitted immediately.
struct SmoothWheelMotion {
    static let responseTime = 0.18
    static let onsetTime = 0.06
    static let responsiveTime = 0.06
    static let responsiveOnset = 0.02
    static let responsiveTail: UInt64 = 220_000_000
    static let maximumPending = Double(MouseWheelMotion.maximumInput) * 4
    static let maximumTail: UInt64 = 1_800_000_000

    private var guideRemaining = 0.0
    private var outputRemaining = 0.0
    private var fractionalOutput = 0.0
    private var lastAdvance: UInt64?
    private var lastInput: UInt64?
    private var lastFrame: UInt64?
    private(set) var isResponsive = false

    var isActive: Bool { lastInput != nil }
    private var response: Double { isResponsive ? Self.responsiveTime : Self.responseTime }
    private var onset: Double { isResponsive ? Self.responsiveOnset : Self.onsetTime }

    mutating func cancel() { self = SmoothWheelMotion() }

    /// Accept bounded movement without emitting an immediate frame. Dense input
    /// and counter-scroll use a shorter response through the gesture. A fresh
    /// opposite gesture also starts fast while an old response is still active.
    mutating func add(distance: Int64, at now: UInt64, responsive: Bool = false,
                      startsNewGesture: Bool = false) -> Int64? {
        guard distance != .min, distance != 0,
              abs(distance) <= MouseWheelMotion.maximumInput else { return nil }
        if let previous = lastAdvance, now < previous { cancel(); return nil }
        if let previous = lastFrame, now - previous > MouseWheelMotion.staleGap { cancel() }
        let reversing = isActive && ((outputRemaining < 0) != (distance < 0))
        if reversing || (startsNewGesture && isResponsive) { cancel() }
        _ = integrate(at: now)
        if (responsive || reversing) && !isResponsive {
            // Preserve position and velocity when shortening an existing response.
            // Changing both time constants without this conversion creates a jump.
            let velocity = (outputRemaining - guideRemaining) / onset
            guideRemaining = outputRemaining - velocity * Self.responsiveOnset
            isResponsive = true
        }
        let room = max(0, Self.maximumPending - abs(outputRemaining + fractionalOutput))
        let accepted = min(abs(distance), Int64(room.rounded(.down)))
        let signed = distance < 0 ? -accepted : accepted
        guideRemaining += Double(signed)
        outputRemaining += Double(signed)
        lastInput = now
        lastAdvance = now
        if lastFrame == nil { lastFrame = now }
        return signed
    }

    mutating func advance(at now: UInt64) -> Int64 {
        guard let input = lastInput, let frame = lastFrame,
              now >= frame, now - frame <= MouseWheelMotion.staleGap,
              now >= input else { cancel(); return 0 }
        if isResponsive && now - input >= Self.responsiveTail {
            // Discard residual movement; never flush a dense backlog as a final jump.
            cancel()
            return 0
        }
        guard integrate(at: now) else { cancel(); return 0 }
        lastFrame = now
        let velocity = abs(outputRemaining - guideRemaining) / onset
        if (abs(outputRemaining) <= 0.75 && velocity <= 8)
            || now - input >= Self.maximumTail {
            let final = Int64((fractionalOutput + outputRemaining).rounded())
            cancel()
            return final
        }
        let pixels = Int64(fractionalOutput.rounded(.towardZero))
        fractionalOutput -= Double(pixels)
        return pixels
    }

    /// Analytic integration keeps input arrivals separate from display-frame output.
    private mutating func integrate(at now: UInt64) -> Bool {
        guard let previous = lastAdvance else { return true }
        guard now >= previous, now - previous <= MouseWheelMotion.staleGap else {
            cancel()
            return false
        }
        let elapsed = Double(now - previous) / 1_000_000_000
        let guideDecay = exp(-elapsed / response)
        let onsetDecay = exp(-elapsed / onset)
        let nextOutput = outputRemaining * onsetDecay
            + guideRemaining * response / (response - onset) * (guideDecay - onsetDecay)
        fractionalOutput += outputRemaining - nextOutput
        guideRemaining *= guideDecay
        outputRemaining = nextOutput
        lastAdvance = now
        return true
    }
}

import Foundation

/// Offline production math only: no event tap, CGEvent posting, device access or UI.
@main
struct DenseWheelResponseCheck {
    struct Result: Codable {
        let framesPerSecond: Int
        let inputPointDelta: Int64
        let acceptedDistance: Int64
        let distanceDuringInput: Int64
        let distanceAfterInput: Int64
        let lastMovementAfterInputMilliseconds: Double
        let firstCounterFramePixels: Int64
    }

    static func main() throws {
        let results = [60, 120].flatMap { rate in
            [Int64(1), 10, 48, 128].map { measure(point: $0, rate: rate) }
        }
        precondition(results.allSatisfy { $0.lastMovementAfterInputMilliseconds < 220 })
        precondition(results.allSatisfy { $0.firstCounterFramePixels < 0 })
        precondition(results.filter { $0.inputPointDelta == 1 }.allSatisfy { $0.acceptedDistance == 288 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    }

    static func measure(point: Int64, rate: Int) -> Result {
        var motion = SmoothWheelMotion(), cadence = WheelInputCadence()
        var accepted: Int64 = 0, during: Int64 = 0, after: Int64 = 0
        var inputIndex: UInt64 = 0, frameIndex: UInt64 = 0
        let lastInput: UInt64 = 990_000_000
        var lastMovement = lastInput
        while inputIndex < 100 || motion.isActive {
            let inputTime = inputIndex < 100 ? inputIndex * 10_000_000 : UInt64.max
            let frameTime = frameIndex * 1_000_000_000 / UInt64(rate)
            if inputTime <= frameTime {
                let input = cadence.observe(distance: point, at: inputTime)
                let distance = MouseWheelMotion.normalizedDistance(
                    pointDelta: point, lineDelta: 1, applyMinimum: !input.isDense || input.reversed
                )!
                accepted += motion.add(distance: distance, at: inputTime,
                                       responsive: input.isDense || input.reversed,
                                       startsNewGesture: input.startsNewGesture)!
                inputIndex += 1
            } else {
                let pixels = motion.advance(at: frameTime)
                if frameTime <= lastInput { during += pixels } else { after += pixels }
                if pixels != 0 && frameTime > lastInput { lastMovement = frameTime }
                frameIndex += 1
            }
        }
        // Independently reproduce a counter while the dense stream still has a tail.
        motion.cancel(); cadence.cancel()
        for index: UInt64 in 0..<100 {
            let now = index * 10_000_000
            let input = cadence.observe(distance: point, at: now)
            let distance = MouseWheelMotion.normalizedDistance(
                pointDelta: point, lineDelta: 1, applyMinimum: !input.isDense
            )!
            _ = motion.add(distance: distance, at: now, responsive: input.isDense,
                           startsNewGesture: input.startsNewGesture)
            _ = motion.advance(at: now)
        }
        let counterTime: UInt64 = 1_000_000_000
        let counter = cadence.observe(distance: -1, at: counterTime)
        _ = motion.add(distance: -48, at: counterTime, responsive: counter.isDense || counter.reversed)
        precondition(motion.advance(at: counterTime) == 0)
        let firstCounter = motion.advance(at: counterTime + 1_000_000_000 / UInt64(rate))
        return .init(framesPerSecond: rate, inputPointDelta: point,
                     acceptedDistance: accepted, distanceDuringInput: during, distanceAfterInput: after,
                     lastMovementAfterInputMilliseconds: Double(lastMovement - lastInput) / 1_000_000,
                     firstCounterFramePixels: firstCounter)
    }
}

import Foundation

/// Offline comparison of the real ScrollFix math and a mathematical reference
/// for Mos's two per-frame response factors at the pinned research commit.
/// The reference excludes dead-zone, event rounding, routing and phase logic;
/// it is not a Mos runtime test. No CGEvent, event tap or posting is used.
private struct ResponseSummary: Codable {
    let profile: String
    let framesPerSecond: Int
    let inputDistance: Int64
    let halfDistanceMilliseconds: Double
    let ninetyPercentMilliseconds: Double
    let distanceAt200Milliseconds: Double
    let maximumFrameDistance: Double
    let distanceAfterTwoSeconds: Double
}

@main
struct WheelResponseCheck {
    static func main() throws {
        var results: [ResponseSummary] = []
        for rate in [60, 120] {
            results.append(measure(profile: "Taktil", rate: rate))
            results.append(measure(profile: "Glätten", rate: rate))
            results.append(measure(profile: "Mos reference shape", rate: rate))
        }
        let smooth = results.filter { $0.profile == "Glätten" }
        let tactile = results.filter { $0.profile == "Taktil" }
        let mos60 = results.first { $0.profile == "Mos reference shape" && $0.framesPerSecond == 60 }!
        let smooth60 = smooth.first { $0.framesPerSecond == 60 }!
        precondition(smooth.allSatisfy { $0.distanceAfterTwoSeconds == 48 })
        precondition(tactile.allSatisfy { $0.distanceAfterTwoSeconds == 48 })
        precondition(abs(smooth[0].halfDistanceMilliseconds - smooth[1].halfDistanceMilliseconds) <= 17)
        precondition(abs(smooth60.halfDistanceMilliseconds - mos60.halfDistanceMilliseconds) <= 35)
        precondition(smooth60.maximumFrameDistance < tactile[0].maximumFrameDistance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    }

    private static func measure(profile: String, rate: Int) -> ResponseSummary {
        let distance: Int64 = 48
        var tactile = MouseWheelMotion()
        var smooth = SmoothWheelMotion()
        var referenceRemaining = Double(distance)
        var referenceFiltered = 0.0
        var emitted = 0.0
        var peak = 0.0
        var half: Double?
        var ninety: Double?
        var at200 = 0.0
        if profile == "Taktil" {
            emitted = Double(tactile.add(distance: distance, at: 0)!)
            peak = emitted
        } else if profile == "Glätten" {
            _ = smooth.add(distance: distance, at: 0)
        }
        for index in 1...(rate * 2) {
            let seconds = Double(index) / Double(rate)
            let now = UInt64((seconds * 1_000_000_000).rounded())
            let frame: Double
            switch profile {
            case "Taktil": frame = Double(tactile.advance(at: now))
            case "Glätten": frame = Double(smooth.advance(at: now))
            default:
                // General discrete response equations, not imported Mos code.
                // 0.085 is its rounded default response factor; 0.23 is the
                // onset filter factor. Its filter output has a one-frame delay.
                let impulse = referenceRemaining * 0.085
                referenceRemaining -= impulse
                frame = referenceFiltered
                referenceFiltered += (impulse - referenceFiltered) * 0.23
            }
            emitted += frame
            peak = max(peak, frame)
            if half == nil && emitted >= Double(distance) * 0.5 { half = seconds * 1000 }
            if ninety == nil && emitted >= Double(distance) * 0.9 { ninety = seconds * 1000 }
            if now <= 200_000_000 { at200 = emitted }
        }
        return ResponseSummary(profile: profile, framesPerSecond: rate, inputDistance: distance,
                               halfDistanceMilliseconds: half ?? -1,
                               ninetyPercentMilliseconds: ninety ?? -1,
                               distanceAt200Milliseconds: at200,
                               maximumFrameDistance: peak, distanceAfterTwoSeconds: emitted)
    }
}

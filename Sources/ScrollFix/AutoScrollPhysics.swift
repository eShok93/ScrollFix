import CoreGraphics

/// Converts pointer displacement from a middle-click anchor into scroll-wheel pixels.
///
/// The input uses AppKit screen coordinates: positive y points up. A positive vertical
/// wheel delta scrolls up; a positive horizontal wheel delta scrolls left.
struct AutoScrollPhysics {
    struct Delta: Equatable {
        let vertical: Int32
        let horizontal: Int32
    }

    static let tickIntervalMilliseconds = 16
    static let nominalTickSeconds = Double(tickIntervalMilliseconds) / 1_000

    private static let deadZonePoints = 12.0
    private static let pixelsPerPointPerTick = 0.2
    private static let maxPixelsPerTick = 80.0
    private static let maxElapsedSeconds = 0.04
    private static let minSpeed = 0.25
    private static let maxSpeed = 3.0

    private var verticalRemainder = 0.0
    private var horizontalRemainder = 0.0

    mutating func reset() {
        verticalRemainder = 0
        horizontalRemainder = 0
    }

    /// Returns nil when this tick has no whole-pixel movement. Fractional pixels remain
    /// available for later ticks, allowing a slow pointer movement to scroll smoothly.
    mutating func tick(
        offset: CGVector,
        speed: Double = 1,
        elapsedSeconds: Double = nominalTickSeconds
    ) -> Delta? {
        let x = Double(offset.dx)
        let y = Double(offset.dy)
        guard x.isFinite, y.isFinite, speed.isFinite, speed > 0,
              elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            reset()
            return nil
        }

        // hypot avoids the intermediate overflow of x*x + y*y.
        let radius = hypot(x, y)
        guard radius.isFinite, radius > Self.deadZonePoints else {
            reset()
            return nil
        }

        let boundedSpeed = min(max(speed, Self.minSpeed), Self.maxSpeed)
        let radialPixels = min(
            (radius - Self.deadZonePoints) * Self.pixelsPerPointPerTick,
            Self.maxPixelsPerTick
        ) * boundedSpeed * (min(elapsedSeconds, Self.maxElapsedSeconds) / Self.nominalTickSeconds)

        // Divide before multiplying by speed: extreme but finite offsets stay finite.
        let vertical = y / radius * radialPixels
        let horizontal = -(x / radius) * radialPixels

        // A small carried fraction must not delay an intentional reversal.
        if (vertical > 0 && verticalRemainder < 0) || (vertical < 0 && verticalRemainder > 0) {
            verticalRemainder = 0
        }
        if (horizontal > 0 && horizontalRemainder < 0) || (horizontal < 0 && horizontalRemainder > 0) {
            horizontalRemainder = 0
        }

        let accumulatedVertical = vertical + verticalRemainder
        let accumulatedHorizontal = horizontal + horizontalRemainder
        guard accumulatedVertical.isFinite, accumulatedHorizontal.isFinite else {
            reset()
            return nil
        }

        let wholeVertical = accumulatedVertical.rounded(.towardZero)
        let wholeHorizontal = accumulatedHorizontal.rounded(.towardZero)
        // The configured cap keeps both values far inside Int32, but check before converting
        // so future tuning cannot turn malformed input into a trapping conversion.
        guard abs(wholeVertical) <= Double(Int32.max),
              abs(wholeHorizontal) <= Double(Int32.max) else {
            reset()
            return nil
        }

        verticalRemainder = accumulatedVertical - wholeVertical
        horizontalRemainder = accumulatedHorizontal - wholeHorizontal
        guard wholeVertical != 0 || wholeHorizontal != 0 else { return nil }
        return Delta(vertical: Int32(wholeVertical), horizontal: Int32(wholeHorizontal))
    }
}

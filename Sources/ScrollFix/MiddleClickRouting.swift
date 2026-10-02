import CoreGraphics

/// Keeps the original down/drag/up decision for an entire middle-button press.
/// No input access, event replay, timers, or posting.
struct MiddleClickRouting {
    static func preservesNativeModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    static func appKitAnchor(from point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, primaryDisplayHeight.isFinite,
              primaryDisplayHeight > 0 else { return nil }
        let y = primaryDisplayHeight - point.y
        guard y.isFinite else { return nil }
        return CGPoint(x: point.x, y: y)
    }

    enum Route: Equatable { case native, captured }

    private(set) var heldRoute: Route?
    private(set) var dropsLateCapturedUp = false
    var isCapturing: Bool { heldRoute == .captured }

    mutating func down(decide: () -> Route) -> Route {
        if let heldRoute { return heldRoute }
        // A new real press supersedes an old consumed press's missing release.
        dropsLateCapturedUp = false
        let route = decide()
        heldRoute = route
        return route
    }

    var dragRoute: Route { heldRoute ?? (dropsLateCapturedUp ? .captured : .native) }

    mutating func up() -> Route {
        if let route = heldRoute {
            heldRoute = nil
            dropsLateCapturedUp = false
            return route
        }
        if dropsLateCapturedUp {
            dropsLateCapturedUp = false
            return .captured
        }
        return .native
    }

    mutating func expireCapturedRelease() {
        guard isCapturing else { return }
        heldRoute = nil
        dropsLateCapturedUp = true
    }

    mutating func resetAfterTapRemoval(dropLateCapturedUp: Bool = false) {
        // A native down may already be in the target app. A restart during its
        // hold must not swallow a duplicate down or its release. If that release
        // occurred while the tap was absent, at most the next full click passes.
        if heldRoute != .native { heldRoute = nil }
        dropsLateCapturedUp = dropLateCapturedUp && heldRoute != .native
    }
}

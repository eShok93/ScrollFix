@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum MiddleClickTarget: Equatable, Sendable {
    case link, nativeControl, content, unknown

    var route: MiddleClickRouting.Route { self == .content ? .captured : .native }
}

/// The bounded walk is shared by the public AX adapter and offline fixtures.
/// Reads only roles/parents; an incomplete or slow answer preserves native input.
enum MiddleClickTargetProbe {
    static let maximumDepth = 8
    static let budgetNanoseconds: UInt64 = 30_000_000

    static func resolve<Node>(
        hitTest: () -> Node?,
        isOwnElement: (Node) -> Bool?,
        readRole: (Node) -> String?,
        readParent: (Node) -> Node?,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> MiddleClickTarget {
        let started = now()
        func withinBudget() -> Bool {
            let current = now()
            return current >= started && current - started < budgetNanoseconds
        }
        guard withinBudget(), let hit = hitTest(), withinBudget(),
              let own = isOwnElement(hit), withinBudget() else { return .unknown }
        // The nonactivating marker can be AX-visible despite ignoring mouse
        // events. Let the original click reach the window underneath it.
        if own { return .nativeControl }
        var element = hit
        for depth in 0..<maximumDepth {
            guard withinBudget(), let role = readRole(element), withinBudget() else { return .unknown }
            switch role {
            case "AXLink": return .link
            case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                 "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar", "AXToolbar",
                 "AXTabGroup", "AXTextField", "AXComboBox", "AXSlider", "AXIncrementor":
                return .nativeControl
            case "AXWebArea", "AXWindow":
                return .content
            default:
                guard depth + 1 < maximumDepth else { return .unknown }
                guard withinBudget(), let parent = readParent(element), withinBudget() else { return .unknown }
                element = parent
            }
        }
        return .unknown
    }
}

/// Created outside the event callback after autoscroll access is available.
/// AX messaging has a short per-call timeout plus a total best-effort deadline.
@MainActor
final class MiddleClickTargetResolver {
    private let systemWide = AXUIElementCreateSystemWide()
    private let boundedMessaging: Bool
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        // A system-wide timeout applies only to AX messaging in this process.
        boundedMessaging = AXUIElementSetMessagingTimeout(systemWide, 0.006) == .success
    }

    func target(at point: CGPoint) -> MiddleClickTarget {
        guard boundedMessaging, point.x.isFinite, point.y.isFinite,
              abs(point.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(point.y) <= CGFloat(Float.greatestFiniteMagnitude) else { return .unknown }
        return MiddleClickTargetProbe.resolve(
            hitTest: { () -> AXUIElement? in
                var element: AXUIElement?
                // Quartz and AX both use global top-left coordinates here.
                guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else {
                    return nil
                }
                return element
            },
            isOwnElement: { element in
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { return nil }
                return pid == ownPID
            },
            readRole: { element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
                return value as? String
            },
            readParent: { element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return (value as! AXUIElement)
            }
        )
    }
}

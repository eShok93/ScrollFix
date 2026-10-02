import Foundation

/// Public AX fallback results may arrive after activation has changed. A
/// focused element is usable only when it belongs to the confirmed target.
enum FocusedElementOwnership {
    static func accepts(expectedPID: Int32, elementPID: Int32) -> Bool {
        expectedPID > 0 && elementPID > 0 && expectedPID == elementPID
    }
}

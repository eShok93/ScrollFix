/// Permission requests happen only after an explicit feature or retry action.
/// A declined/no-op system request still leads to a visible settings page.
@MainActor
enum AutoScrollAccessRequest {
    static func check(interceptionAllowed: Bool, preflight: () -> Bool) -> Bool {
        guard interceptionAllowed else { return false }
        return preflight()
    }

    static func perform(
        interceptionAllowed: Bool,
        preflight: () -> Bool,
        request: () -> Bool,
        openSettings: () -> Void
    ) -> Bool {
        // Do not populate the Post Event cache before Accessibility is granted.
        guard interceptionAllowed else {
            openSettings()
            return false
        }
        if preflight() { return true }
        if request() { return true }
        openSettings()
        return false
    }
}

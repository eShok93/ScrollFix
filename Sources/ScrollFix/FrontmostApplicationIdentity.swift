import Foundation

/// A missing AppKit PID must never become an event-posting target. The fallback
/// accepts only an AX-focused PID whose executable matches the foreground app.
enum FrontmostApplicationIdentity {
    static func resolve(workspacePID: Int32, focusedPID: Int32,
                        expectedExecutable: String?, actualExecutable: String?) -> Int32? {
        if workspacePID > 0 { return workspacePID }
        guard focusedPID > 0,
              let expectedExecutable, !expectedExecutable.isEmpty,
              let actualExecutable, !actualExecutable.isEmpty,
              expectedExecutable == actualExecutable else { return nil }
        return focusedPID
    }
}

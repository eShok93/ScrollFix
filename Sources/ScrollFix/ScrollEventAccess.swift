@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import Dispatch

/// A UI request can carry another process's IPC attribution. Query the app's
/// own access using a public detached dispatch block, invoked synchronously.
/// The system's permission result remains authoritative; no result is cached.
@MainActor
enum ScrollEventAccess {
    private final class Result {
        var value = false
    }

    static func evaluate(_ check: @escaping @MainActor @Sendable () -> Bool) -> Bool {
        let result = Result()
        let item = DispatchWorkItem(flags: .detached) {
            MainActor.assumeIsolated { result.value = check() }
        }
        item.perform()
        return result.value
    }

    static var canPost: Bool { evaluate { CGPreflightPostEventAccess() } }

    static var accessibilityTrusted: Bool {
        evaluate {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        }
    }

    static func requestPost() -> Bool { evaluate { CGRequestPostEventAccess() } }
}

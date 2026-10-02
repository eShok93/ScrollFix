import CoreGraphics

enum KeyboardTapRecovery {
    /// Nil means an ordinary event; false means attempted recovery failed.
    static func recover(_ type: CGEventType, enable: () -> Void,
                        valid: () -> Bool, enabled: () -> Bool) -> Bool? {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return nil }
        enable()
        return valid() && enabled()
    }
}

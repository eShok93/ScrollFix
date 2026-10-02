import CoreGraphics

enum KeyboardEventEncoding {
    static let marker: Int64 = 0x53_46_4B_45_59_53_30_31

    static func modifiers(_ flags: CGEventFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        for (cg, key): (CGEventFlags, KeyModifiers) in [
            (.maskControl, .control), (.maskCommand, .command), (.maskShift, .shift),
            (.maskAlternate, .option), (.maskSecondaryFn, .function), (.maskAlphaShift, .capsLock)
        ] where flags.contains(cg) { result.insert(key) }
        return result
    }

    static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var result: CGEventFlags = []
        for (key, cg): (KeyModifiers, CGEventFlags) in [
            (.control, .maskControl), (.command, .maskCommand), (.shift, .maskShift),
            (.option, .maskAlternate), (.function, .maskSecondaryFn), (.capsLock, .maskAlphaShift)
        ] where modifiers.contains(key) { result.insert(cg) }
        return result
    }

    /// Prepare every event before consuming the original. No partial pair on
    /// allocation failure; no flagsChanged or modifier-key down events.
    static func events(for replacements: [KeyReplacement], source: CGEventSource?) -> [CGEvent]? {
        var events: [CGEvent] = []
        for replacement in replacements {
            let key: UInt16
            let modifiers: KeyModifiers
            let unicode: String?
            var keyClassFlags: CGEventFlags = []
            switch replacement {
            case let .stroke(keyCode, flags):
                key = keyCode; modifiers = flags
                // AppKit arrow bindings expect these native key-class flags,
                // independently of the shortcut's Command/Shift modifiers.
                let arrowCharacter: UInt16?
                switch keyCode {
                case 123: arrowCharacter = 0xF702
                case 124: arrowCharacter = 0xF703
                case 125: arrowCharacter = 0xF701
                case 126: arrowCharacter = 0xF700
                default: arrowCharacter = nil
                }
                if let arrowCharacter {
                    unicode = String(UnicodeScalar(arrowCharacter)!)
                    keyClassFlags = [.maskSecondaryFn, .maskNumericPad]
                } else { unicode = nil }
            case let .terminalSequence(sequence): key = 0; modifiers = []; unicode = sequence
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = flags(modifiers).union(keyClassFlags)
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                if let unicode {
                    let units = Array(unicode.utf16)
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                }
            }
            events.append(down); events.append(up)
        }
        return events
    }
}

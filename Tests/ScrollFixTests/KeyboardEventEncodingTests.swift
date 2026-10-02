import CoreGraphics
import AppKit
import XCTest
@testable import ScrollFix

final class KeyboardEventEncodingTests: XCTestCase {
    @MainActor
    func testArrowBindingsSelectOnlyCurrentLineInLocalTextView() throws {
        // Local responder only: no window, event tap or system input posting.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = "first\nsecond\nthird"
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        let event = try XCTUnwrap(KeyboardEventEncoding.events(
            for: [.stroke(keyCode: 123, modifiers: [.command, .shift])], source: nil)?.first)
        textView.interpretKeyEvents([try XCTUnwrap(NSEvent(cgEvent: event))])
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 6))
    }

    func testArrowEventsCarryNativeFunctionKeyMetadataWithoutPosting() throws {
        for (key, character): (UInt16, UInt16) in [(123, 0xF702), (124, 0xF703), (125, 0xF701), (126, 0xF700)] {
            for modifiers: KeyModifiers in [.command, [.command, .shift]] {
                let events = try XCTUnwrap(KeyboardEventEncoding.events(
                    for: [.stroke(keyCode: key, modifiers: modifiers)], source: nil))
                for event in events {
                    XCTAssertTrue(event.flags.contains(.maskSecondaryFn))
                    XCTAssertTrue(event.flags.contains(.maskNumericPad))
                    let native = try XCTUnwrap(NSEvent(cgEvent: event))
                    let expected = String(UnicodeScalar(character)!)
                    XCTAssertEqual(native.characters, expected)
                    XCTAssertEqual(native.charactersIgnoringModifiers, expected)
                    XCTAssertEqual(native.keyCode, key)
                    XCTAssertTrue(native.modifierFlags.contains(.command))
                    XCTAssertEqual(native.modifierFlags.contains(.shift), modifiers.contains(.shift))
                }
            }
        }
    }
    func testEveryReplacementHasExactlyOneDownAndUpWithIdenticalFlagsAndMarker() throws {
        for key: UInt16 in [0, 14, 123, 124, 125, 126] {
            for modifiers: KeyModifiers in [.control, .command, [.command, .shift]] {
                let events = try XCTUnwrap(KeyboardEventEncoding.events(
                    for: [.stroke(keyCode: key, modifiers: modifiers)], source: nil))
                XCTAssertEqual(events.count, 2)
                XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
                for event in events {
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(key))
                    let isArrow = (123...126).contains(key)
                    XCTAssertEqual(KeyboardEventEncoding.modifiers(event.flags),
                                   isArrow ? modifiers.union(.function) : modifiers)
                    XCTAssertEqual(event.flags.contains(.maskSecondaryFn), isArrow)
                    XCTAssertEqual(event.flags.contains(.maskNumericPad), isArrow)
                    XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), KeyboardEventEncoding.marker)
                }
            }
        }
    }

    func testEscapePayloadIsExactAndNeverPostedByTests() throws {
        for string in ["\u{1b}OH", "\u{1b}OF"] {
            let events = try XCTUnwrap(KeyboardEventEncoding.events(for: [.terminalSequence(string)], source: nil))
            XCTAssertEqual(events.count, 2)
            for event in events {
                var actual = [UniChar](repeating: 0, count: 16)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: actual.count, actualStringLength: &length, unicodeString: &actual)
                XCTAssertEqual(Array(actual.prefix(length)), Array(string.utf16))
                XCTAssertEqual(event.flags, [])
            }
        }
        XCTAssertEqual(KeyboardEventEncoding.events(for: [], source: nil)?.count, 0)
    }

    func testBothDisabledTapTypesValidateRecovery() {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            for valid in [true, false] {
                for enabled in [true, false] {
                    var attempts = 0
                    XCTAssertEqual(KeyboardTapRecovery.recover(type, enable: { attempts += 1 },
                                                              valid: { valid }, enabled: { enabled }), valid && enabled)
                    XCTAssertEqual(attempts, 1)
                }
            }
        }
        XCTAssertNil(KeyboardTapRecovery.recover(.keyDown, enable: { XCTFail("Unexpected recovery") },
                                                 valid: { true }, enabled: { true }))
    }

    func testOldStateCannotReplaceNewRecoveryStatus() {
        var inbox = KeyboardStateInbox()
        XCTAssertTrue(inbox.accept(.init(sequence: 3, running: true, issue: nil)))
        XCTAssertFalse(inbox.accept(.init(sequence: 2, running: false, issue: "Old timeout")))
        XCTAssertFalse(inbox.accept(.init(sequence: 3, running: false, issue: "Duplicate")))
        XCTAssertTrue(inbox.accept(.init(sequence: 4, running: false, issue: "Recovery failed")))
    }
}

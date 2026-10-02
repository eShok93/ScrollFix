import XCTest
@testable import ScrollFix

final class WindowsHomeEndRuleTests: XCTestCase {
    private let text = InputContext(bundleID: "com.apple.TextEdit", processID: 42, focus: .text)
    private let terminal = InputContext(bundleID: "com.apple.Terminal", processID: 43, focus: .terminal)

    func testLineDocumentSelectionAndFnMatrix() {
        let rule = WindowsHomeEndRule(settings: .init())
        for home in [true, false] {
            for document in [true, false] {
                for shift in [true, false] {
                    for fn in [true, false] {
                        var flags: KeyModifiers = []
                        if document { flags.insert(.control) }
                        if shift { flags.insert(.shift) }
                        if fn { flags.insert(.function) }
                        let expected: UInt16 = document ? (home ? 126 : 125) : (home ? 123 : 124)
                        var output: KeyModifiers = .command
                        if shift { output.insert(.shift) }
                        XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: home ? 115 : 119,
                                                        modifiers: flags), context: text),
                                       .replace([.stroke(keyCode: expected, modifiers: output)]))
                    }
                }
            }
        }
    }

    func testKnownNonTextTargetsStayNativeEvenWithAllowEntry() {
        var settings = HomeEndSettings()
        for id in ["com.apple.Safari", "com.apple.finder"] {
            settings.allowedApps.insert(id)
            let rule = WindowsHomeEndRule(settings: settings)
            for code: UInt16 in [115, 119] {
                XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: code, modifiers: .control),
                                          context: .init(bundleID: id, processID: 44, focus: .other)), .passThrough)
            }
        }
    }

    func testUnknownFocusNeedsExplicitAllowAndDenyWins() {
        let unknown = InputContext(bundleID: text.bundleID, processID: 42)
        let input = RuleInput(kind: .down, keyCode: 115)
        var settings = HomeEndSettings()
        XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: unknown), .passThrough)
        settings.allowedApps.insert(text.bundleID)
        XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: unknown),
                       .replace([.stroke(keyCode: 123, modifiers: .command)]))
        settings.excludedApps.insert(text.bundleID)
        XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: unknown), .passThrough)
    }

    func testSecureSyntheticDisabledAndOtherModifiersPassThrough() {
        let input = RuleInput(kind: .down, keyCode: 115)
        var secure = text; secure.secureInput = true
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(input, context: secure), .passThrough)
        secure = text; secure.focus = .secure
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(input, context: secure), .passThrough)
        var settings = HomeEndSettings(); settings.enabled = false
        XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: text), .passThrough)
        for flags: KeyModifiers in [.command, .option, [.control, .command]] {
            XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(
                .init(kind: .down, keyCode: 115, modifiers: flags), context: text), .passThrough)
        }
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(
            .init(kind: .down, keyCode: 115, synthetic: true), context: text), .passThrough)
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(
            .init(kind: .up, keyCode: 115), context: text), .passThrough)
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(
            .init(kind: .down, keyCode: 116), context: text), .passThrough)
    }

    func testTerminalStrategiesAreIndependentOfFn() {
        for fn: KeyModifiers in [[], .function] {
            for home in [true, false] {
                let input = RuleInput(kind: .down, keyCode: home ? 115 : 119, modifiers: fn)
                var settings = HomeEndSettings()
                XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: terminal),
                               .replace([.stroke(keyCode: home ? 0 : 14, modifiers: .control)]))
                settings.terminalStrategy = .escapeSequence
                XCTAssertEqual(WindowsHomeEndRule(settings: settings).apply(input, context: terminal),
                               .replace([.terminalSequence(home ? "\u{1b}OH" : "\u{1b}OF")]))
            }
        }
        XCTAssertEqual(WindowsHomeEndRule(settings: .init()).apply(
            .init(kind: .down, keyCode: 115, modifiers: .shift), context: terminal), .passThrough)
    }

    func testOptInTerminalSelectionProtocol() {
        var settings = HomeEndSettings()
        settings.terminalShiftSelection = .zshRegion
        let rule = WindowsHomeEndRule(settings: settings)
        for fn: KeyModifiers in [[], .function] {
            XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: 115, modifiers: [.shift, fn]), context: terminal),
                           .replace([.terminalSequence("\u{1b}[1;2H")]))
            XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: 119, modifiers: [.shift, fn]), context: terminal),
                           .replace([.terminalSequence("\u{1b}[1;2F")]))
        }
        XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: 115, modifiers: [.control, .shift]), context: terminal), .passThrough)
        XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: 115, modifiers: [.command, .shift]), context: terminal), .passThrough)
        XCTAssertEqual(rule.apply(.init(kind: .down, keyCode: 115, modifiers: .shift), context: text),
                       .replace([.stroke(keyCode: 123, modifiers: [.command, .shift])]))
    }

    func testNativePairCannotBecomeCapturedAndSyntheticDoesNotReleasePair() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        var other = text; other.focus = .other
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 115), context: other, rule: rule).result, .passThrough)
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 115), context: text, rule: rule).result, .passThrough)
        _ = routing.receive(.init(kind: .up, keyCode: 115), context: text, rule: rule)
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 115), context: text, rule: rule).result,
                       .replace([.stroke(keyCode: 123, modifiers: .command)]))
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 115, synthetic: true), context: text, rule: rule).result,
                       .passThrough)
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 115), context: other, rule: rule).result, .replace([]))
    }

    func testCapturedRepeatStopsAtFocusBoundaryAndKeyUpIsConsumed() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        _ = routing.receive(.init(kind: .down, keyCode: 119), context: text, rule: rule)
        var changed = text; changed.focus = .other
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 119), context: changed, rule: rule).result, .replace([]))
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 119), context: changed, rule: rule).result, .replace([]))
        routing.reset()
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 119), context: text, rule: rule).result, .passThrough)
    }

    func testTerminalConfigurationResourceLoads() throws {
        let config = try XCTUnwrap(TerminalAppConfiguration.load())
        XCTAssertTrue(config.terminalBundleIDs.contains("com.apple.Terminal"))
        XCTAssertTrue(config.terminalBundleIDs.contains("com.googlecode.iterm2"))
        XCTAssertTrue(config.isIntegratedTerminal(bundleID: "com.microsoft.VSCode", description: "Terminal input"))
        XCTAssertFalse(config.isIntegratedTerminal(bundleID: "com.microsoft.VSCode", description: "Editor content"))
        XCTAssertFalse(config.isIntegratedTerminal(bundleID: "com.apple.Safari", description: "Terminal input"))
    }

    func testHeldCaptureNeverResumesAfterReturningToOriginalFocus() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        let down = RuleInput(kind: .down, keyCode: 115)
        _ = routing.receive(down, context: text, rule: rule)
        var transitioned = text; transitioned.focus = .transitioning
        XCTAssertEqual(routing.receive(down, context: transitioned, rule: rule).result, .replace([]))
        XCTAssertEqual(routing.receive(down, context: text, rule: rule).result, .replace([]))
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 115), context: text, rule: rule).result, .replace([]))
        XCTAssertEqual(routing.receive(down, context: text, rule: rule).result,
                       .replace([.stroke(keyCode: 123, modifiers: .command)]))
    }

    func testExclusionDuringHoldCancelsUntilRelease() {
        var settings = HomeEndSettings()
        var routing = HomeEndRouting()
        let down = RuleInput(kind: .down, keyCode: 119)
        _ = routing.receive(down, context: text, rule: .init(settings: settings))
        settings.excludedApps.insert(text.bundleID)
        XCTAssertEqual(routing.receive(down, context: text, rule: .init(settings: settings)).result, .replace([]))
        settings.excludedApps.remove(text.bundleID)
        XCTAssertEqual(routing.receive(down, context: text, rule: .init(settings: settings)).result, .replace([]))
    }

    func testEncodingFailureKeepsOriginalPairNative() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        let down = RuleInput(kind: .down, keyCode: 115)
        _ = routing.receive(down, context: text, rule: rule)
        routing.keepNativeUntilRelease(down, context: text)
        XCTAssertEqual(routing.receive(down, context: text, rule: rule).result, .passThrough)
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 115), context: text, rule: rule).result, .passThrough)
    }

    func testUnknownRepeatAfterRestartStaysNativeUntilFreshPress() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        let repeatInput = RuleInput(kind: .down, keyCode: 115, isRepeat: true)
        XCTAssertEqual(routing.receive(repeatInput, context: text, rule: rule).result, .passThrough)
        _ = routing.receive(.init(kind: .up, keyCode: 115), context: text, rule: rule)
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 115), context: text, rule: rule).result,
                       .replace([.stroke(keyCode: 123, modifiers: .command)]))
        XCTAssertEqual(routing.receive(repeatInput, context: text, rule: rule).result,
                       .replace([.stroke(keyCode: 123, modifiers: .command)]))
    }

    func testTapRecoveryCancelsCapturedRepeatsButRetainsNativePair() {
        let rule = WindowsHomeEndRule(settings: .init())
        var routing = HomeEndRouting()
        _ = routing.receive(.init(kind: .down, keyCode: 115), context: text, rule: rule)
        var other = text; other.focus = .other
        _ = routing.receive(.init(kind: .down, keyCode: 119), context: other, rule: rule)
        routing.cancelCapturedHolds()
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 115, isRepeat: true), context: text, rule: rule).result,
                       .replace([]))
        XCTAssertEqual(routing.receive(.init(kind: .down, keyCode: 119, isRepeat: true), context: text, rule: rule).result,
                       .passThrough)
        XCTAssertEqual(routing.receive(.init(kind: .up, keyCode: 115), context: text, rule: rule).result, .replace([]))
    }
}

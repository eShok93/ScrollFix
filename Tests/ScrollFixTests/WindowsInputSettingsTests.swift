import XCTest
@testable import ScrollFix

final class WindowsInputSettingsTests: XCTestCase {
    func testFreshProductionSettingsOfferTerminalSetupAndWindowsWheelDefaults() throws {
        let name = "ScrollFix.settings.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = WindowsInputSettingsStore(defaults: defaults).load(isQA: false)
        XCTAssertTrue(settings.mouseWheelEnabled)
        XCTAssertTrue(settings.autoScrollEnabled)
        XCTAssertTrue(settings.homeEnd.enabled)
        XCTAssertEqual(settings.wheelFeel, "direct")
        XCTAssertEqual(settings.homeEnd.terminalShiftSelection, .zshRegion)
        XCTAssertEqual(TerminalSelectionSetup.effectiveSettings(settings.homeEnd, status: .needsSetup).terminalShiftSelection, .native)
        XCTAssertEqual(TerminalSelectionSetup.effectiveSettings(settings.homeEnd, status: .installed), settings.homeEnd)
    }

    func testSavedNativeTerminalPreferenceRemainsNativeAfterUpdate() throws {
        let name = "ScrollFix.settings.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WindowsInputSettingsStore(defaults: defaults)
        var original = WindowsInputSettings()
        original.homeEnd.terminalShiftSelection = .native
        store.save(original)
        XCTAssertEqual(store.load(), original)
        XCTAssertEqual(TerminalSelectionSetup.effectiveSettings(store.load().homeEnd, status: .installed).terminalShiftSelection, .native)
    }

    func testMigrationRoundTripAndSanitization() throws {
        let name = "ScrollFix.settings.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "scrollFix.enabled")
        defaults.set(false, forKey: "scrollFix.autoScrollEnabled")
        defaults.set("tactile", forKey: "scrollFix.wheelFeel")
        defaults.set(999, forKey: "scrollFix.wheelMinimumStep")
        let store = WindowsInputSettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertFalse(settings.mouseWheelEnabled)
        XCTAssertFalse(settings.autoScrollEnabled)
        XCTAssertEqual(settings.wheelFeel, "direct")
        XCTAssertEqual(settings.wheelMinimumStep, 128)
        settings.homeEnd.terminalStrategy = .escapeSequence
        settings.homeEnd.excludedApps.insert("com.example.editor")
        store.save(settings)
        defaults.set(true, forKey: "scrollFix.enabled")
        XCTAssertEqual(store.load(), settings)
        settings.wheelFeel = "invalid"; settings.wheelMinimumStep = -9
        store.save(settings)
        XCTAssertEqual(store.load().wheelFeel, "direct")
        XCTAssertEqual(store.load().wheelMinimumStep, 16)
    }

    func testHomeEndMigrationPreservesExistingPreferences() throws {
        let old = Data(#"{"enabled":false,"terminalStrategy":"escapeSequence","allowedApps":["com.apple.TextEdit"],"excludedApps":["com.example"]}"#.utf8)
        var settings = try JSONDecoder().decode(HomeEndSettings.self, from: old)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.terminalStrategy, .escapeSequence)
        XCTAssertEqual(settings.terminalShiftSelection, .native)
        XCTAssertEqual(settings.allowedApps, ["com.apple.TextEdit"])
        XCTAssertEqual(settings.excludedApps, ["com.example"])
        settings.terminalShiftSelection = .zshRegion
        XCTAssertEqual(try JSONDecoder().decode(HomeEndSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testBrokenPayloadFallsBackToLegacyPreferences() throws {
        let name = "ScrollFix.settings.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: WindowsInputSettingsStore.key)
        defaults.set("smooth", forKey: "scrollFix.wheelFeel")
        XCTAssertEqual(WindowsInputSettingsStore(defaults: defaults).load().wheelFeel, "smooth")
    }
}

import Foundation
import XCTest
@testable import ScrollFix

final class TerminalSelectionSetupTests: XCTestCase {
    func testFreshUserSetupUsesTheRealBundledModuleWithoutCheckoutPaths() throws {
        try fixture { _, home in
            let resource = try XCTUnwrap(TerminalSelectionSetup.live.resource)
            let setup = TerminalSelectionSetup(home: home, resource: resource, customStartupDirectory: nil)
            XCTAssertEqual(setup.status, .needsSetup)
            try setup.install()
            XCTAssertEqual(setup.status, .installed)
            let installed = home.appendingPathComponent("Library/Application Support/ScrollFix/terminal-selection.zsh")
            XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: resource))
            let loader = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertFalse(loader.contains(resource.path))
            XCTAssertTrue(loader.contains("$HOME/Library/Application Support/ScrollFix/terminal-selection.zsh"))
            XCTAssertNotNil(TerminalAppConfiguration.load())
        }
    }

    func testUnavailableSetupNeverEnablesTerminalEscapeTranslation() {
        var requested = HomeEndSettings()
        requested.terminalShiftSelection = .zshRegion
        requested.excludedApps = ["com.example.exclude"]
        let effective = TerminalSelectionSetup.effectiveSettings(requested, status: .unavailable("unsupported"))
        XCTAssertEqual(effective.terminalShiftSelection, .native)
        XCTAssertEqual(effective.excludedApps, requested.excludedApps)
        XCTAssertEqual(effective.enabled, requested.enabled)
    }

    private func fixture(_ action: (TerminalSelectionSetup, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("scrollfix-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let resource = home.appendingPathComponent("fixture.zsh")
        try Data("# inert test fixture\n".utf8).write(to: resource)
        try action(TerminalSelectionSetup(home: home, resource: resource, customStartupDirectory: nil), home)
    }

    func testInstallPreservesBytesAndCreatesPrivateExactBackup() throws {
        try fixture { setup, home in
            let rc = home.appendingPathComponent(".zshrc")
            let original = Data([0xff, 0x23, 0x61]) // Preserve even non-UTF8 content.
            try original.write(to: rc)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: rc.path)
            XCTAssertEqual(setup.status, .needsSetup)
            let backup = try XCTUnwrap(setup.install())
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber, 0o600)
            XCTAssertTrue(try Data(contentsOf: rc).starts(with: original))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: rc.path)[.posixPermissions] as? NSNumber, 0o640)
            XCTAssertEqual(setup.status, .installed)
        }
    }

    func testRepeatedInstallDoesNotDuplicateBlockOrBackups() throws {
        try fixture { setup, home in
            _ = try setup.install()
            let rc = home.appendingPathComponent(".zshrc")
            let original = try Data(contentsOf: rc)
            XCTAssertNil(try setup.install())
            XCTAssertEqual(try Data(contentsOf: rc), original)
            let folder = home.appendingPathComponent("Library/Application Support/ScrollFix")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("zshrc-backup-") }.count, 1)
        }
    }

    func testModuleUpdateKeepsStartupFileUnchanged() throws {
        try fixture { setup, home in
            _ = try setup.install()
            let rc = home.appendingPathComponent(".zshrc")
            let original = try Data(contentsOf: rc)
            try Data("# newer inert fixture\n".utf8).write(to: XCTUnwrap(setup.resource))
            XCTAssertEqual(setup.status, .needsSetup)
            XCTAssertNil(try setup.install())
            XCTAssertEqual(try Data(contentsOf: rc), original)
            XCTAssertEqual(setup.status, .installed)
        }
    }

    func testStartupSymlinkRejectedWithoutTouchingTarget() throws {
        try fixture { setup, home in
            let target = home.appendingPathComponent("untouched")
            try Data("original".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".zshrc"), withDestinationURL: target)
            XCTAssertThrowsError(try setup.install())
            XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        }
    }

    func testParentSymlinkRejected() throws {
        try fixture { setup, home in
            let target = home.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: target)
            XCTAssertThrowsError(try setup.install())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testCustomStartupLocationAndMalformedManagedBlockRejected() throws {
        try fixture { setup, home in
            let custom = TerminalSelectionSetup(home: home, resource: setup.resource, customStartupDirectory: "/somewhere")
            XCTAssertThrowsError(try custom.install())
            let rc = home.appendingPathComponent(".zshrc")
            let original = Data("# BEGIN ScrollFix terminal selection\nunknown configuration\n".utf8)
            try original.write(to: rc)
            XCTAssertThrowsError(try setup.install())
            XCTAssertEqual(try Data(contentsOf: rc), original)
        }
    }

    func testExistingZshenvIsNotSilentlyAssumedCompatible() throws {
        try fixture { setup, home in
            try Data("# custom shell startup\n".utf8).write(to: home.appendingPathComponent(".zshenv"))
            XCTAssertThrowsError(try setup.install())
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
        }
    }
}

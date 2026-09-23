import AppKit
import XCTest
@testable import Codenotch

@MainActor
final class DockProviderTests: XCTestCase {
    func testProviderLinksOnlyAcceptTheThreeBundledProviders() {
        for id in DockProviderCoordinator.providers.keys {
            XCTAssertEqual(DockProviderCoordinator.providerID(from: URL(string: "codenotch://provider/\(id)")!), id)
        }
        for value in ["https://provider/codex", "codenotch://settings/codex", "codenotch://provider/unknown",
                      "codenotch://provider/codex/extra", "codenotch://provider/codex?file=/tmp/test",
                      "codenotch://provider/codex#fragment", "codenotch://user@provider/codex",
                      "codenotch://provider:123/codex", "codenotch://provider/../codex"] {
            XCTAssertNil(DockProviderCoordinator.providerID(from: URL(string: value)!), value)
        }
    }

    func testDockPreferencePersistsWithoutChangingWidgetPositionOrQuotaChoices() {
        let name = "DockProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.providerDockIcons)
        preferences.notchEdge = .bottom
        preferences.notchVisibility = .alwaysShow
        preferences.setOffset(123, for: .bottom)
        preferences.providerDockIcons = true
        let restored = Preferences(defaults: defaults)
        XCTAssertTrue(restored.providerDockIcons)
        XCTAssertEqual(restored.notchEdge, .bottom)
        XCTAssertEqual(restored.offset(for: .bottom), 123)
        restored.providerDockIcons = false
        XCTAssertEqual(Preferences(defaults: defaults).offset(for: .bottom), 123)
    }

    func testReenablingDockModeInvalidatesThePreviousHelperSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DockProviderCoordinator(directory: directory)
        coordinator.update([], enabled: true, weeklyRing: .off, accent: .system)
        let previous = coordinator.session
        coordinator.update([], enabled: true, weeklyRing: .outside, accent: .system)
        XCTAssertEqual(coordinator.session, previous, "A normal reading/style update keeps its helpers")
        coordinator.stop()
        coordinator.update([], enabled: true, weeklyRing: .off, accent: .system)
        XCTAssertNotEqual(coordinator.session, previous, "Old helpers must not command the new activation")
        coordinator.stop()
    }

    func testAntigravityUsesItsExistingArchiveIdentifier() {
        XCTAssertEqual(DockProviderCoordinator.providers[AntigravityProvider().id], "Codenotch Antigravity")
    }

    func testBundledHelpersHaveDistinctIdentitiesAndNoProviderDependencies() throws {
        var ids = Set<String>()
        for (provider, name) in DockProviderCoordinator.providers {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name).app")
            let bundle = try XCTUnwrap(Bundle(url: url))
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CodenotchProviderID") as? String, provider)
            let identity = try XCTUnwrap(bundle.bundleIdentifier)
            XCTAssertNotEqual(identity, Bundle.main.bundleIdentifier)
            XCTAssertTrue(ids.insert(identity).inserted)
            let executable = try XCTUnwrap(bundle.executableURL)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
            // Minimal AppKit helper, not a duplicate of the full provider app.
            let size = try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertLessThan(size, 2_000_000)
        }
    }

    func testDockIconsRenderProviderUsageAndUnknownStatesDifferently() throws {
        let output = ProcessInfo.processInfo.environment["TREND_RENDER_DIR"]
        for (id, glyph) in [("codex", ProviderGlyph.openai), ("claude", .claude), ("gemini", .antigravity)] {
            var snapshot = ProviderSnapshot(id: id, displayName: id.capitalized, glyph: glyph,
                fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.23)], headlineID: "session")
            let first = try XCTUnwrap(DockIconRenderer.png(snapshot: snapshot, weeklyRing: .off, accent: .system))
            let image = try XCTUnwrap(NSImage(data: first))
            XCTAssertEqual(image.size.width, image.size.height)
            XCTAssertGreaterThan(image.size.width, 0)
            snapshot.windows = [LimitWindow(id: "session", label: "Session", usedFraction: 0.87)]
            let changed = try XCTUnwrap(DockIconRenderer.png(snapshot: snapshot, weeklyRing: .off, accent: .system))
            XCTAssertNotEqual(first, changed)
            if let output { try changed.write(to: URL(fileURLWithPath: output).appendingPathComponent("dock-\(id).png")) }
            snapshot.windows = []
            let unknown = try XCTUnwrap(DockIconRenderer.png(snapshot: snapshot, weeklyRing: .off, accent: .system))
            XCTAssertNotEqual(unknown, changed)
            if let output { try unknown.write(to: URL(fileURLWithPath: output).appendingPathComponent("dock-fallback-\(id).png")) }
        }
    }
}

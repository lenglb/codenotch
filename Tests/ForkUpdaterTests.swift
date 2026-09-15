import XCTest
@testable import Codenotch

@MainActor
final class ForkUpdaterTests: XCTestCase {
    func testCustomBuildDoesNotEmbedTheUnusedUpdateFramework() throws {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path))
        XCTAssertNil(NSClassFromString("SPUUpdater"))
    }

    func testCustomBuildDoesNotStartOrEnableUpstreamUpdates() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CodenotchForkBuild") as? Bool, true)
        let updater = Updater()
        updater.start()
        XCTAssertEqual(updater.outcome, .forkBuild)
        updater.automatic = true
        XCTAssertFalse(updater.automatic)
        XCTAssertNil(updater.lastChecked)
        updater.checkNow()
        XCTAssertEqual(updater.outcome, .forkBuild)
    }
}

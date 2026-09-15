import XCTest
@testable import Codenotch

@MainActor
final class ForkUpdaterTests: XCTestCase {
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

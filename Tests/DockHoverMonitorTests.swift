import XCTest
@testable import Codenotch

final class DockHoverMonitorTests: XCTestCase {
    private let allowed = ["codex": "/Applications/Codenotch.app/Contents/Helpers/Codenotch Codex.app"]

    func testAcceptsOnlyExactAllowlistedFileURL() {
        let exact = URL(fileURLWithPath: allowed["codex"]!)
        XCTAssertEqual(DockHoverMonitor.providerID(for: exact, allowedPaths: allowed), "codex")
        XCTAssertNil(DockHoverMonitor.providerID(
            for: URL(fileURLWithPath: exact.path + ".backup"), allowedPaths: allowed))
        XCTAssertNil(DockHoverMonitor.providerID(
            for: exact.deletingLastPathComponent().appendingPathComponent("Codenotch Codex"),
            allowedPaths: allowed))
    }

    func testRejectsRemoteURLEvenWhenItsPathLooksAllowlisted() throws {
        let remote = try XCTUnwrap(URL(string:
            "https://example.invalid/Applications/Codenotch.app/Contents/Helpers/Codenotch%20Codex.app"))
        let deceptive = ["codex": remote.path]
        XCTAssertNil(DockHoverMonitor.providerID(for: remote, allowedPaths: deceptive))
    }
}

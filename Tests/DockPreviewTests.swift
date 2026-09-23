import AppKit
import XCTest
@testable import Codenotch

@MainActor
final class DockPreviewTests: XCTestCase {
    private func controller(pointer: @escaping () -> CGPoint) -> ProviderDetailWindowController {
        let model = NotchViewModel()
        model.snapshots = Fixtures.trendSnapshots(now: Date())
        let defaults = UserDefaults(suiteName: "DockPreviewTests.\(UUID().uuidString)")!
        return ProviderDetailWindowController(model: model, preferences: Preferences(defaults: defaults),
            revealDelay: 0.025, dismissDelay: 0.025, pointerLocation: pointer)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(90)) }

    func testHoverDoesNotTakeKeyWindowAndSurvivesMoveIntoPreview() async throws {
        let icon = CGRect(x: 400, y: 0, width: 60, height: 60)
        var pointer = CGPoint(x: 430, y: 30)
        let subject = controller { pointer }
        defer { subject.closeAll() }
        let keyWindow = NSApp.keyWindow
        subject.hover("claude", iconFrame: icon)
        await settle()
        let preview = try XCTUnwrap(subject.panel(for: "claude"))
        XCTAssertEqual(subject.previewProviderID, "claude")
        XCTAssertTrue(preview.isVisible)
        XCTAssertFalse(preview.canBecomeKey)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        pointer = CGPoint(x: preview.frame.midX, y: preview.frame.midY)
        subject.hover(nil, iconFrame: nil)
        await settle()
        XCTAssertTrue(preview.isVisible)
        pointer = CGPoint(x: -10000, y: -10000)
        subject.hover(nil, iconFrame: nil)
        await settle()
        XCTAssertNil(subject.previewProviderID)
        XCTAssertFalse(preview.isVisible)
    }

    func testDockClickPinsSameWindowAndPreservesPositionAfterMouseLeaves() async throws {
        var pointer = CGPoint(x: 430, y: 30)
        let subject = controller { pointer }
        defer { subject.closeAll() }
        subject.hover("claude", iconFrame: CGRect(x: 400, y: 0, width: 60, height: 60))
        await settle()
        let preview = try XCTUnwrap(subject.panel(for: "claude"))
        let originalFrame = preview.frame
        subject.show("claude")
        XCTAssertTrue(subject.panel(for: "claude") === preview)
        XCTAssertTrue(subject.isPinned("claude"))
        XCTAssertTrue(preview.canBecomeKey)
        XCTAssertEqual(preview.frame, originalFrame)
        pointer = CGPoint(x: -10000, y: -10000)
        subject.hover(nil, iconFrame: nil)
        await settle()
        XCTAssertTrue(preview.isVisible)
        subject.show("claude")
        XCTAssertEqual(preview.frame, originalFrame, "Repeated Dock clicks must preserve the user's position")
    }

    func testQuickPassAndStopNeverOpenDelayedPreview() async {
        let subject = controller { CGPoint(x: 430, y: 30) }
        defer { subject.closeAll() }
        let icon = CGRect(x: 400, y: 0, width: 60, height: 60)
        subject.hover("claude", iconFrame: icon)
        subject.hover(nil, iconFrame: nil)
        await settle()
        XCTAssertNil(subject.panel(for: "claude"))
        subject.hover("claude", iconFrame: icon)
        subject.stopHover()
        await settle()
        XCTAssertNil(subject.panel(for: "claude"))
    }

    func testSwitchingProviderKeepsOnlyOneTransientWindowAndPreservesPinnedOne() async throws {
        let subject = controller { CGPoint(x: 430, y: 30) }
        defer { subject.closeAll() }
        let icon = CGRect(x: 400, y: 0, width: 60, height: 60)
        subject.hover("claude", iconFrame: icon)
        await settle()
        let first = try XCTUnwrap(subject.panel(for: "claude"))
        subject.hover("codex", iconFrame: icon)
        await settle()
        XCTAssertFalse(first.isVisible)
        XCTAssertEqual(subject.previewProviderID, "codex")
        subject.show("codex")
        subject.hover("claude", iconFrame: icon)
        await settle()
        XCTAssertTrue(subject.isPinned("codex"))
        XCTAssertTrue(subject.panel(for: "codex")?.isVisible == true)
        XCTAssertEqual(subject.previewProviderID, "claude")
    }

    func testClosingPreviewRequiresLeavingIconBeforeItReopens() async throws {
        let subject = controller { CGPoint(x: 430, y: 30) }
        defer { subject.closeAll() }
        let icon = CGRect(x: 400, y: 0, width: 60, height: 60)
        subject.hover("claude", iconFrame: icon)
        await settle()
        let panel = try XCTUnwrap(subject.panel(for: "claude"))
        panel.close()
        subject.hover("claude", iconFrame: icon)
        await settle()
        XCTAssertNil(subject.previewProviderID)
        subject.hover(nil, iconFrame: nil)
        subject.hover("claude", iconFrame: icon)
        await settle()
        XCTAssertEqual(subject.previewProviderID, "claude")
        subject.show("claude")
        subject.stopHover()
        XCTAssertTrue(subject.panel(for: "claude")?.isVisible == true)
    }

    func testPreviewPlacementForThreeDockEdgesAndSecondaryDisplay() {
        for origin in [CGPoint.zero, CGPoint(x: -1500, y: 500)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 1000))
            let visible = screen.insetBy(dx: 60, dy: 60)
            let size = CGSize(width: 300, height: 500)
            for icon in [CGRect(x: screen.midX, y: screen.minY, width: 50, height: 50),
                         CGRect(x: screen.minX, y: screen.midY, width: 50, height: 50),
                         CGRect(x: screen.maxX - 50, y: screen.midY, width: 50, height: 50)] {
                let point = ProviderDetailWindowController.previewOrigin(size: size, icon: icon, screen: screen, visible: visible)
                let result = CGRect(origin: point, size: size)
                XCTAssertTrue(visible.contains(result))
                XCTAssertFalse(result.intersects(icon))
            }
        }
    }
}

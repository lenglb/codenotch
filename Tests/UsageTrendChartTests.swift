import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class UsageTrendChartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(id: String = "codex", duration: Double = 18000) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id == "codex" ? "Codex" : "Claude", glyph: id == "codex" ? .openai : .claude,
                         fidelity: .official, status: .ok, windows: [
                            LimitWindow(id: "primary", label: duration == 604800 ? "Weekly limit" : "5h limit", usedFraction: 0.65,
                                        resetsAt: now.addingTimeInterval(duration / 2), duration: duration),
                            LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: 0.32,
                                        resetsAt: now.addingTimeInterval(302400), duration: 604800)
                         ], headlineID: "primary")
    }

    func testOnlyKnownCodexAndClaudeCyclesOfferTheChart() {
        XCTAssertTrue(snapshot().hasUsageTrend)
        XCTAssertTrue(snapshot(id: "claude").hasUsageTrend)
        XCTAssertFalse(snapshot(id: "cursor").hasUsageTrend)
        var missing = snapshot()
        missing.windows = [LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.2)]
        XCTAssertFalse(missing.hasUsageTrend)
        missing.windows = [LimitWindow(id: "primary", label: "Unknown", usedFraction: 0.2,
                                       resetsAt: now, duration: UsageHistory.retention + 1)]
        XCTAssertFalse(missing.hasUsageTrend)
    }

    func testDailyPaceHeadlineAndSavedSelectionOpenAnActualQuotaChart() throws {
        let original = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok, windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: 0.2,
                            resetsAt: now.addingTimeInterval(3600), duration: 18000),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.3,
                            resetsAt: now.addingTimeInterval(302400), duration: 604800)
            ], headlineID: "session", weeklyID: "weekly_all")
        let paced = DailyPace.apply(to: original, now: now)
        XCTAssertEqual(paced.headlineID, DailyPace.windowID)
        XCTAssertEqual(paced.trendWindows.map(\.id), ["session", "weekly_all"])
        for savedID in ["", DailyPace.windowID, "removed-window"] {
            let selected = try XCTUnwrap(paced.selectedTrendWindow(id: savedID))
            XCTAssertEqual(selected.id, "session")
            XCTAssertNotNil(UsageTrend(providerID: paced.id, window: selected, samples: [], now: now))
        }
        XCTAssertEqual(paced.selectedTrendWindow(id: "weekly_all")?.id, "weekly_all")
    }

    func testMissingMetadataCannotHideOtherAvailableWindowCharts() throws {
        var value = snapshot()
        value.windows.insert(LimitWindow(id: "no-duration", label: "Untimed", usedFraction: 0.2,
                                         resetsAt: now.addingTimeInterval(3600)), at: 0)
        value.headlineID = "no-duration"
        XCTAssertEqual(value.selectedTrendWindow(id: "no-duration")?.id, "primary")
        value.windows = [value.windows[0]]
        XCTAssertFalse(value.hasUsageTrend)
        XCTAssertNil(value.selectedTrendWindow(id: "no-duration"))
    }

    func testChartBudgetReplacesWindowRowsAndGroupsWithoutGrowingForMoreWindows() {
        let single = NotchLayout.cardHeight(windowCount: 1, hasUsageTrend: true)
        let multiple = NotchLayout.cardHeight(windowCount: 12, groupCount: 5, hasUsageTrend: true)
        XCTAssertEqual(single, multiple)
        XCTAssertEqual(single, 2 * NotchLayout.cardPadding + max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight)
                       + NotchLayout.headerToBlock + NotchLayout.usageTrendHeight, accuracy: 0.01)
    }

    func testTrendAndAccountActivityFitEveryScreenEdge() {
        for edge in NotchEdge.allCases {
            for height in [900.0, 1080.0, 1440.0] {
                let model = NotchViewModel()
                model.edge = edge
                model.screenSize = CGSize(width: 1512, height: height)
                var codex = snapshot()
                codex.tokenUsage = CodexTokenUsage()
                model.snapshots = [codex, snapshot(id: "claude"), snapshot(id: "cursor")]
                let panel = model.panelSize(cellCount: 3)
                XCTAssertLessThanOrEqual(panel.height, height, "\(edge), \(height)")
                XCTAssertLessThanOrEqual(panel.width, 1512, "\(edge), \(height)")
            }
        }
    }

    func testTrendCardRendersMeasuredAndEmptyHistoriesInBothAppearances() throws {
        let snapshot = snapshot()
        let window = snapshot.windows[0]
        let reset = try XCTUnwrap(window.resetsAt)
        let cycle = UsageSample.CycleIdentity(providerID: snapshot.id, windowID: window.id,
                                              resetsAt: reset, duration: 18000)
        let samples = (0...10).map { index in
            UsageSample(cycle: cycle, measuredAt: reset.addingTimeInterval(-18000 + Double(index) * 900),
                        remainingFraction: max(0, 1 - Double(index) * 0.065))
        }
        for dark in [true, false] {
            for populated in [true, false] {
                let view = UsageTrendSection(snapshot: snapshot, samples: populated ? samples : [], now: now)
                    .padding(NotchLayout.cardPadding)
                    .frame(width: NotchLayout.cardWidth)
                    .background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size.width, NotchLayout.cardWidth, accuracy: 1)
                XCTAssertEqual(image.size.height, NotchLayout.usageTrendHeight + 2 * NotchLayout.cardPadding, accuracy: 1)
                if let directory = ProcessInfo.processInfo.environment["TREND_RENDER_DIR"] {
                    let data = try XCTUnwrap(image.tiffRepresentation)
                    let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("trend-\(dark ? "dark" : "light")-\(populated ? "measured" : "empty").png"))
                }
            }
        }
    }

    func testWeeklyPlotAndFullTooltipRender() throws {
        let snapshot = snapshot(duration: 604800)
        let reset = try XCTUnwrap(snapshot.windows[0].resetsAt)
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: "primary", resetsAt: reset, duration: 604800)
        let samples = (0...336).map { index in
            UsageSample(cycle: cycle, measuredAt: reset.addingTimeInterval(-604800 + Double(index) * 900),
                        remainingFraction: 1 - 0.65 * Double(index) / 336)
        }
        let view = TooltipCard(snapshot: snapshot, historySamples: samples, now: now)
            .padding(20).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, NotchLayout.usageTrendHeight)
        if let directory = ProcessInfo.processInfo.environment["TREND_RENDER_DIR"] {
            let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("trend-weekly-card.png"))
        }
    }
}

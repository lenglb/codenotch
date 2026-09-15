import XCTest
@testable import Codenotch

final class UsageHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "UsageHistoryTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        value.removePersistentDomain(forName: name)
        return value
    }

    private func window(id: String = "primary", used: Double = 0.2,
                        duration: TimeInterval = 5 * 3600,
                        resetOffset: TimeInterval = 5 * 3600) -> LimitWindow {
        LimitWindow(id: id, label: "Limit", usedFraction: used,
                    resetsAt: start.addingTimeInterval(resetOffset), duration: duration)
    }

    private func snapshot(providerID: String = "codex", windows: [LimitWindow],
                          status: ProviderStatus = .ok) -> ProviderSnapshot {
        ProviderSnapshot(id: providerID, displayName: providerID, glyph: .openai,
                         fidelity: .official, status: status, windows: windows)
    }

    func testSameBucketKeepsLatestTrueTimestampAndPersists() throws {
        let defaults = defaults()
        var history = UsageHistory(defaults: defaults)
        history.record(snapshot: snapshot(windows: [window(used: 0.1)]), at: start.addingTimeInterval(10))
        history.record(snapshot: snapshot(windows: [window(used: 0.3)]), at: start.addingTimeInterval(500))

        let sample = try XCTUnwrap(history.samples.only)
        XCTAssertEqual(sample.measuredAt, start.addingTimeInterval(500))
        XCTAssertEqual(sample.remainingFraction, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(UsageHistory(defaults: defaults).samples, history.samples)
    }

    func testCyclesProfilesAndWindowsNeverMix() throws {
        var history = UsageHistory(defaults: defaults())
        history.record(snapshot: snapshot(windows: [window()]), at: start)
        history.record(snapshot: snapshot(providerID: "codex-work", windows: [window()]), at: start)
        history.record(snapshot: snapshot(providerID: "claude-client", windows: [window(id: "session")]), at: start)
        history.record(snapshot: snapshot(windows: [window(resetOffset: 10 * 3600)]),
                       at: start.addingTimeInterval(5 * 3600))

        XCTAssertEqual(history.samples.count, 4)
        XCTAssertEqual(Set(history.samples.map(\.providerID)), ["codex", "codex-work", "claude-client"])
        XCTAssertEqual(Set(history.samples.filter { $0.providerID == "codex" }.map(\.resetsAt)).count, 2)

        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: window(),
                                             samples: history.samples, now: start.addingTimeInterval(60)))
        XCTAssertEqual(trend.observed.flatMap { $0 }.count, 1)
    }

    func testTrendBuildsFutureIdealGridButNoFutureActual() throws {
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: "primary",
            resetsAt: start.addingTimeInterval(5 * 3600), duration: 5 * 3600)
        let past = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(60), remainingFraction: 0.8)
        let future = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(3600), remainingFraction: 0.5)
        let now = start.addingTimeInterval(120)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: window(),
                                             samples: [past, future], now: now))

        XCTAssertEqual(trend.start, start)
        XCTAssertEqual(trend.end, cycle.resetsAt)
        XCTAssertEqual(trend.grid.first, start)
        XCTAssertEqual(trend.grid.last, cycle.resetsAt)
        XCTAssertTrue(trend.grid.contains { $0 > now })
        XCTAssertEqual(trend.observed.flatMap { $0 }, [past])
        XCTAssertEqual(trend.idealRemaining(at: start), 1, accuracy: 0.000_001)
        XCTAssertEqual(trend.idealRemaining(at: cycle.resetsAt), 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(trend.deviation(at: past)),
                       past.remainingFraction - trend.idealRemaining(at: past.measuredAt), accuracy: 0.000_001)
    }

    func testLongOfflineGapCreatesSeparateObservedRuns() throws {
        let cycle = UsageSample.CycleIdentity(providerID: "claude", windowID: "weekly",
            resetsAt: start.addingTimeInterval(30 * 24 * 3600), duration: 30 * 24 * 3600)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 1),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(14 * 60), remainingFraction: 0.9),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(60 * 60), remainingFraction: 0.8),
        ]
        let longWindow = LimitWindow(id: "weekly", label: "Monthly", usedFraction: 0.2,
                                     resetsAt: cycle.resetsAt, duration: cycle.duration)
        let trend = try XCTUnwrap(UsageTrend(providerID: "claude", window: longWindow,
                                             samples: samples, now: cycle.resetsAt))
        XCTAssertEqual(trend.observed.map(\.count), [2, 1])
        XCTAssertEqual(trend.grid.count, 30 * 24 * 4 + 1)
    }

    func testAdjacentMeasuredBucketsRemainOneRunDespiteTimestampJitter() throws {
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: "primary",
            resetsAt: start.addingTimeInterval(5 * 3600), duration: 5 * 3600)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(1), remainingFraction: 0.9),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(29 * 60 + 59), remainingFraction: 0.8),
        ]
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: window(),
                                             samples: samples, now: start.addingTimeInterval(3600)))
        XCTAssertEqual(trend.observed.map(\.count), [2])
    }

    func testRefillWithReusedCycleIdentityDropsTheOldRun() {
        var history = UsageHistory(defaults: defaults())
        history.record(snapshot: snapshot(windows: [window(used: 0.8)]), at: start)
        history.record(snapshot: snapshot(windows: [window(used: 0.1)]),
                       at: start.addingTimeInterval(16 * 60))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.remainingFraction, 0.9)
    }

    func testTrendRejectsAnUnboundedGridAndInvalidDirectSamples() throws {
        let hostile = LimitWindow(id: "huge", label: "Huge", usedFraction: 0,
                                  resetsAt: start.addingTimeInterval(UsageHistory.retention * 2),
                                  duration: UsageHistory.retention * 2)
        XCTAssertNil(UsageTrend(providerID: "codex", window: hostile, samples: [], now: start))

        let validWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: validWindow.id,
                                              resetsAt: validWindow.resetsAt!, duration: validWindow.duration!)
        let invalid = UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 2)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: validWindow,
                                             samples: [invalid], now: start))
        XCTAssertTrue(trend.observed.isEmpty)
    }

    func testUnknownInvalidAndStaleValuesAreNeverRecorded() {
        let defaults = defaults()
        defaults.set(Data("not json".utf8), forKey: "usageHistory")
        var history = UsageHistory(defaults: defaults)
        XCTAssertTrue(history.samples.isEmpty)

        history.record(snapshot: snapshot(windows: [
            LimitWindow(id: "missing", label: "Missing", usedFraction: 0.2),
            window(id: "negative", used: -0.1),
            window(id: "too-high", used: 1.1),
            LimitWindow(id: "too-long", label: "Too long", usedFraction: 0.2,
                        resetsAt: start.addingTimeInterval(UsageHistory.retention * 2),
                        duration: UsageHistory.retention * 2),
        ]), at: start)
        history.record(snapshot: snapshot(windows: [window()], status: .stale(since: start)), at: start)
        history.record(snapshot: snapshot(providerID: "cursor", windows: [window()]), at: start)
        XCTAssertTrue(history.samples.isEmpty)
        XCTAssertNil(UsageTrend(providerID: "codex",
            window: LimitWindow(id: "x", label: "Unknown"), samples: [], now: start))
    }

    func testForgetRemovesOnlyTheSelectedProfile() {
        var history = UsageHistory(defaults: defaults())
        history.record(snapshot: snapshot(windows: [window()]), at: start)
        history.record(snapshot: snapshot(providerID: "codex-work", windows: [window()]), at: start)
        history.forget(providerID: "codex")
        XCTAssertEqual(history.samples.map(\.providerID), ["codex-work"])
    }

    func testCachedAndOutOfOrderTimestampsDoNotReplaceNewerActual() {
        var history = UsageHistory(defaults: defaults())
        let newer = start.addingTimeInterval(500)
        history.record(snapshot: snapshot(windows: [window(used: 0.3)]), at: newer)
        history.record(snapshot: snapshot(windows: [window(used: 0.8)]), at: newer)
        history.record(snapshot: snapshot(windows: [window(used: 0.9)]), at: start.addingTimeInterval(100))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.measuredAt, newer)
        XCTAssertEqual(history.samples.first?.remainingFraction, 0.7)
    }

    func testHashedAccountSwitchClearsOldProfileSamplesAcrossRelaunch() throws {
        let defaults = defaults()
        var first = UsageHistory(defaults: defaults)
        first.record(snapshot: snapshot(windows: [window(used: 0.2)]), at: start,
                     accountFingerprint: "hash-a")

        var relaunched = UsageHistory(defaults: defaults)
        relaunched.record(snapshot: snapshot(windows: [window(used: 0.1)]),
                          at: start.addingTimeInterval(16 * 60),
                          accountFingerprint: "hash-b")
        let sample = try XCTUnwrap(relaunched.samples.only)
        XCTAssertEqual(sample.cycle.accountFingerprint, "hash-b")
        XCTAssertEqual(sample.remainingFraction, 0.9)
    }

    func testTrendSelectsOnlyCurrentAccountFingerprint() throws {
        let baseWindow = window()
        let oldCycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!, accountFingerprint: "old")
        let newCycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!, accountFingerprint: "new")
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow, samples: [
            UsageSample(cycle: oldCycle, measuredAt: start, remainingFraction: 0.2),
            UsageSample(cycle: newCycle, measuredAt: start, remainingFraction: 0.9),
        ], now: start, accountFingerprint: "new"))
        XCTAssertEqual(trend.observed.flatMap { $0 }.map(\.remainingFraction), [0.9])
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

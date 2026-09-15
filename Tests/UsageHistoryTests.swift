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

    func testSameBucketKeepsFirstAndLatestTrueTimestampsAndPersists() throws {
        let defaults = defaults()
        var history = UsageHistory(defaults: defaults)
        history.record(snapshot: snapshot(windows: [window(used: 0.1)]), at: start.addingTimeInterval(10))
        history.record(snapshot: snapshot(windows: [window(used: 0.3)]), at: start.addingTimeInterval(500))

        XCTAssertEqual(history.samples.map(\.measuredAt),
                       [start.addingTimeInterval(10), start.addingTimeInterval(500)])
        XCTAssertEqual(history.samples.last!.remainingFraction, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(UsageHistory(defaults: defaults).samples, history.samples)
    }

    func testSameBucketThirdReadingReplacesOnlyTheLast() {
        var history = UsageHistory(defaults: defaults())
        for (offset, used) in [(10.0, 0.1), (300.0, 0.2), (500.0, 0.3)] {
            history.record(snapshot: snapshot(windows: [window(used: used)]),
                           at: start.addingTimeInterval(offset))
        }
        XCTAssertEqual(history.samples.map(\.measuredAt),
                       [start.addingTimeInterval(10), start.addingTimeInterval(500)])
    }

    func testTinyResetDriftRecoversPersistedCycleAndCanonicalizesNewSample() throws {
        let defaults = defaults()
        let oldCycle = UsageSample.CycleIdentity(providerID: "claude-client", windowID: "weekly_all",
            resetsAt: start.addingTimeInterval(7 * 24 * 3600), duration: 7 * 24 * 3600,
            accountFingerprint: "account")
        let old = UsageSample(cycle: oldCycle, measuredAt: start.addingTimeInterval(60),
                              remainingFraction: 0.9)
        defaults.set(try JSONEncoder().encode([old]), forKey: "usageHistory")
        var history = UsageHistory(defaults: defaults)
        let drifted = LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.2,
            resetsAt: oldCycle.resetsAt.addingTimeInterval(1.4), duration: oldCycle.duration)
        history.record(snapshot: snapshot(providerID: "claude-client", windows: [drifted]),
                       at: start.addingTimeInterval(16 * 60), accountFingerprint: "account")

        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(Set(history.samples.map(\.cycle)).count, 1)
        let trend = try XCTUnwrap(UsageTrend(providerID: "claude-client", window: drifted,
            samples: history.samples, now: start.addingTimeInterval(20 * 60),
            accountFingerprint: "account"))
        XCTAssertEqual(trend.observed.flatMap { $0 }.count, 2)
    }

    func testLegacyDriftStillRejectsOutOfOrderAndRefillClearsEveryMatchingIdentity() throws {
        let defaults = defaults()
        let reset = start.addingTimeInterval(5 * 3600)
        let cycles = [-1.0, 1.0].map {
            UsageSample.CycleIdentity(providerID: "codex", windowID: "primary",
                resetsAt: reset.addingTimeInterval($0), duration: 5 * 3600,
                accountFingerprint: "account")
        }
        let legacy = [
            UsageSample(cycle: cycles[0], measuredAt: start.addingTimeInterval(10 * 60),
                        remainingFraction: 0.5),
            UsageSample(cycle: cycles[1], measuredAt: start.addingTimeInterval(20 * 60),
                        remainingFraction: 0.4),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "usageHistory")
        var history = UsageHistory(defaults: defaults)
        let driftedWindow = LimitWindow(id: "primary", label: "Limit", usedFraction: 0.8,
            resetsAt: reset.addingTimeInterval(0.5), duration: 5 * 3600)
        history.record(snapshot: snapshot(windows: [driftedWindow]),
                       at: start.addingTimeInterval(15 * 60), accountFingerprint: "account")
        XCTAssertEqual(history.samples, legacy)

        let refill = LimitWindow(id: "primary", label: "Limit", usedFraction: 0.1,
            resetsAt: reset.addingTimeInterval(0.5), duration: 5 * 3600)
        history.record(snapshot: snapshot(windows: [refill]),
                       at: start.addingTimeInterval(30 * 60), accountFingerprint: "account")
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.remainingFraction, 0.9)
    }

    func testResetToleranceDoesNotMergeRealCycleWindowOrAccountChanges() {
        let base = UsageSample.CycleIdentity(providerID: "claude", windowID: "weekly",
            resetsAt: start, duration: 3600, accountFingerprint: "a")
        XCTAssertFalse(UsageHistory.sameCycle(base, .init(providerID: "claude", windowID: "weekly",
            resetsAt: start.addingTimeInterval(6), duration: 3600, accountFingerprint: "a")))
        XCTAssertFalse(UsageHistory.sameCycle(base, .init(providerID: "claude", windowID: "scoped",
            resetsAt: start, duration: 3600, accountFingerprint: "a")))
        XCTAssertFalse(UsageHistory.sameCycle(base, .init(providerID: "claude", windowID: "weekly",
            resetsAt: start, duration: 3600, accountFingerprint: "b")))
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


    func testLegacyDriftBucketCompactsToItsFirstAndNewestReading() throws {
        let store = defaults()
        let reset = start.addingTimeInterval(18000)
        let legacy = (0..<4).map { index in
            UsageSample(cycle: .init(providerID: "codex", windowID: "primary",
                                    resetsAt: reset.addingTimeInterval(Double(index) / 10), duration: 18000),
                        measuredAt: start.addingTimeInterval(Double(index) * 60), remainingFraction: 0.8)
        }
        store.set(try JSONEncoder().encode(legacy), forKey: "usageHistory")
        var history = UsageHistory(defaults: store)
        history.record(snapshot: snapshot(windows: [window(used: 0.3)]), at: start.addingTimeInterval(300))
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(history.samples.first?.measuredAt, start)
        XCTAssertEqual(history.samples.last?.measuredAt, start.addingTimeInterval(300))
    }

    func testForecastUsesRecentContinuousConsumptionAndClampsAtDepletion() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(30 * 60), remainingFraction: 0.8),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(45 * 60), remainingFraction: 0.65),
        ]
        let now = start.addingTimeInterval(46 * 60)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
                                             samples: samples, now: now))
        let forecast = try XCTUnwrap(trend.forecast(now: now))
        XCTAssertEqual(forecast.basis, .recent)
        XCTAssertEqual(forecast.basisDuration, 15 * 60)
        XCTAssertEqual(forecast.ratePerSecond, 0.15 / (15 * 60), accuracy: 0.000_000_1)
        XCTAssertEqual(forecast.remaining(at: forecast.origin.measuredAt), 0.65, accuracy: 0.000_001)
        XCTAssertEqual(forecast.remaining(at: try XCTUnwrap(forecast.exhaustionDate)), 0, accuracy: 0.000_001)
    }

    func testForecastFallsBackToCycleAverageWithShortHistory() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let sample = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(30 * 60),
                                 remainingFraction: 0.7)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [sample], now: sample.measuredAt))
        let forecast = try XCTUnwrap(trend.forecast(now: sample.measuredAt))
        XCTAssertEqual(forecast.basis, .cycleAverage)
        XCTAssertEqual(forecast.basisDuration, 30 * 60)
        XCTAssertEqual(forecast.ratePerSecond, 0.3 / (30 * 60), accuracy: 0.000_000_1)
    }

    func testForecastFlatUsageHasNoExhaustionDate() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 1),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(15 * 60), remainingFraction: 1),
        ]
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: samples, now: start.addingTimeInterval(15 * 60)))
        let forecast = try XCTUnwrap(trend.forecast(now: start.addingTimeInterval(15 * 60)))
        XCTAssertEqual(forecast.ratePerSecond, 0)
        XCTAssertNil(forecast.exhaustionDate)
        XCTAssertEqual(forecast.remaining(at: cycle.resetsAt), 1)
    }

    func testForecastFlatDepletedUsageIsAlreadyExhausted() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let latest = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(15 * 60),
                                 remainingFraction: 0)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 0),
            latest,
        ]
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: samples, now: latest.measuredAt))
        let forecast = try XCTUnwrap(trend.forecast(now: latest.measuredAt))
        XCTAssertEqual(forecast.ratePerSecond, 0)
        XCTAssertEqual(forecast.exhaustionDate, latest.measuredAt)
    }

    func testPersistedRefillStartsASeparateForecastRun() throws {
        let baseWindow = window()
        let reset = baseWindow.resetsAt!
        func cycle(_ drift: TimeInterval) -> UsageSample.CycleIdentity {
            .init(providerID: "codex", windowID: baseWindow.id,
                  resetsAt: reset.addingTimeInterval(drift), duration: baseWindow.duration!)
        }
        let samples = [
            UsageSample(cycle: cycle(-1), measuredAt: start.addingTimeInterval(15 * 60),
                        remainingFraction: 0.2),
            UsageSample(cycle: cycle(1), measuredAt: start.addingTimeInterval(30 * 60),
                        remainingFraction: 0.9),
            UsageSample(cycle: cycle(0), measuredAt: start.addingTimeInterval(45 * 60),
                        remainingFraction: 0.8),
        ]
        let now = start.addingTimeInterval(45 * 60)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
                                             samples: samples, now: now))
        XCTAssertEqual(trend.observed.map(\.count), [1, 2])
        let forecast = try XCTUnwrap(trend.forecast(now: now))
        XCTAssertEqual(forecast.basis, .recent)
        XCTAssertEqual(forecast.ratePerSecond, 0.1 / (15 * 60), accuracy: 0.000_000_1)
    }

    func testForecastRejectsStaleEndedAndInvalidNow() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let sample = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(60),
                                 remainingFraction: 0.9)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [sample], now: start.addingTimeInterval(16 * 60)))
        XCTAssertNil(trend.forecast(now: start.addingTimeInterval(16 * 60 + 1)))
        XCTAssertNil(trend.forecast(now: cycle.resetsAt))
        XCTAssertNil(trend.forecast(now: Date(timeIntervalSince1970: .infinity)))
    }

    func testForecastDoesNotBridgeOfflineRuns() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let latest = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(2 * 3600),
                                 remainingFraction: 0.6)
        let samples = [
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(30 * 60), remainingFraction: 0.9),
            latest,
        ]
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: samples, now: latest.measuredAt))
        XCTAssertEqual(trend.observed.map(\.count), [1, 1])
        let forecast = try XCTUnwrap(trend.forecast(now: latest.measuredAt))
        XCTAssertEqual(forecast.basis, .cycleAverage)
        XCTAssertEqual(forecast.basisDuration, 2 * 3600)
    }

    func testObservationGapsExposeLongMonotonicOfflineGap() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let before = UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 0.9)
        let after = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(31 * 60),
                                remainingFraction: 0.8)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [before, after], now: after.measuredAt))

        XCTAssertEqual(trend.observed.map(\.count), [1, 1])
        XCTAssertEqual(trend.observationGaps, [.init(before: before, after: after)])
    }

    func testObservationGapsDoNotBridgeARefill() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow, samples: [
            UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 0.2),
            UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(31 * 60), remainingFraction: 0.9),
        ], now: start.addingTimeInterval(31 * 60)))

        XCTAssertEqual(trend.observed.map(\.count), [1, 1])
        XCTAssertTrue(trend.observationGaps.isEmpty)
    }

    func testDisplayRangeFocusesRecentWeeklyHistory() throws {
        let duration = 7 * 24 * 3600.0
        let reset = start.addingTimeInterval(duration)
        let weekly = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.2,
                                 resetsAt: reset, duration: duration)
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: weekly.id,
            resetsAt: reset, duration: duration)
        let first = start.addingTimeInterval(2 * 24 * 3600)
        let readings = (0..<9).map { index in
            UsageSample(cycle: cycle, measuredAt: first.addingTimeInterval(Double(index) * 15 * 60),
                        remainingFraction: 0.9 - Double(index) * 0.02)
        }
        let now = readings.last!.measuredAt
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: weekly,
            samples: readings, now: now))
        let range = trend.displayRange(now: now, fullWindow: false)

        XCTAssertGreaterThanOrEqual(readings.last!.measuredAt.timeIntervalSince(readings.first!.measuredAt)
                                    / range.upperBound.timeIntervalSince(range.lowerBound), 0.5)
        XCTAssertEqual(trend.displayRange(now: now, fullWindow: true), trend.start...trend.end)
    }

    func testDisplayRangeFallsBackToFullWindowWithoutRecentObservations() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let now = start.addingTimeInterval(4 * 3600)
        let outdated = UsageSample(cycle: cycle, measuredAt: start, remainingFraction: 0.9)
        let oldTrend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [outdated], now: now))
        let emptyTrend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [], now: now))

        XCTAssertEqual(oldTrend.displayRange(now: now, fullWindow: false), oldTrend.start...oldTrend.end)
        XCTAssertEqual(emptyTrend.displayRange(now: now, fullWindow: false), emptyTrend.start...emptyTrend.end)
    }

    func testDisplayRangeIsBoundedWhenNowIsOutsideTheCycle() throws {
        let baseWindow = window()
        let cycle = UsageSample.CycleIdentity(providerID: "codex", windowID: baseWindow.id,
            resetsAt: baseWindow.resetsAt!, duration: baseWindow.duration!)
        let sample = UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(60), remainingFraction: 0.9)
        let trend = try XCTUnwrap(UsageTrend(providerID: "codex", window: baseWindow,
            samples: [sample], now: baseWindow.resetsAt!))

        for now in [start.addingTimeInterval(-3600), baseWindow.resetsAt!.addingTimeInterval(3600)] {
            let range = trend.displayRange(now: now, fullWindow: false)
            XCTAssertGreaterThan(range.upperBound, range.lowerBound)
            XCTAssertGreaterThanOrEqual(range.lowerBound, trend.start)
            XCTAssertLessThanOrEqual(range.upperBound, trend.end)
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

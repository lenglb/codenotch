import Foundation

/// One provider-confirmed percentage reading, tied to the exact quota cycle it
/// belongs to. The timestamp is the fetch time, never a display-grid boundary.
struct UsageSample: Codable, Equatable, Identifiable, Sendable {
    struct CycleIdentity: Codable, Equatable, Hashable, Sendable {
        let providerID: String
        let windowID: String
        let resetsAt: Date
        let duration: TimeInterval
        /// A one-way hash supplied by the provider. Nil keeps older persisted
        /// samples decodable, but never claims two unidentified accounts match.
        var accountFingerprint: String? = nil
    }

    let cycle: CycleIdentity
    let measuredAt: Date
    let remainingFraction: Double

    var id: String {
        "\(cycle.providerID)|\(cycle.windowID)|\(cycle.resetsAt.timeIntervalSince1970)|\(measuredAt.timeIntervalSince1970)"
    }

    var providerID: String { cycle.providerID }
    var windowID: String { cycle.windowID }
    var resetsAt: Date { cycle.resetsAt }
    var duration: TimeInterval { cycle.duration }
}

/// Persistent, bounded quota measurements. It deliberately stores only the
/// quantities needed for a trend, separate from the last-good UI archive.
struct UsageHistory {
    static let resolution: TimeInterval = 15 * 60
    static let resetTolerance: TimeInterval = 5
    static let retention: TimeInterval = 120 * 24 * 60 * 60
    static let maximumSamples = 12_000

    private let defaults: UserDefaults?
    private let key: String
    private(set) var samples: [UsageSample]

    /// Production uses the app domain. XCTest gets a run-local disposable
    /// suite so an existing store test that only injects `UsageArchive` cannot
    /// touch the user's real trend history as a side effect.
    static func applicationDefault(processInfo: ProcessInfo = .processInfo) -> UsageHistory {
        guard processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTest.XCTestCase") != nil
                || NSClassFromString("XCTestCase") != nil
        else { return UsageHistory(defaults: .standard) }
        return UsageHistory(defaults: nil)
    }

    init(defaults: UserDefaults? = .standard, key: String = "usageHistory") {
        self.defaults = defaults
        self.key = key
        samples = Self.decode(defaults?.data(forKey: key))
    }

    mutating func record(snapshot: ProviderSnapshot, at measuredAt: Date,
                         accountFingerprint: String? = nil) {
        guard case .ok = snapshot.status,
              measuredAt.timeIntervalSince1970.isFinite,
              CodexProfile.isCodex(providerID: snapshot.id)
                || ClaudeProfile.isClaude(providerID: snapshot.id)
        else { return }

        for window in snapshot.windows {
            guard let used = window.usedFraction,
                  used.isFinite, (0...1).contains(used),
                  let resetsAt = window.resetsAt,
                  resetsAt.timeIntervalSince1970.isFinite,
                  let duration = window.duration,
                  duration.isFinite, duration > 0, duration <= Self.retention,
                  measuredAt <= resetsAt,
                  measuredAt >= resetsAt.addingTimeInterval(-duration)
            else { continue }

            let reportedCycle = UsageSample.CycleIdentity(
                providerID: snapshot.id, windowID: window.id,
                resetsAt: resetsAt, duration: duration,
                accountFingerprint: accountFingerprint
            )
            // Some providers derive resetsAt from a rounded countdown. Reuse
            // the persisted identity for tiny clock drift without joining real
            // cycles or unidentified accounts.
            let cycle = samples.last(where: {
                Self.sameCycle($0.cycle, reportedCycle)
            })?.cycle ?? reportedCycle
            let sample = UsageSample(cycle: cycle, measuredAt: measuredAt,
                                     remainingFraction: 1 - used)
            if let accountFingerprint {
                // This is also the relaunch-safe account-switch path: samples
                // carry only the provider's one-way fingerprint, never its raw
                // account label or organization id.
                samples.removeAll {
                    $0.providerID == snapshot.id
                        && $0.cycle.accountFingerprint != accountFingerprint
                }
            }
            // A cached response can be returned repeatedly, or arrive after a
            // newer request. Neither is a new observation.
            if let latest = samples.last(where: { Self.sameCycle($0.cycle, cycle) }),
               measuredAt <= latest.measuredAt {
                continue
            }
            // A provider may reuse a reset timestamp while beginning a fresh
            // allowance. Do not draw the old, depleted cycle into the refill.
            if let previous = samples.last(where: { Self.sameCycle($0.cycle, cycle) }),
               sample.remainingFraction > previous.remainingFraction + 0.001 {
                samples.removeAll { Self.sameCycle($0.cycle, cycle) }
            }
            // Keep the first and last real observation in each display bucket.
            // The first pair forms a curve immediately; later polling only
            // replaces the bucket's last point.
            let bucket = floor(measuredAt.timeIntervalSince1970 / Self.resolution)
            let bucketIndices = samples.indices.filter {
                Self.sameCycle(samples[$0].cycle, cycle)
                    && floor(samples[$0].measuredAt.timeIntervalSince1970 / Self.resolution) == bucket
            }
            // Legacy jitter may have left more than two identities in a
            // bucket. Compact all but its first reading before appending.
            for index in bucketIndices.dropFirst().reversed() {
                samples.remove(at: index)
            }
            samples.append(sample)
        }
        prune(reference: measuredAt)
        save()
    }

    mutating func forget(providerID: String) {
        let oldCount = samples.count
        samples.removeAll { $0.providerID == providerID }
        if samples.count != oldCount { save() }
    }

    private mutating func prune(reference: Date) {
        let cutoff = reference.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.measuredAt < cutoff }
        samples.sort { $0.measuredAt < $1.measuredAt }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults?.set(data, forKey: key)
    }

    static func sameCycle(_ lhs: UsageSample.CycleIdentity,
                          _ rhs: UsageSample.CycleIdentity) -> Bool {
        lhs.providerID == rhs.providerID
            && lhs.windowID == rhs.windowID
            && lhs.accountFingerprint == rhs.accountFingerprint
            && abs(lhs.duration - rhs.duration) <= resetTolerance
            && abs(lhs.resetsAt.timeIntervalSince(rhs.resetsAt)) <= resetTolerance
    }

    private static func decode(_ data: Data?) -> [UsageSample] {
        guard let data, let decoded = try? JSONDecoder().decode([UsageSample].self, from: data) else {
            return []
        }
        let valid = decoded.filter { sample in
            sample.measuredAt.timeIntervalSince1970.isFinite
                && sample.resetsAt.timeIntervalSince1970.isFinite
                && sample.duration.isFinite && sample.duration > 0 && sample.duration <= retention
                && sample.remainingFraction.isFinite
                && (0...1).contains(sample.remainingFraction)
                && sample.measuredAt <= sample.resetsAt
                && sample.measuredAt >= sample.resetsAt.addingTimeInterval(-sample.duration)
        }.sorted { $0.measuredAt < $1.measuredAt }
        guard let newest = valid.last?.measuredAt else { return [] }
        let cutoff = newest.addingTimeInterval(-retention)
        return Array(valid.filter { $0.measuredAt >= cutoff }.suffix(maximumSamples))
    }
}

/// Chart-ready pacing for one live window. Ideal data may extend to the reset;
/// observations contain only actual readings at or before `now`.
struct UsageTrend: Equatable {
    struct ObservationGap: Equatable {
        let before: UsageSample
        let after: UsageSample
    }

    let cycle: UsageSample.CycleIdentity
    let start: Date
    let end: Date
    let grid: [Date]
    /// Separate runs so a chart cannot draw through a long offline gap.
    let observed: [[UsageSample]]

    init?(providerID: String, window: LimitWindow, samples: [UsageSample], now: Date,
          accountFingerprint: String? = nil) {
        guard let end = window.resetsAt,
              end.timeIntervalSince1970.isFinite,
              let duration = window.duration,
              duration.isFinite, duration > 0, duration <= UsageHistory.retention,
              now.timeIntervalSince1970.isFinite
        else { return nil }
        let start = end.addingTimeInterval(-duration)
        let cycle = UsageSample.CycleIdentity(providerID: providerID, windowID: window.id,
                                              resetsAt: end, duration: duration,
                                              accountFingerprint: accountFingerprint)
        self.cycle = cycle
        self.start = start
        self.end = end

        var dates: [Date] = [start]
        var date = Date(timeIntervalSince1970:
            ceil(start.timeIntervalSince1970 / UsageHistory.resolution) * UsageHistory.resolution)
        while date < end {
            if date > start { dates.append(date) }
            date = date.addingTimeInterval(UsageHistory.resolution)
        }
        if dates.last != end { dates.append(end) }
        grid = dates

        let actual = samples.filter {
            UsageHistory.sameCycle($0.cycle, cycle)
                && $0.measuredAt >= start.addingTimeInterval(-UsageHistory.resetTolerance)
                && $0.measuredAt <= min(now, end)
                && $0.remainingFraction.isFinite
                && (0...1).contains($0.remainingFraction)
        }.sorted { $0.measuredAt < $1.measuredAt }
        var runs: [[UsageSample]] = []
        for sample in actual {
            if let previous = runs.last?.last,
               sample.remainingFraction <= previous.remainingFraction + 0.001,
               Self.bucket(of: sample.measuredAt) - Self.bucket(of: previous.measuredAt) <= 1 {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        observed = runs
    }

    private static func bucket(of date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / UsageHistory.resolution))
    }

    /// Discontinuities between real readings that a chart should render as a
    /// gap. An allowance refill is deliberately excluded: it starts a new run
    /// but must never look like a missing-data bridge.
    var observationGaps: [ObservationGap] {
        guard observed.count > 1 else { return [] }
        return zip(observed, observed.dropFirst()).compactMap { beforeRun, afterRun in
            guard let before = beforeRun.last,
                  let after = afterRun.first,
                  after.remainingFraction <= before.remainingFraction + 0.001
            else { return nil }
            return ObservationGap(before: before, after: after)
        }
    }

    /// The full quota window, or a focused range around recent observations.
    /// If the retained history is older than six hours, retain the full window
    /// so that the focused view cannot make all actual readings disappear.
    func displayRange(now: Date, fullWindow: Bool) -> ClosedRange<Date> {
        guard !fullWindow,
              now.timeIntervalSince1970.isFinite,
              !observed.isEmpty
        else { return start...end }

        let clampedNow = min(max(now, start), end)
        let actual = observed.flatMap { $0 }.filter { $0.measuredAt <= clampedNow }
        guard let earliestObservedAt = actual.first?.measuredAt,
              let latestObservedAt = actual.last?.measuredAt,
              latestObservedAt >= clampedNow.addingTimeInterval(-6 * 3600)
        else { return start...end }

        let lower = max(start, max(clampedNow.addingTimeInterval(-6 * 3600),
                                   earliestObservedAt.addingTimeInterval(-900)))
        let futurePadding = max(900, min(3600,
            clampedNow.timeIntervalSince(lower) * 0.25))
        let upper = min(end, clampedNow.addingTimeInterval(futurePadding))
        guard lower < upper else { return start...end }
        return lower...upper
    }

    func idealRemaining(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(start)
        return min(max(1 - elapsed / cycle.duration, 0), 1)
    }

    /// Positive means more quota remains than an even pace would leave.
    func deviation(at sample: UsageSample) -> Double? {
        guard UsageHistory.sameCycle(sample.cycle, cycle) else { return nil }
        return sample.remainingFraction - idealRemaining(at: sample.measuredAt)
    }

    struct Forecast: Equatable {
        enum Basis: Equatable { case recent, cycleAverage }

        let origin: UsageSample
        let ratePerSecond: Double
        let basis: Basis
        let basisDuration: TimeInterval
        let exhaustionDate: Date?

        func remaining(at date: Date) -> Double {
            min(max(origin.remainingFraction
                    - ratePerSecond * max(0, date.timeIntervalSince(origin.measuredAt)), 0), 1)
        }
    }

    func forecast(now: Date) -> Forecast? {
        guard now.timeIntervalSince1970.isFinite, now < end,
              let run = observed.last, let latest = run.last,
              now.timeIntervalSince(latest.measuredAt) >= 0,
              now.timeIntervalSince(latest.measuredAt) <= UsageHistory.resolution
        else { return nil }

        let recentCutoff = latest.measuredAt.addingTimeInterval(-60 * 60)
        let recent = run.filter { $0.measuredAt >= recentCutoff }
        let firstRecent = recent.first
        let recentDuration = firstRecent.map { latest.measuredAt.timeIntervalSince($0.measuredAt) } ?? 0

        let rate: Double
        let basis: Forecast.Basis
        let basisDuration: TimeInterval
        if let firstRecent, recentDuration >= UsageHistory.resolution {
            rate = max(0, (firstRecent.remainingFraction - latest.remainingFraction) / recentDuration)
            basis = .recent
            basisDuration = recentDuration
        } else {
            let elapsed = latest.measuredAt.timeIntervalSince(start)
            guard elapsed > 0 else { return nil }
            rate = max(0, (1 - latest.remainingFraction) / elapsed)
            basis = .cycleAverage
            basisDuration = elapsed
        }
        guard rate.isFinite else { return nil }
        let exhaustion: Date?
        if latest.remainingFraction <= 0 {
            exhaustion = latest.measuredAt
        } else if rate > 0 {
            let interval = latest.remainingFraction / rate
            exhaustion = interval.isFinite ? latest.measuredAt.addingTimeInterval(interval) : nil
        } else {
            exhaustion = nil
        }
        return Forecast(origin: latest, ratePerSecond: rate, basis: basis,
                        basisDuration: basisDuration, exhaustionDate: exhaustion)
    }
}

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

            let cycle = UsageSample.CycleIdentity(
                providerID: snapshot.id, windowID: window.id,
                resetsAt: resetsAt, duration: duration,
                accountFingerprint: accountFingerprint
            )
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
            if let latest = samples.last(where: { $0.cycle == cycle }),
               measuredAt <= latest.measuredAt {
                continue
            }
            // A provider may reuse a reset timestamp while beginning a fresh
            // allowance. Do not draw the old, depleted cycle into the refill.
            if let previous = samples.last(where: { $0.cycle == cycle }),
               sample.remainingFraction > previous.remainingFraction + 0.001 {
                samples.removeAll { $0.cycle == cycle }
            }
            // Keep the newest real observation in a display-resolution bucket.
            // This reduces polling noise without pretending it was measured at
            // the bucket boundary.
            let bucket = floor(measuredAt.timeIntervalSince1970 / Self.resolution)
            samples.removeAll {
                $0.cycle == cycle
                    && floor($0.measuredAt.timeIntervalSince1970 / Self.resolution) == bucket
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
            $0.cycle == cycle && $0.measuredAt >= start
                && $0.measuredAt <= min(now, end)
                && $0.remainingFraction.isFinite
                && (0...1).contains($0.remainingFraction)
        }.sorted { $0.measuredAt < $1.measuredAt }
        var runs: [[UsageSample]] = []
        for sample in actual {
            if let previous = runs.last?.last,
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

    func idealRemaining(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(start)
        return min(max(1 - elapsed / cycle.duration, 0), 1)
    }

    /// Positive means more quota remains than an even pace would leave.
    func deviation(at sample: UsageSample) -> Double? {
        guard sample.cycle == cycle else { return nil }
        return sample.remainingFraction - idealRemaining(at: sample.measuredAt)
    }
}

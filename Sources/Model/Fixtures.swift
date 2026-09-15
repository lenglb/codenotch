import Foundation

/// The three providers from the design frame, at the levels it shows.
/// These stand in until the adapters in M4 land.
enum Fixtures {
    static func snapshots(now: Date = Date(), calendar: Calendar = .current) -> [ProviderSnapshot] {
        let sessionReset = now.addingTimeInterval(51 * 60)
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(24 * 60 * 60))

        return [
            ProviderSnapshot(
                id: "claude",
                displayName: "Claude",
                glyph: .claude,
                fidelity: .derived,
                status: .ok,
                windows: [
                    LimitWindow(id: "claude.session", label: L10n.t("Current session"),
                                usedFraction: 0.73, resetsAt: sessionReset),
                    LimitWindow(id: "claude.all", label: L10n.t("All models"),
                                usedFraction: 0.07, resetsAt: midnight)
                ]
            ),
            ProviderSnapshot(
                id: "openai",
                displayName: "OpenAI",
                glyph: .openai,
                fidelity: .manual,
                status: .ok,
                windows: [
                    LimitWindow(id: "openai.session", label: L10n.t("Current session"),
                                usedFraction: 0.21, resetsAt: now.addingTimeInterval(3 * 60 * 60))
                ]
            ),
            ProviderSnapshot(
                id: "third",
                displayName: "Perplexity",
                glyph: .third,
                fidelity: .manual,
                status: .ok,
                windows: [
                    LimitWindow(id: "third.daily", label: L10n.t("Daily quota"),
                                usedFraction: 0.52, resetsAt: midnight)
                ]
            )
        ]
    }
}

extension Fixtures {
    /// Opt-in native interaction fixture: no provider or credential is loaded.
    static func trendSnapshots(now: Date = Date()) -> [ProviderSnapshot] {
        ["codex", "claude"].map { id in
            ProviderSnapshot(id: id, displayName: id == "codex" ? "Codex · Demo" : "Claude · Demo",
                             glyph: id == "codex" ? .openai : .claude,
                             fidelity: .manual, status: .ok, windows: [
                                LimitWindow(id: id == "codex" ? "primary" : "session", label: L10n.t("5h limit"), usedFraction: 0.65,
                                            resetsAt: now.addingTimeInterval(9000), duration: 18000),
                                LimitWindow(id: id == "codex" ? "secondary" : "weekly_all", label: L10n.t("Weekly limit"), usedFraction: 0.32,
                                            resetsAt: now.addingTimeInterval(302400), duration: 604800),
                                LimitWindow(id: "weekly_fable", group: "Fable", label: L10n.t("Weekly limit"),
                                            usedFraction: 0.58, resetsAt: now.addingTimeInterval(302400), duration: 604800)
                             ], headlineID: "primary", weeklyID: "secondary")
        }
    }

    static func trendHistory(for snapshots: [ProviderSnapshot], now: Date) -> [UsageSample] {
        snapshots.flatMap { snapshot in
            snapshot.windows.flatMap { window -> [UsageSample] in
                guard let end = window.resetsAt, let duration = window.duration,
                      let used = window.usedFraction else { return [] }
                let start = end.addingTimeInterval(-duration)
                let count = Int(now.timeIntervalSince(start) / 900)
                let cycle = UsageSample.CycleIdentity(providerID: snapshot.id, windowID: window.id,
                                                      resetsAt: end, duration: duration)
                return (0...count).map { index in
                    let progress = Double(index) / Double(max(count, 1))
                    let consumed = used * (0.75 * progress + 0.25 * progress * progress)
                    return UsageSample(cycle: cycle, measuredAt: start.addingTimeInterval(Double(index) * 900),
                                       remainingFraction: 1 - consumed)
                }
            }
        }
    }
}

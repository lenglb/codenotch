import Foundation
import Combine

/// This personal fork is updated from its repository. Keeping an unused
/// Sparkle dependency still makes dyld load it before application startup,
/// which rejects its signature in an ad-hoc signed hardened-runtime build.
@MainActor
final class Updater: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case forkBuild
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle:          return nil
            case .forkBuild:     return L10n.t("This custom build is updated from your fork.")
            case .checking:      return L10n.t("Checking…")
            case .upToDate:      return L10n.t("Codenotch is up to date.")
            case .found(let v):  return L10n.t("Version \(v) is available and will install shortly.")
            case .unreachable:
                // The one people actually hit, and the one Sparkle's wording
                // hides: nothing is wrong with the app or the machine.
                return L10n.t("Couldn't reach the update server. Codenotch will try again on its own — nothing is wrong with this copy.")
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle

    var automatic: Bool {
        get { false }
        set { }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var lastChecked: Date? { nil }
    func start() { outcome = .forkBuild }
    func checkNow() { outcome = .forkBuild }
}

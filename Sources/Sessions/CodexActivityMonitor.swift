import AppKit
import Combine
import Foundation

/// The small, stable part of a Codex rollout that is useful for activity.
///
/// `item_completed` is intentionally ignored: commands and other child items
/// emit it too. A turn is complete only after Codex writes `task_complete`.
struct CodexRolloutActivity {
    enum State: Equatable {
        case busy
        case success
    }

    /// Read backwards in bounded chunks: only the last lifecycle event matters.
    /// Splitting UTF-8 bytes avoids repeatedly decoding entire, potentially huge
    /// conversations on the main thread. JSON still validates every candidate.
    static func state(from url: URL) -> State? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        do {
            var offset = try file.seekToEnd()
            var fragments: [Data] = []
            func event() -> (found: Bool, state: State?) {
                defer { fragments.removeAll(keepingCapacity: true) }
                let line = fragments.reversed().reduce(into: Data()) { $0.append($1) }
                guard lifecycleNames.contains(where: { line.range(of: $0) != nil }),
                      let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      record["type"] as? String == "event_msg",
                      let payload = record["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { return (false, nil) }
                switch type {
                case "task_started": return (true, .busy)
                case "task_complete": return (true, .success)
                case "turn_aborted": return (true, nil)
                default: return (false, nil)
                }
            }
            while offset > 0 {
                let count = Int(min(offset, 64 * 1024))
                offset -= UInt64(count)
                try file.seek(toOffset: offset)
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { return nil }
                var end = chunk.endIndex
                for index in chunk.indices.reversed() where chunk[index] == 10 {
                    fragments.append(Data(chunk[(index + 1)..<end]))
                    let result = event()
                    if result.found { return result.state }
                    end = index
                }
                fragments.append(Data(chunk[..<end]))
            }
            return event().state
        } catch {
            return nil
        }
    }

    private static let lifecycleNames = ["task_started", "task_complete", "turn_aborted"]
        .map { Data($0.utf8) }

    /// Instance-scoped cache: profiles never share results. Replacement and
    /// truncation invalidate it even when the rollout path remains the same.
    final class Reader {
        private struct Signature: Equatable {
            let url: URL
            let size: UInt64
            let inode: UInt64
            let modified: Date
            let created: Date?
        }
        private var signature: Signature?
        private var cached: State?
        private let scan: (URL) -> State?

        init(scan: @escaping (URL) -> State? = CodexRolloutActivity.state) {
            self.scan = scan
        }

        func state(from url: URL) -> State? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                signature = nil
                cached = nil
                return nil
            }
            let next = Signature(url: url, size: size.uint64Value, inode: inode.uint64Value,
                                 modified: modified, created: attributes[.creationDate] as? Date)
            if signature == next { return cached }
            cached = scan(url)
            signature = next
            return cached
        }
    }

}

/// Reports whether Codex is mid-turn.
///
/// Codex does not publish a live status field, but its rollout includes
/// lifecycle events. `task_started` and `task_complete` are used when present;
/// the file's recent modification time remains the activity fallback.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. A stale rollout is deliberately not
/// converted into `.success` or `.idle`, because inactivity is not evidence
/// that a Codex turn completed — a long-running command can be quiet too.
/// If Codex grows a real status field this should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?
    private let rolloutReader = CodexRolloutActivity.Reader()

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        guard timer == nil else { return }
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        timer.tolerance = min(0.2, interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter, profile: profile, rolloutState: rolloutReader.state)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default(),
                     rolloutState: (URL) -> CodexRolloutActivity.State? = CodexRolloutActivity.state) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date, state: AgentSession.State)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date,
           now.timeIntervalSince(modified) <= staleAfter {
            let state: AgentSession.State
            switch rolloutState(rollout) {
            case .success: state = .success
            case .busy, .none: state = .busy
            }
            candidates.append((id: "\(profile.id).\(rollout.lastPathComponent)",
                               name: profile.displayName, at: modified, state: state))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "\(profile.id).desktop", name: desktop.title,
                               at: desktop.updatedAt, state: .busy))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, state: newest.state,
                                    staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }

        return AgentSession(
            id: id,
            name: name,
            detail: state == .success ? L10n.t("Complete") : L10n.t("Working"),
            state: state,
            waitingFor: nil,
            since: modified
        )
    }
}

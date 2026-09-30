import Foundation
import Observation
import VintedCore

/// One agent run shown in the app.
@MainActor
@Observable
final class AgentJob: Identifiable {
    enum State: Equatable { case running, succeeded, failed, cancelled }

    let id = UUID()
    let kind: AgentKind
    let task: AgentTask
    let startedAt = Date()
    private(set) var events: [AgentEvent] = []
    private(set) var state: State = .running
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var costUSD: Double?
    private(set) var finishedAt: Date?

    private let run: AgentRun

    init(kind: AgentKind, task: AgentTask, run: AgentRun) {
        self.kind = kind
        self.task = task
        self.run = run
    }

    /// What the agent is doing right now, or how the run ended.
    var currentStep: String {
        for event in events.reversed() {
            switch event {
            case .tool(let name, let detail): return detail.isEmpty ? name : "\(name) \(detail)"
            case .message(let text):
                if state == .running, let line = text.split(separator: "\n").first { return String(line) }
            case .finished(let summary, let isError, _):
                if isError { return summary ?? "Failed" }
            case .notice(let text): return text
            case .started: break
            }
            if state != .running { break }
        }
        switch state {
        case .running: return events.isEmpty ? "Starting…" : "Working…"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    func start() async {
        for await event in run.events() {
            events.append(event)
            switch event {
            case .started(let session, let model):
                sessionID = session
                self.model = model
            case .finished(_, let isError, let cost):
                costUSD = cost
                if state != .cancelled { state = isError ? .failed : .succeeded }
            default:
                break
            }
        }
        if state == .running { state = .failed }
        finishedAt = Date()
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        run.cancel()
    }
}

/// Settings and readiness are loaded from the Rust CLI. The app only displays them.
@MainActor
@Observable
final class AgentStore {
    var configs: [AgentKind: AgentConfig] = [:] { didSet { if !loading { persistConfigs(from: oldValue) } } }
    var defaultKind: AgentKind = .claude { didSet { if !loading && oldValue != defaultKind { persist("default", defaultKind.rawValue) } } }
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    private(set) var isChecking = false
    private(set) var jobs: [AgentJob] = []

    private var repository: VintedRepository?
    private var loading = false
    private var pendingSave: Task<Void, Never>?

    func use(_ repository: VintedRepository) {
        self.repository = repository
        statuses = [:]
        jobs = []
        Task {
            await migrateLegacySettings(repository: repository)
            await refreshStatus()
        }
    }

    func config(_ kind: AgentKind) -> AgentConfig { configs[kind] ?? AgentConfig(kind: kind) }
    func status(_ kind: AgentKind) -> AgentStatus? { statuses[kind] }
    var readyKinds: [AgentKind] { AgentKind.allCases.filter { statuses[$0]?.isReady == true } }
    var preferredKind: AgentKind? { statuses[defaultKind]?.isReady == true ? defaultKind : readyKinds.first }
    var runningCount: Int { jobs.filter { $0.state == .running }.count }
    var isClustering: Bool {
        jobs.contains { job in
            guard job.state == .running else { return false }
            if case .clusterPhotos = job.task { return true }
            return false
        }
    }
    var lastClusteringJob: AgentJob? {
        jobs.first { if case .clusterPhotos = $0.task { return true }; return false }
    }
    func job(_ id: AgentJob.ID) -> AgentJob? { jobs.first { $0.id == id } }

    func refreshStatus() async {
        guard let repository else { return }
        isChecking = true
        defer { isChecking = false }
        await pendingSave?.value
        do {
            let snapshot = try await AgentSnapshot.load(repository: repository)
            guard self.repository == repository else { return }
            loading = true
            configs = snapshot.configs
            defaultKind = snapshot.defaultKind
            statuses = snapshot.statuses
            loading = false
        } catch {
            statuses = [:]
        }
    }

    @discardableResult
    func start(_ task: AgentTask, kind: AgentKind? = nil, repository: VintedRepository) -> AgentJob? {
        guard let kind = kind ?? preferredKind, statuses[kind]?.isReady == true else { return nil }
        let job = AgentJob(kind: kind, task: task, run: AgentRun(kind: kind, task: task, repository: repository))
        jobs.insert(job, at: 0)
        Task { await job.start() }
        return job
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
    }

    private func persistConfigs(from old: [AgentKind: AgentConfig]) {
        for kind in AgentKind.allCases {
            let before = old[kind] ?? AgentConfig(kind: kind)
            let after = config(kind)
            if before.binaryPath != after.binaryPath { persist("\(kind.rawValue).binary", after.binaryPath) }
            if before.model != after.model { persist("\(kind.rawValue).model", after.model) }
            if before.environment != after.environment {
                let text = after.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                persist("\(kind.rawValue).env", text)
            }
        }
    }

    private func persist(_ key: String, _ value: String) {
        guard let repository else { return }
        let previous = pendingSave
        pendingSave = Task {
            await previous?.value
            do {
                _ = try await VintedCLI(repository: repository).run(["agent", "config", "set", key, value])
            } catch {
                statuses = [:]
            }
        }
    }

    /// Bring settings from older app versions into the CLI's per-user config once.
    private func migrateLegacySettings(repository: VintedRepository) async {
        struct LegacyConfig: Decodable {
            let kind: AgentKind
            let binaryPath: String
            let model: String
            let environment: [String: String]
        }
        let defaults = UserDefaults.standard
        guard let stored = defaults.data(forKey: "agentConfigs"),
              let configs = try? JSONDecoder().decode([LegacyConfig].self, from: stored) else { return }
        let cli = VintedCLI(repository: repository)
        guard let path = try? await cli.run(["agent", "config", "path"]),
              !FileManager.default.fileExists(atPath: path) else { return }
        if let kind = defaults.string(forKey: "defaultAgent") {
            _ = try? await cli.run(["agent", "config", "set", "default", kind])
        }
        for config in configs {
            let prefix = config.kind.rawValue
            if !config.binaryPath.isEmpty {
                _ = try? await cli.run(["agent", "config", "set", "\(prefix).binary", config.binaryPath])
            }
            if !config.model.isEmpty {
                _ = try? await cli.run(["agent", "config", "set", "\(prefix).model", config.model])
            }
            if !config.environment.isEmpty {
                let value = config.environment.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                _ = try? await cli.run(["agent", "config", "set", "\(prefix).env", value])
            }
        }
    }
}

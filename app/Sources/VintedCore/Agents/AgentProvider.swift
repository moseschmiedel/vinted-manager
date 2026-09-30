import Foundation

/// Provider identifiers used by the UI. Detection and configuration live in `vinted agent`.
public enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

public struct AgentConfig: Sendable, Equatable {
    public let kind: AgentKind
    public var binaryPath = ""
    public var model = ""
    public var environment: [String: String] = [:]
    public init(kind: AgentKind) { self.kind = kind }
}

public struct AgentStatus: Sendable, Equatable {
    public var executable: URL?
    public var version: String?
    public var loggedIn: Bool?
    public var detail: String
    public var isReady: Bool { executable != nil && loggedIn == true }
}

public struct AgentSnapshot: Sendable {
    public let defaultKind: AgentKind
    public let configs: [AgentKind: AgentConfig]
    public let statuses: [AgentKind: AgentStatus]

    public static func load(repository: VintedRepository) async throws -> AgentSnapshot {
        let output = try await VintedCLI(repository: repository).run(["agent", "status", "--json"])
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CLIError(command: "vinted agent status --json", output: "Invalid JSON") }
        let defaultKind = AgentKind(rawValue: root["default"] as? String ?? "") ?? .claude
        var configs: [AgentKind: AgentConfig] = [:]
        var statuses: [AgentKind: AgentStatus] = [:]
        for entry in root["agents"] as? [[String: Any]] ?? [] {
            guard let kind = AgentKind(rawValue: entry["id"] as? String ?? "") else { continue }
            var config = AgentConfig(kind: kind)
            config.binaryPath = entry["binary"] as? String ?? ""
            config.model = entry["model"] as? String ?? ""
            config.environment = entry["env"] as? [String: String] ?? [:]
            configs[kind] = config
            let path = entry["executable"] as? String
            statuses[kind] = AgentStatus(executable: path.map { URL(fileURLWithPath: $0) },
                                         version: entry["version"] as? String,
                                         loggedIn: entry["logged_in"] as? Bool,
                                         detail: entry["detail"] as? String ?? "Unknown")
        }
        return AgentSnapshot(defaultKind: defaultKind, configs: configs, statuses: statuses)
    }
}

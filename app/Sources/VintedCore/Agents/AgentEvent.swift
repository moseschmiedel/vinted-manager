import Foundation

/// Shared event format emitted by `vinted agent run --json`.
public enum AgentEvent: Sendable, Equatable {
    case started(sessionID: String, model: String?)
    case message(String)
    case tool(name: String, detail: String)
    case finished(summary: String?, isError: Bool, costUSD: Double?)
    case notice(String)

    public static func parse(line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "started":
            return .started(sessionID: object["session_id"] as? String ?? "", model: object["model"] as? String)
        case "message": return .message(object["text"] as? String ?? "")
        case "tool": return .tool(name: object["name"] as? String ?? "tool", detail: object["detail"] as? String ?? "")
        case "finished":
            return .finished(summary: object["summary"] as? String,
                             isError: object["is_error"] as? Bool ?? true,
                             costUSD: object["cost_usd"] as? Double)
        case "notice": return .notice(object["text"] as? String ?? "")
        default: return nil
        }
    }
}

import Foundation

struct ToolCallDelta {
    let index: Int
    let id: String?
    let name: String?
    let arguments: String
}

enum LLMStreamEvent {
    case token(String)
    case thinking(String)
    case toolCallDelta(ToolCallDelta)
    case finishReason(String?)
}

enum AgentEvent {
    case thinking(String)
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case token(String)
    case done
    case error(String)
}

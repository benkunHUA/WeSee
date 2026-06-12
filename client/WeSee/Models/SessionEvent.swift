import Foundation

enum SessionEvent {
    case token(String)
    case thinking(String)
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case done
    case error(String)
}

extension SessionEvent: Equatable {
    static func == (lhs: SessionEvent, rhs: SessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.token(let a), .token(let b)): return a == b
        case (.thinking(let a), .thinking(let b)): return a == b
        case (.done, .done): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

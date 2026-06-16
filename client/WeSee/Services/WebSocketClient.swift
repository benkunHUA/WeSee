// client/WeSee/Services/WebSocketClient.swift
import Foundation

actor WebSocketClient {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var onEvent: ((ServerEvent) -> Void)?
    private var isConnected = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL) {
        task = session.webSocketTask(with: url)
        task?.resume()
        isConnected = true
        receiveNext()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    func send(_ message: ClientMessage) async {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await task?.send(.string(text))
    }

    func listen(onEvent: @escaping (ServerEvent) -> Void) {
        self.onEvent = onEvent
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { await self?.handle(result) }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                    onEvent?(event)
                }
            case .data(let data):
                if let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                    onEvent?(event)
                }
            @unknown default:
                break
            }
            receiveNext()

        case .failure:
            isConnected = false
            onEvent?(ServerEvent(type: .error, data: "Connection lost"))
        }
    }
}

// MARK: - Codable event models

struct ClientMessage: Codable {
    let type: ClientMessageType
    var content: String? = nil
    var id: String? = nil
    var name: String? = nil
    var result: String? = nil
    var path: String? = nil

    enum ClientMessageType: String, Codable {
        case chat
        case newConversation = "new_conversation"
        case toolResult = "tool_result"
        case updateWorkspace = "update_workspace"
    }
}

struct ServerEvent: Codable {
    let type: ServerEventType
    var data: String? = nil
    var id: String? = nil
    var name: String? = nil
    var arguments: [String: AnyCodable]? = nil

    enum ServerEventType: String, Codable {
        case token
        case thinking
        case toolCall = "tool_call"
        case done
        case error
    }
}

// Helper for encoding/decoding arbitrary JSON dictionaries
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String {
            try container.encode(str)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let arr = value as? [Any] {
            try container.encode(arr.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}

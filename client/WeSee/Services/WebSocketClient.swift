// client/WeSee/Services/WebSocketClient.swift
import Foundation
import Network

/// WebSocket client using Network.framework to avoid URLSession's nsurlsessiond XPC path.
final class WebSocketClient {
    private var connection: NWConnection?
    private var onEvent: ((ServerEvent) -> Void)?
    private let queue = DispatchQueue(label: "com.wesee.websocket")
    private var state: NWConnection.State = .setup

    func connect(url: URL) {
        disconnect()

        guard url.host != nil, url.port != nil else {
            WeSeeLog.error("[WS] Invalid server URL: \(url.absoluteString)")
            onEvent?(ServerEvent(type: .error, data: "Invalid server URL"))
            return
        }

        WeSeeLog.info("[WS] Connecting to \(url.absoluteString)...")

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters: NWParameters = url.scheme == "wss"
            ? NWParameters.tls
            : NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        connection = NWConnection(to: NWEndpoint.url(url), using: parameters)

        connection?.stateUpdateHandler = { [weak self] newState in
            self?.state = newState
            switch newState {
            case .setup:
                WeSeeLog.debug("[WS] State: setup")
            case .preparing:
                WeSeeLog.debug("[WS] State: preparing")
            case .ready:
                WeSeeLog.info("[WS] Connected, state: ready")
                self?.receiveNextMessage()
            case .failed(let error):
                WeSeeLog.error("[WS] Connection failed: \(error.localizedDescription)")
                self?.onEvent?(ServerEvent(type: .error, data: "Connection failed: \(error.localizedDescription)"))
            case .cancelled:
                WeSeeLog.info("[WS] Connection cancelled")
            case .waiting(let error):
                WeSeeLog.error("[WS] Waiting (error): \(error.localizedDescription)")
            @unknown default:
                WeSeeLog.debug("[WS] State: unknown")
            }
        }

        connection?.start(queue: queue)
    }

    func disconnect() {
        WeSeeLog.info("[WS] Disconnecting")
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        state = .setup
    }

    func send(_ message: ClientMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            WeSeeLog.error("[WS] Failed to encode message: \(message.type.rawValue)")
            return
        }

        WeSeeLog.info("[WS] Sending: type=\(message.type.rawValue)\(message.content.map { ", content=\($0.prefix(50))" } ?? "")")

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "send",
            metadata: [metadata]
        )

        connection?.send(
            content: text.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    WeSeeLog.error("[WS] Send failed: \(error.localizedDescription)")
                } else {
                    WeSeeLog.debug("[WS] Send completed: type=\(message.type.rawValue)")
                }
            }
        )
    }

    func listen(onEvent: @escaping (ServerEvent) -> Void) {
        self.onEvent = onEvent
        WeSeeLog.debug("[WS] Listener registered")
    }

    // MARK: - Receive loop

    private func receiveNextMessage() {
        guard let connection = connection else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "receive",
            metadata: [metadata]
        )

        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                WeSeeLog.error("[WS] Receive error: \(error.localizedDescription)")
                self.onEvent?(ServerEvent(type: .error, data: "Receive error: \(error.localizedDescription)"))
                return
            }

            if let data, let text = String(data: data, encoding: .utf8) {
                WeSeeLog.debug("[WS] Received raw: \(text.prefix(300))")
                if let jsonData = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ServerEvent.self, from: jsonData) {
                    WeSeeLog.info("[WS] Decoded event: type=\(event.type.rawValue)\(event.data.map { ", data=\($0.prefix(50))" } ?? "")")
                    DispatchQueue.main.async {
                        self.onEvent?(event)
                    }
                } else {
                    WeSeeLog.error("[WS] Failed to decode event from: \(text.prefix(200))")
                }
            }

            self.receiveNextMessage()
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
    var arguments: [String: JSONValue]? = nil

    enum ServerEventType: String, Codable {
        case token
        case thinking
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case done
        case error
    }
}

// MARK: - JSON value type (no Objective-C bridging)

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map { $0.anyValue }
        case .object(let d): return d.mapValues { $0.anyValue }
        case .null: return Optional<Any>.none as Any
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let dblAsInt = try? container.decode(Int.self) {
            self = .number(Double(dblAsInt))
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let d): try container.encode(d)
        case .null: try container.encodeNil()
        }
    }
}

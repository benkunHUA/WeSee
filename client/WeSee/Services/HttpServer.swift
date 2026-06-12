import Foundation
import Network

final class HttpServer {
    private let port: UInt16
    private let chatSession: ChatSessionProtocol
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.wesee.httpserver")

    init(port: UInt16, chatSession: ChatSessionProtocol) {
        self.port = port
        self.chatSession = chatSession
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready: WeSeeLog.info("HttpServer listening on port \(self.port)")
            case .failed(let error): WeSeeLog.error("HttpServer failed: \(error)")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            if let requestText = String(data: data, encoding: .utf8) {
                self.processRequest(requestText, on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP routing

    private func processRequest(_ raw: String, on connection: NWConnection) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              let method = requestLine.components(separatedBy: " ").first,
              let path = requestLine.components(separatedBy: " ").dropFirst().first
        else {
            send(status: 400, body: "Bad Request", contentType: "text/plain", on: connection)
            return
        }

        var body: String?
        if method == "POST" {
            if let bodyStart = raw.range(of: "\r\n\r\n") {
                body = String(raw[bodyStart.upperBound...])
            }
        }

        switch (method, path) {
        case ("GET", "/"):
            serveStaticFile(named: "index.html", contentType: "text/html; charset=utf-8", on: connection)

        case ("GET", "/app.js"):
            serveStaticFile(named: "app.js", contentType: "application/javascript; charset=utf-8", on: connection)

        case ("GET", "/api/messages"):
            serveMessages(on: connection)

        case ("POST", "/api/chat"):
            serveChatStream(body: body, on: connection)

        case ("POST", "/api/new-conversation"):
            chatSession.newConversation()
            send(status: 200, body: #"{"ok":true}"#, contentType: "application/json", on: connection)

        default:
            send(status: 404, body: "Not Found", contentType: "text/plain", on: connection)
        }
    }

    // MARK: - Static files

    private func serveStaticFile(named filename: String, contentType: String, on connection: NWConnection) {
        guard let resourceURL = Bundle.main.url(forResource: filename, withExtension: nil),
              let data = try? Data(contentsOf: resourceURL) else {
            send(status: 404, body: "Not Found", contentType: "text/plain", on: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: contentType, on: connection)
    }

    // MARK: - API handlers

    private func serveMessages(on connection: NWConnection) {
        let messagesArray = chatSession.messages.map { msg -> [String: Any] in
            [
                "id": msg.id.uuidString,
                "content": msg.content,
                "thinkingContent": msg.thinkingContent as Any,
                "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                "isFromMe": msg.isFromMe,
            ]
        }
        let json: [String: Any] = ["messages": messagesArray]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            send(status: 500, body: "Internal Error", contentType: "text/plain", on: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: "application/json", on: connection)
    }

    private func serveChatStream(body: String?, on connection: NWConnection) {
        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let content = json["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            send(status: 400, body: #"{"error":"Invalid request"}"#, contentType: "application/json", on: connection)
            return
        }

        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        sendRaw(headers, on: connection)

        Task {
            let stream = chatSession.eventStream

            // Start consuming events BEFORE calling send() to avoid unbuffered stream deadlock
            async let sendDone: Void = chatSession.send(content)

            for await event in stream {
                switch event {
                case .token(let text):
                    sendRaw(formatSSE(type: "token", data: ["data": text]), on: connection)
                case .thinking(let text):
                    sendRaw(formatSSE(type: "thinking", data: ["data": text]), on: connection)
                case .toolCallStart(let id, let name, let arguments):
                    sendRaw(formatSSE(type: "toolCall", data: [
                        "id": id, "name": name, "arguments": arguments
                    ]), on: connection)
                case .toolCallResult(let id, let name, let result):
                    sendRaw(formatSSE(type: "toolResult", data: [
                        "id": id, "name": name, "result": result
                    ]), on: connection)
                case .done:
                    sendRaw(formatSSE(type: "done", data: [:]), on: connection)
                    sendRaw("data: [DONE]\n\n", on: connection)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
                    return
                case .error(let msg):
                    sendRaw(formatSSE(type: "error", data: ["data": msg]), on: connection)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
                    return
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
        }
    }

    // MARK: - SSE formatting

    private func formatSSE(type: String, data: [String: Any]) -> String {
        var payload = data
        payload["type"] = type
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return "data: {\"type\":\"\(type)\"}\n\n"
        }
        return "data: \(jsonStr)\n\n"
    }

    // MARK: - Response helpers

    private func send(status: Int, body: String, contentType: String, on connection: NWConnection) {
        let data = body.data(using: .utf8)!
        send(status: status, bodyData: data, contentType: contentType, on: connection)
    }

    private func send(status: Int, bodyData: Data, contentType: String, on connection: NWConnection) {
        let statusText = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var response = header.data(using: .utf8)!
        response.append(bodyData)
        sendRawData(response, on: connection)
    }

    private func sendRaw(_ text: String, on connection: NWConnection) {
        sendRawData(text.data(using: .utf8)!, on: connection)
    }

    private func sendRawData(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .idempotent)
    }
}

import Foundation

protocol RemoteClient {
    func sendMessage(_ content: String) async throws
    func fetchMessages() async throws -> [Message]
    func syncStatus() async throws
}

final class NoOpRemoteClient: RemoteClient {
    func sendMessage(_ content: String) async throws {}
    func fetchMessages() async throws -> [Message] { [] }
    func syncStatus() async throws {}
}

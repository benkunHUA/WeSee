// client/WeSee/WeSeeApp.swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let httpServer: HttpServer
    let wsClient: WebSocketClient

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        let config = (try? ConfigLoader.load()) ?? ClientConfig.default
        wsClient = WebSocketClient()
        chatSession = ChatSessionImpl(
            wsClient: wsClient,
            workspaceManager: wm
        )
        httpServer = HttpServer(port: config.httpPort, chatSession: chatSession)
        do {
            try httpServer.start()
        } catch {
            WeSeeLog.error("HttpServer failed to start: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                chatSession: chatSession,
                wsClient: wsClient
            )
        }
        .modelContainer(container)
    }
}

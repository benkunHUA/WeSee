// client/WeSee/WeSeeApp.swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let wsClient: WebSocketClient

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        wsClient = WebSocketClient()
        chatSession = ChatSessionImpl(
            wsClient: wsClient,
            workspaceManager: wm
        )
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

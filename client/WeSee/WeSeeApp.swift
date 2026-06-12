import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let httpServer: HttpServer

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        chatSession = ChatSessionImpl(
            agentRunner: AgentRunner(workspaceManager: wm),
            workspaceManager: wm,
            systemPromptBuilder: SystemPromptBuilder(workspaceManager: wm)
        )
        let config = (try? ConfigLoader.load()) ?? ClientConfig.default
        httpServer = HttpServer(port: config.httpPort, chatSession: chatSession)
        do {
            try httpServer.start()
            WeSeeLog.info("HttpServer started on port \(config.httpPort)")
        } catch {
            WeSeeLog.error("HttpServer failed to start: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatSession: chatSession)
        }
        .modelContainer(container)
    }
}

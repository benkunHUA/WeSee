import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init() {
        let wm = WorkspaceManager()
        let agentRunner = AgentRunner(workspaceManager: wm)
        let systemPromptBuilder = SystemPromptBuilder(workspaceManager: wm)
        let session = ChatSessionImpl(
            agentRunner: agentRunner,
            workspaceManager: wm,
            systemPromptBuilder: systemPromptBuilder
        )
        _chatViewModel = State(initialValue: ChatViewModel(session: session))
        _sidebarViewModel = State(initialValue: SidebarViewModel(workspaceManager: wm))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: sidebarViewModel, chatViewModel: chatViewModel)
                .frame(minWidth: 220)
        } detail: {
            ChatView(viewModel: chatViewModel)
                .frame(minWidth: 400)
        }
        .onAppear {
            chatViewModel.configure(with: modelContext)
            sidebarViewModel.configure(with: modelContext)
        }
    }
}

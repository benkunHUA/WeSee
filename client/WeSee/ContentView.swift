// client/WeSee/ContentView.swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init(chatSession: ChatSessionImpl, wsClient: WebSocketClient) {
        let wm = chatSession.workspaceManager
        let vm = ChatViewModel(
            wsClient: wsClient,
            workspaceManager: wm
        )
        _chatViewModel = State(initialValue: vm)
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
            chatViewModel.fetchMessages()
            let config = (try? ConfigLoader.load()) ?? ClientConfig.default
            let serverURL = URL(string: "ws://localhost:\(config.httpPort)/ws")!
            chatViewModel.connect(serverURL: serverURL)
        }
    }
}

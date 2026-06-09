import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init() {
        let client = LiveRemoteClient()
        _chatViewModel = State(initialValue: ChatViewModel(remoteClient: client))
        _sidebarViewModel = State(initialValue: SidebarViewModel(remoteClient: client))
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

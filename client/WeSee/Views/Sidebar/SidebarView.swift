import SwiftUI

struct SidebarView: View {
    let viewModel: SidebarViewModel
    let chatViewModel: ChatViewModel
    @State private var showScheduledTasks = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    FunctionMenuView(
                        onNewConversation: {
                            chatViewModel.newConversation()
                        },
                        onScheduledTasks: {
                            showScheduledTasks = true
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)

            Divider()

            WorkspaceSectionView(workspaceManager: viewModel.workspaceManager)
        }
        .sheet(isPresented: $showScheduledTasks) {
            ScheduledTaskSheet(viewModel: viewModel)
        }
        .navigationTitle("WeSee")
    }
}

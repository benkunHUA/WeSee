import SwiftUI

struct SidebarView: View {
    let viewModel: SidebarViewModel
    let chatViewModel: ChatViewModel
    @State private var showScheduledTasks = false

    var body: some View {
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

            Section {
                TagFilterListView(
                    tags: viewModel.tags,
                    selectedTag: chatViewModel.selectedTag,
                    onSelectTag: { tag in
                        chatViewModel.filterByTag(tag)
                    },
                    onCreateTag: { name in
                        viewModel.createTag(name: name)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("标签")
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showScheduledTasks) {
            ScheduledTaskSheet(viewModel: viewModel)
        }
        .navigationTitle("WeSee")
    }
}

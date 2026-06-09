//
//  ContentView.swift
//  WeSee
//
//  Created by haobenkun on 2026/6/9.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel = ChatViewModel()
    @State private var sidebarViewModel = SidebarViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: sidebarViewModel,
                chatViewModel: chatViewModel
            )
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

#Preview {
    ContentView()
}

import SwiftUI

struct MessageListView: View {
    let messages: [Message]
    let onBookmark: (Message) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "开始对话",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("发送第一条消息吧")
                        )
                        .padding(.top, 60)
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message) {
                            onBookmark(message)
                        }
                        .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

import SwiftUI

struct MessageListView: View {
    let messages: [Message]
    let streamingContent: String?
    let onBookmark: (Message) -> Void
    let onTagClick: (Tag) -> Void

    init(messages: [Message], streamingContent: String? = nil, onBookmark: @escaping (Message) -> Void, onTagClick: @escaping (Tag) -> Void = { _ in }) {
        self.messages = messages
        self.streamingContent = streamingContent
        self.onBookmark = onBookmark
        self.onTagClick = onTagClick
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if messages.isEmpty && streamingContent == nil {
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
                        } onTagClick: { tag in
                            onTagClick(tag)
                        }
                        .id(message.id)
                    }

                    if let streaming = streamingContent, !streaming.isEmpty {
                        StreamingBubble(content: streaming)
                            .id("streaming")
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
            .onChange(of: streamingContent ?? "") { _, _ in
                withAnimation {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }
}

struct StreamingBubble: View {
    let content: String

    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 6) {
                Text(content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if content.isEmpty || content.last != " " {
                            Circle()
                                .fill(Color(nsColor: .secondaryLabelColor))
                                .frame(width: 6, height: 6)
                                .padding(.trailing, 6)
                                .padding(.bottom, 4)
                        }
                    }
                Spacer(minLength: 60)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

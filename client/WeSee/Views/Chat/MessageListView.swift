import SwiftUI
import MarkdownUI

struct MessageListView: View {
    let messages: [Message]
    let streamingContent: String?
    let thinkingContent: String?

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
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if let streaming = streamingContent, !streaming.isEmpty {
                        StreamingBubble(
                            content: streaming,
                            thinkingContent: thinkingContent
                        )
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
    let thinkingContent: String?

    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    if let thinking = thinkingContent, !thinking.isEmpty {
                        ThinkingSection(content: thinking, initiallyExpanded: true)
                        Divider()
                            .padding(.vertical, 6)
                    }

                    MarkdownContent(content: content)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(alignment: .bottomTrailing) {
                    if content.isEmpty || thinkingContent != nil || content.last != " " {
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

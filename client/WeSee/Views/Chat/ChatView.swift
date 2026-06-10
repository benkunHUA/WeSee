import SwiftUI

struct ChatView: View {
    let viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(
                messages: viewModel.messages,
                streamingContent: viewModel.isStreaming ? viewModel.streamingContent : nil,
                thinkingContent: viewModel.isStreaming ? viewModel.thinkingContent : nil
            )

            Divider()

            MessageInputBar(
                isDisabled: viewModel.isSendingDisabled,
                onSend: { content in
                    viewModel.sendMessage(content)
                }
            )
        }
        .navigationTitle("聊天")
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.red.opacity(0.9)))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.clearError()
                        }
                    }
            }
        }
    }
}

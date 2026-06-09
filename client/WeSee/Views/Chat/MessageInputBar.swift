import SwiftUI

struct MessageInputBar: View {
    @State private var inputText: String = ""
    let isDisabled: Bool
    let onSend: (String) -> Void

    var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("输入消息...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .lineLimit(1...5)
                .onSubmit {
                    sendIfValid()
                }

            Button(action: { sendIfValid() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(trimmedInput.isEmpty || isDisabled)
            .opacity(trimmedInput.isEmpty || isDisabled ? 0.4 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func sendIfValid() {
        guard !trimmedInput.isEmpty, !isDisabled else { return }
        onSend(trimmedInput)
        inputText = ""
    }
}

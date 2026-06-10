import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isFromMe { Spacer(minLength: 60) }

            if message.isFromMe {
                userBubble
            } else {
                aiBubble
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var aiBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                if let thinking = message.thinkingContent, !thinking.isEmpty {
                    ThinkingSection(content: thinking)
                    Divider()
                        .padding(.vertical, 6)
                }

                MarkdownContent(content: message.content)

                if !message.attachmentPaths.isEmpty {
                    ForEach(message.attachmentPaths, id: \.self) { path in
                        AttachmentImageView(path: path)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ThinkingSection: View {
    let content: String
    var initiallyExpanded: Bool = false

    @State private var isExpanded: Bool

    init(content: String, initiallyExpanded: Bool = false) {
        self.content = content
        self.initiallyExpanded = initiallyExpanded
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.smooth(duration: 0.2), value: isExpanded)

                    Image(systemName: "brain.head.profile")
                        .font(.caption)

                    Text("思考过程")
                        .font(.caption)

                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 3)
                    }
            }
        }
    }
}

struct AttachmentImageView: View {
    let path: String

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 400, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(.top, 6)
                .onTapGesture(count: 2) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
        }
    }
}

struct MarkdownContent: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownCodeSyntaxHighlighter(.plainText)
            .markdownBlockStyle(\.codeBlock) { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }
            .markdownTextStyle(\.text) {
                FontSize(.em(0.95))
            }
            .textSelection(.enabled)
    }
}

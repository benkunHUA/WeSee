import SwiftUI

struct MessageBubble: View {
    let message: Message
    let onBookmark: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 4) {
                    if message.isFromMe {
                        Button(action: onBookmark) {
                            Image(systemName: message.isBookmarked ? "bookmark.fill" : "bookmark")
                                .font(.caption2)
                                .foregroundStyle(message.isBookmarked ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            message.isFromMe
                                ? Color.accentColor
                                : Color(nsColor: .controlBackgroundColor)
                        )
                        .foregroundStyle(message.isFromMe ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if !message.isFromMe {
                        Button(action: onBookmark) {
                            Image(systemName: message.isBookmarked ? "bookmark.fill" : "bookmark")
                                .font(.caption2)
                                .foregroundStyle(message.isBookmarked ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

import SwiftUI

struct TagChipView: View {
    let tag: Tag
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color(hex: tag.colorHex) ?? .blue)
                    .frame(width: 6, height: 6)
                Text(tag.name)
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(hex: tag.colorHex)?.opacity(0.15) ?? Color.blue.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }
}

struct MessageBubble: View {
    let message: Message
    let onBookmark: () -> Void
    let onTagClick: (Tag) -> Void

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

                if !message.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.tags) { tag in
                            TagChipView(tag: tag) {
                                onTagClick(tag)
                            }
                        }
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

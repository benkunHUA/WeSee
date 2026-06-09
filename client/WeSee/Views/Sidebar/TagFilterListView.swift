import SwiftUI

struct TagFilterListView: View {
    let tags: [Tag]
    let selectedTag: Tag?
    let onSelectTag: (Tag?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("标签筛选")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            Button(action: { onSelectTag(nil) }) {
                HStack {
                    Text("全部")
                        .foregroundStyle(selectedTag == nil ? Color.accentColor : .primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selectedTag == nil
                        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                        : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                )
            }
            .buttonStyle(.plain)

            ForEach(tags) { tag in
                Button(action: { onSelectTag(tag) }) {
                    HStack {
                        Circle()
                            .fill(Color(hex: tag.colorHex) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(tag.name)
                            .foregroundStyle(selectedTag?.id == tag.id ? Color.accentColor : .primary)
                        Spacer()
                        Text("\(tag.messages.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selectedTag?.id == tag.id
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                            : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            if tags.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无标签，发送消息时可添加")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 16)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

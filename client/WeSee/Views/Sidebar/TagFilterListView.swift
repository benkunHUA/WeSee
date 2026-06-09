import SwiftUI

struct TagFilterListView: View {
    let tags: [Tag]
    let selectedTag: Tag?
    let onSelectTag: (Tag?) -> Void
    let onCreateTag: (String) -> Void

    @State private var newTagName: String = ""
    @State private var showAddField: Bool = false

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

            if showAddField {
                HStack(spacing: 4) {
                    TextField("标签名称", text: $newTagName)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .onSubmit {
                            addTag()
                        }

                    Button(action: { addTag() }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: {
                        showAddField = false
                        newTagName = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Button(action: { showAddField = true }) {
                Label("新建标签", systemImage: "plus")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if tags.isEmpty && !showAddField {
                HStack {
                    Spacer()
                    Text("暂无标签，点击下方创建")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onCreateTag(name)
        newTagName = ""
        showAddField = false
    }
}

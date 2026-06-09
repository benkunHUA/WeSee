import SwiftUI

struct FunctionMenuView: View {
    let onNewConversation: () -> Void
    let onScheduledTasks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("功能菜单")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            Button(action: onNewConversation) {
                Label("新建会话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))

            Button(action: onScheduledTasks) {
                Label("定时任务", systemImage: "clock")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 8)
    }
}

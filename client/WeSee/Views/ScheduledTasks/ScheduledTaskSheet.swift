import SwiftUI

struct ScheduledTaskSheet: View {
    let viewModel: SidebarViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("定时任务")
                    .font(.headline)
                Spacer()
                Button(action: {
                    viewModel.createTask(
                        type: .reminder,
                        title: "新任务 \(viewModel.scheduledTasks.count + 1)",
                        cronExpression: "0 9 * * *"
                    )
                }) {
                    Image(systemName: "plus")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                Button("完成") { dismiss() }
            }
            .padding()

            Divider()

            if viewModel.scheduledTasks.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "暂无定时任务",
                    systemImage: "clock.badge.questionmark",
                    description: Text("点击 + 创建定时任务")
                )
                Spacer()
            } else {
                List {
                    ForEach(viewModel.scheduledTasks) { task in
                        HStack {
                            Image(systemName: iconFor(task.type))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.body)
                                Text(task.cronExpression)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { task.isEnabled },
                                set: { _ in viewModel.toggleTask(task) }
                            ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 400)
    }

    private func iconFor(_ type: TaskType) -> String {
        switch type {
        case .sendMessage: "message.fill"
        case .syncStatus: "arrow.triangle.2.circlepath"
        case .reminder: "bell.fill"
        }
    }
}

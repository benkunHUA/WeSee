import Foundation
import Observation
import SwiftData

@Observable
final class SidebarViewModel {
    var scheduledTasks: [ScheduledTask] = []

    let workspaceManager: WorkspaceManager
    private var modelContext: ModelContext?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchScheduledTasks()
    }

    func fetchScheduledTasks() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.title)])
        scheduledTasks = (try? context.fetch(descriptor)) ?? []
    }

    func toggleTask(_ task: ScheduledTask) {
        task.isEnabled.toggle()
        try? modelContext?.save()
        fetchScheduledTasks()
    }

    func createTask(type: TaskType, title: String, cronExpression: String) {
        guard let context = modelContext else { return }
        let task = ScheduledTask(type: type, title: title, cronExpression: cronExpression)
        context.insert(task)
        try? context.save()
        fetchScheduledTasks()
    }
}

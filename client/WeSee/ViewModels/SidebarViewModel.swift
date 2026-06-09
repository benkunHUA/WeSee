import Foundation
import Observation
import SwiftData

@Observable
final class SidebarViewModel {
    var tags: [Tag] = []
    var scheduledTasks: [ScheduledTask] = []
    var conversations: [ConversationDTO] = []

    private var modelContext: ModelContext?
    private let remoteClient: RemoteClient

    init(remoteClient: RemoteClient = NoOpRemoteClient()) {
        self.remoteClient = remoteClient
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchTags()
        fetchScheduledTasks()
        Task { await loadRemoteData() }
    }

    func loadRemoteData() async {
        do {
            conversations = try await remoteClient.fetchConversations()
        } catch {
            // Silently fail; conversations are non-critical
        }
    }

    func fetchTags() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        tags = (try? context.fetch(descriptor)) ?? []
    }

    func fetchScheduledTasks() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.title)])
        scheduledTasks = (try? context.fetch(descriptor)) ?? []
    }

    func createTag(name: String, colorHex: String = "#007AFF") {
        guard let context = modelContext else { return }
        let tag = Tag(name: name, colorHex: colorHex)
        context.insert(tag)
        try? context.save()
        fetchTags()
        Task {
            _ = try? await remoteClient.createTag(name: name, colorHex: colorHex)
        }
    }

    func toggleTask(_ task: ScheduledTask) {
        task.isEnabled.toggle()
        try? modelContext?.save()
        fetchScheduledTasks()
        Task {
            _ = try? await remoteClient.toggleTask(task.id.uuidString)
        }
    }

    func createTask(type: TaskType, title: String, cronExpression: String) {
        guard let context = modelContext else { return }
        let task = ScheduledTask(type: type, title: title, cronExpression: cronExpression)
        context.insert(task)
        try? context.save()
        fetchScheduledTasks()
        Task {
            _ = try? await remoteClient.createTask(
                type: type.rawValue,
                title: title,
                cronExpression: cronExpression
            )
        }
    }
}

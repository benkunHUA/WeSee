import Foundation
import SwiftData

enum TaskType: String, Codable {
    case sendMessage
    case syncStatus
    case reminder
}

@Model
final class ScheduledTask {
    var id: UUID
    var typeRaw: String
    var title: String
    var cronExpression: String
    var isEnabled: Bool
    var nextFireDate: Date?

    var type: TaskType {
        TaskType(rawValue: typeRaw) ?? .reminder
    }

    init(type: TaskType, title: String, cronExpression: String) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.title = title
        self.cronExpression = cronExpression
        self.isEnabled = true
        self.nextFireDate = nil
    }
}

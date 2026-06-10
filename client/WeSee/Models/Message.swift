import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID
    var content: String
    var thinkingContent: String?
    var attachmentPaths: [String] = []
    var timestamp: Date
    var isFromMe: Bool

    init(content: String, thinkingContent: String? = nil, attachmentPaths: [String] = [], isFromMe: Bool) {
        self.id = UUID()
        self.content = content
        self.thinkingContent = thinkingContent
        self.attachmentPaths = attachmentPaths
        self.timestamp = Date()
        self.isFromMe = isFromMe
    }

    var trimmedContent: String {
        String(content.prefix(5000))
    }

    var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

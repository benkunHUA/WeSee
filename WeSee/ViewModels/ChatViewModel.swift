import Foundation
import SwiftData
import Observation
import SwiftUI

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var selectedTag: Tag?
    var isSendingDisabled: Bool = false
    var errorMessage: String?

    private var modelContext: ModelContext?

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchMessages()
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        if let tag = selectedTag {
            let tagId = tag.id
            descriptor.predicate = #Predicate<Message> { message in
                message.tags.contains(where: { $0.id == tagId })
            }
        }
        do {
            messages = try context.fetch(descriptor)
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool, tags: [Tag] = []) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }
        guard let context = modelContext else { return }
        let message = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
        context.insert(message)
        try? context.save()
        fetchMessages()
        isSendingDisabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isSendingDisabled = false
        }
    }

    func toggleBookmark(_ message: Message) {
        guard let context = modelContext else { return }
        message.isBookmarked.toggle()
        try? context.save()
        fetchMessages()
    }

    func filterByTag(_ tag: Tag?) {
        selectedTag = tag
        fetchMessages()
    }

    func clearError() {
        errorMessage = nil
    }
}

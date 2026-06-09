//
//  Message.swift
//  WeSee
//
//  Created by haobenkun on 2026/6/9.
//

import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID
    var content: String
    var timestamp: Date
    var isFromMe: Bool
    var isBookmarked: Bool
    @Relationship(inverse: \Tag.messages)
    var tags: [Tag]

    init(content: String, isFromMe: Bool, tags: [Tag] = []) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.isFromMe = isFromMe
        self.isBookmarked = false
        self.tags = tags
    }

    var trimmedContent: String {
        String(content.prefix(5000))
    }

    var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

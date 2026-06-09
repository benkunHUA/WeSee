//
//  Tag.swift
//  WeSee
//
//  Created by haobenkun on 2026/6/9.
//

import Foundation
import SwiftData

@Model
final class Tag {
    var id: UUID
    var name: String
    var colorHex: String
    var messages: [Message]

    init(name: String, colorHex: String = "#007AFF") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.messages = []
    }
}

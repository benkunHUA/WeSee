//
//  ChatViewModelTests.swift
//  WeSeeTests
//
//  Created by haobenkun on 2026/6/9.
//

import Testing
@testable import WeSee

struct ChatViewModelTests {

    @Test func addMessageAppendsToMessages() async throws {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "Hello", isFromMe: true)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "Hello")
        #expect(viewModel.messages.first?.isFromMe == true)
    }

    @Test func addEmptyMessageIsIgnored() async throws {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "", isFromMe: true)
        viewModel.addMessage(content: "   ", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }
}

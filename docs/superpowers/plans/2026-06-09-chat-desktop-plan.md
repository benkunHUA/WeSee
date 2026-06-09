# Chat Desktop Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS desktop chat tool with left sidebar (function menu + tag filter list) and right chat area (message list + input bar), using MVVM + SwiftData.

**Architecture:** NavigationSplitView layout with SwiftData-persisted Message/Tag/ScheduledTask models. ChatViewModel and SidebarViewModel as @Observable state managers. Protocol-based RemoteClient placeholder for future backend integration.

**Tech Stack:** SwiftUI, SwiftData, Swift Concurrency, XCTest

---

## File Structure Map

```
WeSee/
├── App/WeSeeApp.swift                  (modify - add ModelContainer)
├── Models/
│   ├── Message.swift                   (create)
│   ├── Tag.swift                       (create)
│   └── ScheduledTask.swift             (create)
├── Views/
│   ├── ContentView.swift               (modify - replace with split layout)
│   ├── Sidebar/
│   │   ├── SidebarView.swift           (create)
│   │   ├── FunctionMenuView.swift      (create)
│   │   └── TagFilterListView.swift     (create)
│   ├── Chat/
│   │   ├── ChatView.swift              (create)
│   │   ├── MessageBubble.swift         (create)
│   │   ├── MessageListView.swift       (create)
│   │   └── MessageInputBar.swift       (create)
│   └── ScheduledTasks/
│       └── ScheduledTaskSheet.swift    (create)
├── ViewModels/
│   ├── ChatViewModel.swift             (create)
│   └── SidebarViewModel.swift          (create)
└── Services/
    └── RemoteClient.swift              (create)
WeSeeTests/
└── ChatViewModelTests.swift            (create)
```

---

### Task 1: Create Message model

**Files:**
- Create: `WeSee/Models/Message.swift`
- Create: `WeSeeTests/ChatViewModelTests.swift` (first test)

- [ ] **Step 1: Write the failing test**

Create `WeSeeTests/ChatViewModelTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS' 2>&1 | tail -20`
Expected: Compilation errors — `ChatViewModel` not found, `Message` not found

- [ ] **Step 3: Create Message model**

Create `WeSee/Models/Message.swift`:

```swift
import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID
    var content: String
    var timestamp: Date
    var isFromMe: Bool
    var isBookmarked: Bool
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
```

- [ ] **Step 4: Commit**

```bash
git add WeSee/Models/Message.swift WeSeeTests/ChatViewModelTests.swift
git commit -m "feat: add Message model with SwiftData"
```

---

### Task 2: Create Tag model

**Files:**
- Create: `WeSee/Models/Tag.swift`

- [ ] **Step 1: Write Tag model**

Create `WeSee/Models/Tag.swift`:

```swift
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
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/Models/Tag.swift
git commit -m "feat: add Tag model with SwiftData"
```

---

### Task 3: Create ScheduledTask model

**Files:**
- Create: `WeSee/Models/ScheduledTask.swift`

- [ ] **Step 1: Write ScheduledTask model**

Create `WeSee/Models/ScheduledTask.swift`:

```swift
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
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/Models/ScheduledTask.swift
git commit -m "feat: add ScheduledTask model with SwiftData"
```

---

### Task 4: Create ChatViewModel

**Files:**
- Create: `WeSee/ViewModels/ChatViewModel.swift`

- [ ] **Step 1: Write ChatViewModel**

Create `WeSee/ViewModels/ChatViewModel.swift`:

```swift
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
            descriptor.predicate = #Predicate { message in
                message.tags.contains(where: { $0.id == tag.id })
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
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/ViewModels/ChatViewModel.swift
git commit -m "feat: add ChatViewModel with message CRUD and tag filtering"
```

---

### Task 5: Create SidebarViewModel

**Files:**
- Create: `WeSee/ViewModels/SidebarViewModel.swift`

- [ ] **Step 1: Write SidebarViewModel**

Create `WeSee/ViewModels/SidebarViewModel.swift`:

```swift
import Foundation
import SwiftData
import Observation

@Observable
final class SidebarViewModel {
    var tags: [Tag] = []
    var scheduledTasks: [ScheduledTask] = []

    private var modelContext: ModelContext?

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchTags()
        fetchScheduledTasks()
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
    }
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/ViewModels/SidebarViewModel.swift
git commit -m "feat: add SidebarViewModel with tag and task management"
```

---

### Task 6: Create FunctionMenuView and TagFilterListView

**Files:**
- Create: `WeSee/Views/Sidebar/FunctionMenuView.swift`
- Create: `WeSee/Views/Sidebar/TagFilterListView.swift`

- [ ] **Step 1: Write FunctionMenuView**

Create `WeSee/Views/Sidebar/FunctionMenuView.swift`:

```swift
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
```

- [ ] **Step 2: Write TagFilterListView**

Create `WeSee/Views/Sidebar/TagFilterListView.swift`:

```swift
import SwiftUI

struct TagFilterListView: View {
    let tags: [Tag]
    let selectedTag: Tag?
    let onSelectTag: (Tag?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("标签筛选")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            Button(action: { onSelectTag(nil) }) {
                HStack {
                    Text("全部")
                        .foregroundStyle(selectedTag == nil ? Color.accentColor : .primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selectedTag == nil
                        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                        : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                )
            }
            .buttonStyle(.plain)

            ForEach(tags) { tag in
                Button(action: { onSelectTag(tag) }) {
                    HStack {
                        Circle()
                            .fill(Color(hex: tag.colorHex) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(tag.name)
                            .foregroundStyle(selectedTag?.id == tag.id ? Color.accentColor : .primary)
                        Spacer()
                        Text("\(tag.messages.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selectedTag?.id == tag.id
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                            : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            if tags.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无标签，发送消息时可添加")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 16)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 4: Commit**

```bash
git add WeSee/Views/Sidebar/FunctionMenuView.swift WeSee/Views/Sidebar/TagFilterListView.swift
git commit -m "feat: add FunctionMenuView and TagFilterListView"
```

---

### Task 7: Create SidebarView

**Files:**
- Create: `WeSee/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Write SidebarView**

Create `WeSee/Views/Sidebar/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    let viewModel: SidebarViewModel
    let chatViewModel: ChatViewModel
    @State private var showScheduledTasks = false

    var body: some View {
        List {
            Section {
                FunctionMenuView(
                    onNewConversation: {
                        chatViewModel.filterByTag(nil)
                    },
                    onScheduledTasks: {
                        showScheduledTasks = true
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                TagFilterListView(
                    tags: viewModel.tags,
                    selectedTag: chatViewModel.selectedTag,
                    onSelectTag: { tag in
                        chatViewModel.filterByTag(tag)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("历史会话")
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showScheduledTasks) {
            ScheduledTaskSheet(viewModel: viewModel)
        }
        .navigationTitle("WeSee")
    }
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/Views/Sidebar/SidebarView.swift
git commit -m "feat: add SidebarView composing menu and tag filter"
```

---

### Task 8: Create Chat view components

**Files:**
- Create: `WeSee/Views/Chat/MessageBubble.swift`
- Create: `WeSee/Views/Chat/MessageListView.swift`
- Create: `WeSee/Views/Chat/MessageInputBar.swift`
- Create: `WeSee/Views/Chat/ChatView.swift`

- [ ] **Step 1: Write MessageBubble**

Create `WeSee/Views/Chat/MessageBubble.swift`:

```swift
import SwiftUI

struct MessageBubble: View {
    let message: Message
    let onBookmark: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !message.isFromMe { Spacer().frame(width: 32) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 4) {
                    if message.isFromMe {
                        Button(action: onBookmark) {
                            Image(systemName: message.isBookmarked ? "bookmark.fill" : "bookmark")
                                .font(.caption2)
                                .foregroundStyle(message.isBookmarked ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            message.isFromMe
                                ? Color.accentColor
                                : Color(nsColor: .controlBackgroundColor)
                        )
                        .foregroundStyle(message.isFromMe ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if !message.isFromMe {
                        Button(action: onBookmark) {
                            Image(systemName: message.isBookmarked ? "bookmark.fill" : "bookmark")
                                .font(.caption2)
                                .foregroundStyle(message.isBookmarked ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.isFromMe { Spacer().frame(width: 32) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Write MessageListView**

Create `WeSee/Views/Chat/MessageListView.swift`:

```swift
import SwiftUI

struct MessageListView: View {
    let messages: [Message]
    let onBookmark: (Message) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "开始对话",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("发送第一条消息吧")
                        )
                        .padding(.top, 60)
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message) {
                            onBookmark(message)
                        }
                        .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Write MessageInputBar**

Create `WeSee/Views/Chat/MessageInputBar.swift`:

```swift
import SwiftUI

struct MessageInputBar: View {
    @State private var inputText: String = ""
    let isDisabled: Bool
    let onSend: (String) -> Void

    var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("输入消息...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .lineLimit(1...5)
                .onSubmit {
                    sendIfValid()
                }

            Button(action: { sendIfValid() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(trimmedInput.isEmpty || isDisabled)
            .opacity(trimmedInput.isEmpty || isDisabled ? 0.4 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func sendIfValid() {
        guard !trimmedInput.isEmpty, !isDisabled else { return }
        onSend(trimmedInput)
        inputText = ""
    }
}
```

- [ ] **Step 4: Write ChatView**

Create `WeSee/Views/Chat/ChatView.swift`:

```swift
import SwiftUI

struct ChatView: View {
    let viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(
                messages: viewModel.messages,
                onBookmark: { viewModel.toggleBookmark($0) }
            )

            Divider()

            MessageInputBar(
                isDisabled: viewModel.isSendingDisabled,
                onSend: { content in
                    viewModel.addMessage(content: content, isFromMe: true)
                }
            )
        }
        .navigationTitle(viewModel.selectedTag?.name ?? "聊天")
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.red.opacity(0.9)))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.clearError()
                        }
                    }
            }
        }
    }
}
```

- [ ] **Step 5: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 6: Commit**

```bash
git add WeSee/Views/Chat/MessageBubble.swift WeSee/Views/Chat/MessageListView.swift WeSee/Views/Chat/MessageInputBar.swift WeSee/Views/Chat/ChatView.swift
git commit -m "feat: add Chat view components - bubble, list, input, chat"
```

---

### Task 9: Create ScheduledTaskSheet

**Files:**
- Create: `WeSee/Views/ScheduledTasks/ScheduledTaskSheet.swift`

- [ ] **Step 1: Write ScheduledTaskSheet**

Create `WeSee/Views/ScheduledTasks/ScheduledTaskSheet.swift`:

```swift
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
                            Toggle("", isOn: .constant(task.isEnabled))
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
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 3: Commit**

```bash
git add WeSee/Views/ScheduledTasks/ScheduledTaskSheet.swift
git commit -m "feat: add ScheduledTaskSheet view"
```

---

### Task 10: Rewire ContentView and WeSeeApp

**Files:**
- Modify: `WeSee/Views/ContentView.swift`
- Modify: `WeSee/App/WeSeeApp.swift`
- Create: `WeSee/Services/RemoteClient.swift`

- [ ] **Step 1: Write RemoteClient protocol placeholder**

Create `WeSee/Services/RemoteClient.swift`:

```swift
import Foundation

protocol RemoteClient {
    func sendMessage(_ content: String) async throws
    func fetchMessages() async throws -> [Message]
    func syncStatus() async throws
}

final class NoOpRemoteClient: RemoteClient {
    func sendMessage(_ content: String) async throws {}
    func fetchMessages() async throws -> [Message] { [] }
    func syncStatus() async throws {}
}
```

- [ ] **Step 2: Rewrite ContentView**

Rewrite `WeSee/Views/ContentView.swift`:

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel = ChatViewModel()
    @State private var sidebarViewModel = SidebarViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: sidebarViewModel,
                chatViewModel: chatViewModel
            )
            .frame(minWidth: 220)
        } detail: {
            ChatView(viewModel: chatViewModel)
                .frame(minWidth: 400)
        }
        .onAppear {
            chatViewModel.configure(with: modelContext)
            sidebarViewModel.configure(with: modelContext)
        }
    }
}
```

- [ ] **Step 3: Update WeSeeApp with ModelContainer**

Rewrite `WeSee/App/WeSeeApp.swift`:

```swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Message.self, Tag.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS' 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS' 2>&1 | tail -10`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add WeSee/Views/ContentView.swift WeSee/App/WeSeeApp.swift WeSee/Services/RemoteClient.swift
git commit -m "feat: wire up NavigationSplitView layout with ModelContainer"
```

---

### Task 11: Add comprehensive tests

**Files:**
- Modify: `WeSeeTests/ChatViewModelTests.swift` (expand)

- [ ] **Step 1: Expand tests**

Rewrite `WeSeeTests/ChatViewModelTests.swift`:

```swift
import Testing
@testable import WeSee

struct ChatViewModelTests {

    @Test func addMessageAppendsToMessages() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "Hello", isFromMe: true)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func addEmptyMessageIsIgnored() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "", isFromMe: true)
        viewModel.addMessage(content: "   ", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func addWhitespaceOnlyMessageIsIgnored() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "\n\n", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func isSendingDisabledBlocksRapidSend() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "msg1", isFromMe: true)
        #expect(viewModel.isSendingDisabled == true)
    }

    @Test func filterByTagUpdatesSelectedTag() {
        let viewModel = ChatViewModel()
        viewModel.filterByTag(nil)
        #expect(viewModel.selectedTag == nil)
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let viewModel = ChatViewModel()
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS' 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add WeSeeTests/ChatViewModelTests.swift
git commit -m "test: add comprehensive ChatViewModel tests"
```

---

### Task 12: Final verification

- [ ] **Step 1: Build and run full test suite**

```bash
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS' 2>&1 | grep -E '(BUILD|Test|passed|failed)'
```

Expected: BUILD SUCCEEDED, all tests passed

- [ ] **Step 2: Verify coverage**

```bash
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS' -enableCodeCoverage YES 2>&1 | tail -5
```

- [ ] **Step 3: Commit if needed**

```bash
git status
```

//
//  WeSeeApp.swift
//  WeSee
//
//  Created by haobenkun on 2026/6/9.
//

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

import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
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

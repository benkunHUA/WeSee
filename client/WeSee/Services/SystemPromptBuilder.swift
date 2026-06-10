import Foundation

struct SystemPromptBuilder {
    let workspaceManager: WorkspaceManager

    func build() -> String {
        var parts: [String] = []

        parts.append("You are a helpful assistant running inside a macOS application.")
        parts.append("Your working directory is: \(workspaceManager.currentURL.path)")
        parts.append("All relative paths are resolved against this directory.")
        parts.append("Respond in Chinese unless the user asks otherwise.")

        return parts.joined(separator: "\n")
    }
}

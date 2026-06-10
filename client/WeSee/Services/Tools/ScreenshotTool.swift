import Foundation

final class ScreenshotTool: AgentTool {
    let name = "screenshot"
    let description = "Take a screenshot on macOS. Supports fullscreen, window selection, or interactive area selection. Screenshots are saved as PNG files."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "type": JSONSchema.PropertyDef(
                type: "string",
                description: "Screenshot type: 'fullscreen' (default), 'window' (capture a window after click), or 'selection' (drag to select area)"
            ),
        ],
        required: []
    )

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let type = arguments["type"] as? String ?? "fullscreen"

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "screenshot_\(timestamp).png"
        let outputURL = workspaceManager.screenshotsURL.appendingPathComponent(filename)

        try? FileManager.default.createDirectory(
            at: workspaceManager.screenshotsURL,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        var args: [String] = []
        switch type {
        case "window":
            args = ["-w", "-W", outputURL.path]
        case "selection":
            args = ["-i", outputURL.path]
        default:
            args = [outputURL.path]
        }
        process.arguments = args

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outputURL.path)
                } else {
                    continuation.resume(
                        returning: "Error: screenshot failed with exit code \(proc.terminationStatus)"
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: "Error: failed to start screencapture: \(error.localizedDescription)"
                )
            }
        }
    }
}

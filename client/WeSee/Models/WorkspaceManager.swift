import Foundation

@Observable
final class WorkspaceManager {
    var currentURL: URL
    var screenshotsURL: URL

    private let configURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, configURL: URL? = nil) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.configURL = configURL ?? home.appendingPathComponent(".config/wesee/config.json")
        let defaultURL = home.appendingPathComponent("Documents/WeSee")
        self.currentURL = defaultURL
        self.screenshotsURL = defaultURL.appendingPathComponent("screenshots")
        load()
        ensureDirectoryExists()
    }

    func update(path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        currentURL = url
        ensureDirectoryExists()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let workspacePath = json["workspace"] as? String, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath)
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            currentURL = url
        }

        if let screenshotsPath = json["screenshotsPath"] as? String, !screenshotsPath.isEmpty {
            screenshotsURL = resolveScreenshotsPath(screenshotsPath)
        } else {
            screenshotsURL = currentURL.appendingPathComponent("screenshots")
        }
    }

    private func resolveScreenshotsPath(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return currentURL.appendingPathComponent(path)
    }

    func save() {
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        json["workspace"] = currentURL.path
        json["screenshotsPath"] = screenshotsURL.path

        let dir = configURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            WeSeeLog.error("WorkspaceManager: Failed to serialize config JSON")
            return
        }
        do {
            try data.write(to: configURL)
        } catch {
            WeSeeLog.error("WorkspaceManager: Failed to save config: \(error.localizedDescription)")
        }
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: currentURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
    }
}

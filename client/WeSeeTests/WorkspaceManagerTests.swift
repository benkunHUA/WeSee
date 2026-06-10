import Testing
import Foundation
@testable import WeSee

struct WorkspaceManagerTests {
    private func tempConfigURL() -> URL {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir.appendingPathComponent("config.json")
    }

    @Test func defaultWorkspaceIsDocumentsWeSee() {
        let configURL = tempConfigURL()
        let wm = WorkspaceManager(configURL: configURL)
        let path = wm.currentURL.path
        #expect(path.hasSuffix("Documents/WeSee"))
    }

    @Test func updateChangesCurrentURL() {
        let wm = WorkspaceManager(configURL: tempConfigURL())
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_update").path
        wm.update(path: tmpDir)
        #expect(wm.currentURL.path == tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
    }

    @Test func updateCreatesDirectoryIfNeeded() {
        let wm = WorkspaceManager(configURL: tempConfigURL())
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_nonexistent_sub/subdir").path
        wm.update(path: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
        // Cleanup
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    @Test func saveWritesToConfigFile() {
        let configURL = tempConfigURL()
        // Save requires the config file to already exist
        let initial: [String: Any] = ["apiKey": "test-key"]
        let initialData = try! JSONSerialization.data(withJSONObject: initial)
        try! initialData.write(to: configURL)

        let wm = WorkspaceManager(configURL: configURL)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_save").path
        wm.update(path: tmpDir)

        #expect(FileManager.default.fileExists(atPath: configURL.path))

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #expect(Bool(false), "config.json should be valid JSON")
            return
        }
        #expect(json["workspace"] as? String == tmpDir)
        #expect(json["apiKey"] as? String == "test-key")
    }

    @Test func loadReadsExistingWorkspaceFromConfig() {
        let configURL = tempConfigURL()
        // Save requires the config file to already exist
        let initial: [String: Any] = ["apiKey": "test-key"]
        let initialData = try! JSONSerialization.data(withJSONObject: initial)
        try! initialData.write(to: configURL)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_load").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        // First WM loads apiKey-only config, then saves workspace
        let first = WorkspaceManager(configURL: configURL)
        first.update(path: tmpDir)

        // Second WM should load the saved path
        let second = WorkspaceManager(configURL: configURL)
        #expect(second.currentURL.path == tmpDir)
    }
}

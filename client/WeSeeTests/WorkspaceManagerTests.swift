import Testing
import Foundation
@testable import WeSee

struct WorkspaceManagerTests {
    @Test func defaultWorkspaceIsDocumentsWeSee() {
        // Remove config to ensure load() uses the default path, not a stale value
        // from another test run
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/wesee/config.json")
        try? FileManager.default.removeItem(at: configURL)

        let wm = WorkspaceManager()
        let path = wm.currentURL.path
        #expect(path.hasSuffix("Documents/WeSee"))
    }

    @Test func updateChangesCurrentURL() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_update").path
        wm.update(path: tmpDir)
        #expect(wm.currentURL.path == tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
    }

    @Test func updateCreatesDirectoryIfNeeded() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_nonexistent_sub/subdir").path
        wm.update(path: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
        // Cleanup
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    @Test func saveWritesToConfigFile() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_save").path
        wm.update(path: tmpDir)

        // Verify config was written
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/wesee/config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #expect(Bool(false), "config.json should be valid JSON")
            return
        }
        #expect(json["workspace"] as? String == tmpDir)
    }

    @Test func loadReadsExistingWorkspaceFromConfig() {
        // Create a fresh WM with a known path, save it
        let first = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_load").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        first.update(path: tmpDir)

        // Create a second WM — it should load the saved path
        let second = WorkspaceManager()
        #expect(second.currentURL.path == tmpDir)
    }
}

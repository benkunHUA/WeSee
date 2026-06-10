import Testing
import Foundation
@testable import WeSee

struct FileSystemToolTests {
    @Test func readFileReturnsContent() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        try "hello world".write(toFile: tmpDir + "/test_read.txt", atomically: true, encoding: .utf8)
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "test_read.txt"])
        #expect(result == "hello world")
    }

    @Test func readFileNotFoundReturnsError() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: FileManager.default.temporaryDirectory.path)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "nonexistent.txt"])
        #expect(result.hasPrefix("Error: file not found"))
    }

    @Test func writeFileCreatesFile() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "write_file", "path": "test_write.txt", "content": "test content",
        ])
        #expect(result.hasPrefix("Successfully wrote"))
        let written = try String(contentsOfFile: tmpDir + "/test_write.txt", encoding: .utf8)
        #expect(written == "test content")
    }

    @Test func listDirectoryReturnsContents() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": ".",
        ])
        #expect(!result.isEmpty)
    }

    @Test func listDirectoryNotFoundReturnsError() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": "nonexistent",
        ])
        #expect(result.hasPrefix("Error:"))
    }

    @Test func unknownActionReturnsError() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["action": "delete_file", "path": "test.txt"])
        #expect(result.hasPrefix("Error: unknown action"))
    }

    @Test func pathTraversalIsRejected() async throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-config-\(UUID().uuidString).json")
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager(configURL: configURL)
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "read_file", "path": "../etc/passwd",
        ])
        #expect(result.hasPrefix("Error: path"))
    }
}

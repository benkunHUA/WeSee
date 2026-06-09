import Testing
import Foundation
@testable import WeSee

struct FileSystemToolTests {
    @Test func readFileReturnsContent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_read.txt").path
        try "hello world".write(toFile: filePath, atomically: true, encoding: .utf8)
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "read_file", "path": filePath])
        #expect(result == "hello world")
    }

    @Test func readFileNotFoundReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "/nonexistent/file.txt"])
        #expect(result.hasPrefix("Error: file not found"))
    }

    @Test func writeFileCreatesFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_write.txt").path
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "write_file", "path": filePath, "content": "test content",
        ])
        #expect(result.hasPrefix("Successfully wrote"))
        let written = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(written == "test content")
    }

    @Test func listDirectoryReturnsContents() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": FileManager.default.temporaryDirectory.path,
        ])
        #expect(!result.isEmpty)
    }

    @Test func listDirectoryNotFoundReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": "/nonexistent/dir",
        ])
        #expect(result.hasPrefix("Error:"))
    }

    @Test func unknownActionReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "delete_file", "path": "/tmp/test.txt"])
        #expect(result.hasPrefix("Error: unknown action"))
    }
}

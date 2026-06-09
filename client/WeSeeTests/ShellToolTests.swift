import Testing
@testable import WeSee

struct ShellToolTests {
    @Test func executeEchoReturnsOutput() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "echo hello"])
        #expect(result.contains("hello"))
    }

    @Test func executeWithWorkingDirectory() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: [
            "command": "pwd", "working_directory": "/tmp",
        ])
        #expect(result.contains("/tmp"))
    }

    @Test func executeInvalidCommandReturnsError() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "nonexistent_command_xyz"])
        #expect(result.hasPrefix("Exit code"))
    }

    @Test func missingCommandParameterReturnsError() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Error: missing required parameter"))
    }
}

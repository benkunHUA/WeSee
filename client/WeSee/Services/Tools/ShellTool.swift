import Foundation

final class ShellTool: AgentTool {
    let name = "shell"
    let description = "Execute a safe shell command. Only supported commands are allowed. No pipes, redirects, or command substitution. Commands have a 30-second timeout."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "command": JSONSchema.PropertyDef(
                type: "string",
                description: "The shell command to execute"
            ),
            "working_directory": JSONSchema.PropertyDef(
                type: "string",
                description: "Optional working directory for the command"
            ),
        ],
        required: ["command"]
    )

    private let timeoutSeconds: Int
    private let allowedCommands: Set<String>
    private let workspaceManager: WorkspaceManager

    private static let defaultAllowedCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "find", "echo",
        "pwd", "date", "whoami", "uname", "df", "du", "ps", "top",
        "git", "swift", "xcodebuild", "python3", "node", "npm",
        "sed", "awk", "sort", "uniq", "diff", "xargs", "mkdir",
        "touch", "cp", "mv", "rm", "chmod", "ln", "file", "which",
        "open", "osascript", "plutil", "defaults", "system_profiler",
    ]

    init(
        timeoutSeconds: Int = 30,
        allowedCommands: Set<String>? = nil,
        workspaceManager: WorkspaceManager
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.allowedCommands = allowedCommands ?? Self.defaultAllowedCommands
        self.workspaceManager = workspaceManager
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing required parameter 'command'"
        }
        if let error = validateCommand(command) {
            return error
        }
        let workingDir = arguments["working_directory"] as? String
            ?? workspaceManager.currentURL.path
        return try await runCommand(command, workingDirectory: workingDir)
    }

    private func validateCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "Error: empty command"
        }
        let dangerousPatterns = [
            ("|", "|", "pipes"),
            (";", ";", "command separators"),
            ("&", "&", "background/chain operators"),
            ("`", "`", "backtick command substitution"),
            ("$(", "$(", "command substitution"),
            (">", ">", "output redirection"),
            ("<", "<", "input redirection"),
        ]
        for (pattern, _, name) in dangerousPatterns {
            if trimmed.contains(pattern) {
                return "Error: command contains disallowed \(name) ('\(pattern)')"
            }
        }
        let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let commandName = (firstWord as NSString).lastPathComponent
        guard allowedCommands.contains(commandName) else {
            return "Error: command '\(commandName)' is not in the allowed list"
        }
        return nil
    }

    private func runCommand(_ command: String, workingDirectory: String?) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: workspaceManager.currentURL.path)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutData = NSMutableData()
            let stderrData = NSMutableData()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutData.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrData.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let out = String(data: stdoutData as Data, encoding: .utf8) ?? ""
                let err = String(data: stderrData as Data, encoding: .utf8) ?? ""
                var result = ""
                if !out.isEmpty { result += out }
                if !err.isEmpty { result += (result.isEmpty ? "" : "\n") + err }
                if result.isEmpty { result = "(no output)" }
                if proc.terminationStatus != 0 {
                    result = "Exit code \(proc.terminationStatus)\n" + result
                }
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: "Error: failed to start command: \(error.localizedDescription)"
                )
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(self.timeoutSeconds)) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

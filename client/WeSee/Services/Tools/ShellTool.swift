import Foundation

final class ShellTool: AgentTool {
    let name = "shell"
    let description = "Execute a shell command. Returns stdout and stderr combined. Commands have a 30-second timeout."

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

    init(timeoutSeconds: Int = 30) {
        self.timeoutSeconds = timeoutSeconds
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing required parameter 'command'"
        }
        let workingDir = arguments["working_directory"] as? String
        return try await runCommand(command, workingDirectory: workingDir)
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
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
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

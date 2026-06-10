import Foundation

final class FileSystemTool: AgentTool {
    let name = "file_system"
    let description = "Read, write, and list files within the workspace directory. Use read_file to read content, write_file to create or overwrite files, and list_directory to list directory contents. All paths are relative to the workspace root."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": JSONSchema.PropertyDef(
                type: "string",
                description: "One of: read_file, write_file, list_directory"
            ),
            "path": JSONSchema.PropertyDef(
                type: "string",
                description: "Path relative to the workspace directory"
            ),
            "content": JSONSchema.PropertyDef(
                type: "string",
                description: "File content to write (required for write_file)"
            ),
        ],
        required: ["action", "path"]
    )

    private let fileManager: FileManager
    private let maxFileSize: Int
    private let workspaceManager: WorkspaceManager

    init(
        fileManager: FileManager = .default,
        maxFileSize: Int = 1_000_000,
        workspaceManager: WorkspaceManager
    ) {
        self.fileManager = fileManager
        self.maxFileSize = maxFileSize
        self.workspaceManager = workspaceManager
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let action = arguments["action"] as? String,
              let path = arguments["path"] as? String else {
            return "Error: missing required parameters 'action' or 'path'"
        }
        guard let safePath = resolveSafePath(path) else {
            return "Error: path '\(path)' escapes the workspace directory"
        }
        switch action {
        case "read_file": return try await readFile(at: safePath)
        case "write_file":
            let content = arguments["content"] as? String ?? ""
            return try await writeFile(content: content, at: safePath)
        case "list_directory": return try await listDirectory(at: safePath)
        default: return "Error: unknown action '\(action)'. Supported: read_file, write_file, list_directory"
        }
    }

    private func resolveSafePath(_ relativePath: String) -> String? {
        let root = workspaceManager.currentURL.path
        let resolved = ((root as NSString)
            .appendingPathComponent(relativePath) as NSString)
            .standardizingPath
        let rootStandardized = (root as NSString).standardizingPath
        guard resolved.hasPrefix(rootStandardized) else { return nil }
        return resolved
    }

    private func readFile(at path: String) async throws -> String {
        guard fileManager.fileExists(atPath: path) else {
            return "Error: file not found at \(path)"
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int,
              fileSize <= maxFileSize else {
            return "Error: file too large or unable to read attributes"
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    private func writeFile(content: String, at path: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: dir) {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return "Successfully wrote \(content.count) bytes to \(path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    private func listDirectory(at path: String) async throws -> String {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return "Error: directory not found at \(path)"
        }
        do {
            let items = try fileManager.contentsOfDirectory(atPath: path)
            return items.sorted().joined(separator: "\n")
        } catch {
            return "Error listing directory: \(error.localizedDescription)"
        }
    }
}

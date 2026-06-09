import Foundation

final class FileSystemTool: AgentTool {
    let name = "file_system"
    let description = "Read, write, and list files on the local filesystem. Use read_file to read content, write_file to create or overwrite files, and list_directory to list directory contents."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": JSONSchema.PropertyDef(
                type: "string",
                description: "One of: read_file, write_file, list_directory"
            ),
            "path": JSONSchema.PropertyDef(
                type: "string",
                description: "Absolute path to the file or directory"
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

    init(fileManager: FileManager = .default, maxFileSize: Int = 1_000_000) {
        self.fileManager = fileManager
        self.maxFileSize = maxFileSize
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let action = arguments["action"] as? String,
              let path = arguments["path"] as? String else {
            return "Error: missing required parameters 'action' or 'path'"
        }
        switch action {
        case "read_file": return try await readFile(at: path)
        case "write_file":
            let content = arguments["content"] as? String ?? ""
            return try await writeFile(content: content, at: path)
        case "list_directory": return try await listDirectory(at: path)
        default: return "Error: unknown action '\(action)'. Supported: read_file, write_file, list_directory"
        }
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

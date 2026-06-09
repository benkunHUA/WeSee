import Foundation

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    func execute(arguments: [String: Any]) async throws -> String
}

struct JSONSchema: Codable {
    let type: String
    let properties: [String: PropertyDef]
    let required: [String]

    struct PropertyDef: Codable {
        let type: String
        let description: String

        init(type: String, description: String) {
            self.type = type
            self.description = description
        }
    }

    init(type: String, properties: [String: PropertyDef], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    func toDictionary() -> [String: Any] {
        let propsDict = properties.mapValues { prop -> [String: Any] in
            ["type": prop.type, "description": prop.description]
        }
        return [
            "type": type,
            "properties": propsDict,
            "required": required,
        ]
    }
}

final class ToolRegistry {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func get(name: String) -> AgentTool? {
        tools[name]
    }

    var allTools: [AgentTool] {
        Array(tools.values)
    }

    func encodeToAPIParams() -> [[String: Any]] {
        allTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.toDictionary(),
                ],
            ]
        }
    }
}

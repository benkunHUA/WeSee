import Testing
@testable import WeSee

struct FakeTool: AgentTool {
    let name = "fake_tool"
    let description = "A fake tool for testing"
    let parameters = JSONSchema(
        type: "object",
        properties: ["input": JSONSchema.PropertyDef(type: "string", description: "An input")],
        required: ["input"]
    )
    func execute(arguments: [String: Any]) async throws -> String { "fake_result" }
}

struct AgentToolTests {
    @Test func registerAndRetrieveTool() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        #expect(registry.get(name: "fake_tool") != nil)
        #expect(registry.get(name: "nonexistent") == nil)
    }

    @Test func allToolsReturnsRegisteredTools() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        #expect(registry.allTools.count == 1)
        #expect(registry.allTools.first?.name == "fake_tool")
    }

    @Test func encodeToAPIParamsReturnsCorrectFormat() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        let params = registry.encodeToAPIParams()
        #expect(params.count == 1)
        let first = params[0]
        #expect(first["type"] as? String == "function")
        let function = first["function"] as? [String: Any]
        #expect(function?["name"] as? String == "fake_tool")
        #expect(function?["description"] as? String == "A fake tool for testing")
        let parameters = function?["parameters"] as? [String: Any]
        #expect(parameters?["type"] as? String == "object")
        #expect(parameters?["required"] as? [String] == ["input"])
    }

    @Test func jsonSchemaToDictionary() {
        let schema = JSONSchema(
            type: "object",
            properties: [
                "path": JSONSchema.PropertyDef(type: "string", description: "File path"),
                "content": JSONSchema.PropertyDef(type: "string", description: "File content"),
            ],
            required: ["path"]
        )
        let dict = schema.toDictionary()
        #expect(dict["type"] as? String == "object")
        let props = dict["properties"] as? [String: [String: Any]]
        #expect(props?["path"]?["type"] as? String == "string")
        #expect(props?["path"]?["description"] as? String == "File path")
        #expect(dict["required"] as? [String] == ["path"])
    }
}

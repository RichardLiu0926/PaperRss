import Foundation

/// Parses a tool directive emitted by models that do not support native
/// function calling. The directive is deliberately strict: one JSON object with
/// a known tool name and an object/string `arguments` payload.
public enum AgentTextToolCallParser {
    public static func parse(
        _ content: String,
        allowedToolNames: Set<String>
    ) -> AgentToolCall? {
        guard let json = extractJSONObject(from: content),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (object["tool"] as? String ?? object["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              allowedToolNames.contains(name) else {
            return nil
        }
        let argumentsString: String
        if let dictionary = object["arguments"] as? [String: Any] {
            guard let encoded = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
                  let string = String(data: encoded, encoding: .utf8) else { return nil }
            argumentsString = string
        } else if let string = object["arguments"] as? String, !string.isEmpty {
            argumentsString = string
        } else {
            argumentsString = "{}"
        }
        return AgentToolCall(
            id: "text_\(UUID().uuidString)",
            name: name,
            arguments: argumentsString
        )
    }

    /// Appended to the system prompt in text-JSON mode. Kept terse so small
    /// local models do not lose the actual user request.
    public static func instructions(for tools: [AgentToolDefinition]) -> String {
        let toolLines = tools.map { tool -> String in
            let parameters = tool.parameters.map { parameter in
                "\(parameter.name):\(parameter.kind.rawValue)"
            }.joined(separator: ", ")
            return "- \(tool.name)(\(parameters)): \(tool.description)"
        }.joined(separator: "\n")
        return """
        You can call tools. To call one, output ONLY a fenced JSON block:
        ```json
        {"tool":"<name>","arguments":{...}}
        ```
        Available tools:
        \(toolLines)
        Never invent tool names or article ids. After a call you will receive a user message starting with "TOOL_RESULT"; use it to answer normally. Do not emit a tool block when you have enough information.
        """
    }

    private static func extractJSONObject(from content: String) -> String? {
        if let start = content.range(of: "```json", options: .caseInsensitive),
           let end = content.range(of: "```", options: .backwards, range: start.upperBound..<content.endIndex) {
            let body = String(content[start.upperBound..<end.lowerBound])
            if let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}"), first <= last {
                return String(body[first...last])
            }
        }
        if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end {
            return String(content[start...end])
        }
        return nil
    }
}

import Foundation

/// Roles understood by the OpenAI-compatible chat endpoint used by the
/// assistant. Kept deliberately small: the agent only needs system/user/
/// assistant/tool turns.
public enum AgentChatRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// A function call requested by the model. `arguments` is the raw JSON string
/// returned by the provider; parsing and validation happen in the tool layer so
/// a malformed payload can be reported back to the model instead of crashing.
public struct AgentToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One turn sent to `LLMService.chat`. Assistant turns may carry tool calls;
/// tool turns must carry the matching `toolCallID`.
public struct AgentChatMessage: Codable, Hashable, Sendable {
    public let role: AgentChatRole
    public let content: String
    public let toolCalls: [AgentToolCall]
    public let toolCallID: String?

    public init(
        role: AgentChatRole,
        content: String = "",
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ content: String) -> AgentChatMessage {
        AgentChatMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> AgentChatMessage {
        AgentChatMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String, toolCalls: [AgentToolCall] = []) -> AgentChatMessage {
        AgentChatMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }

    public static func tool(callID: String, content: String) -> AgentChatMessage {
        AgentChatMessage(role: .tool, content: content, toolCallID: callID)
    }
}

/// A flat parameter description. The assistant tools all use object schemas
/// with scalar or string-array parameters, so this stays readable instead of
/// introducing a general JSON-schema type.
public struct AgentToolParameter: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case string
        case integer
        case number
        case boolean
        case stringArray = "array"
    }

    public let name: String
    public let kind: Kind
    public let description: String
    public let isRequired: Bool
    public let enumValues: [String]?
    public let itemType: String?

    public init(
        name: String,
        kind: Kind,
        description: String,
        isRequired: Bool = false,
        enumValues: [String]? = nil,
        itemType: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.isRequired = isRequired
        self.enumValues = enumValues
        self.itemType = itemType
    }
}

public struct AgentToolDefinition: Hashable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [AgentToolParameter]

    public init(name: String, description: String, parameters: [AgentToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// JSON-schema object handed to the provider. Built with Foundation types
    /// because the request body is serialized with `JSONSerialization`.
    public var schemaObject: [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for parameter in parameters {
            var property: [String: Any] = [
                "type": parameter.kind.rawValue,
                "description": parameter.description
            ]
            if let enumValues = parameter.enumValues, !enumValues.isEmpty {
                property["enum"] = enumValues
            }
            if parameter.kind == .stringArray {
                property["items"] = ["type": parameter.itemType ?? "string"]
            }
            properties[parameter.name] = property
            if parameter.isRequired { required.append(parameter.name) }
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
}

public struct AgentChatCompletion: Equatable, Sendable {
    public let content: String
    public let toolCalls: [AgentToolCall]
    public let finishReason: String?

    public init(content: String, toolCalls: [AgentToolCall] = [], finishReason: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }

    public var hasToolCalls: Bool { !toolCalls.isEmpty }
}

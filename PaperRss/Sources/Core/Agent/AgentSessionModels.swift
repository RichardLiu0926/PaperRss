import Foundation

/// A locally stored assistant conversation. Messages reference article ids
/// instead of copying full article bodies, keeping the chat database small.
public struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var scopeJSON: String
    public var providerID: String?
    public var modelID: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var isArchived: Bool

    public init(
        id: String,
        title: String,
        scopeJSON: String = "{}",
        providerID: String? = nil,
        modelID: String? = nil,
        createdAt: Double,
        updatedAt: Double,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.scopeJSON = scopeJSON
        self.providerID = providerID
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}

public struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let role: AgentChatRole
    public let content: String
    public let toolCalls: [AgentToolCall]
    public let toolCallID: String?
    public let createdAt: Double

    public init(
        id: String,
        sessionID: String,
        role: AgentChatRole,
        content: String,
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.createdAt = createdAt
    }

    public var chatMessage: AgentChatMessage {
        AgentChatMessage(role: role, content: content, toolCalls: toolCalls, toolCallID: toolCallID)
    }
}

public enum AgentActionStatus: String, Codable, Hashable, Sendable {
    case executed
    case failed
    case undone
}

/// Append-only local audit record for every write proposal the assistant
/// executes. `priorStatesJSON` lets the UI undo the exact entries later without
/// guessing what the previous read/starred flags were.
public struct AgentAction: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionID: String?
    public let messageID: String?
    public let tool: String
    public let argumentsJSON: String
    public let affectedIDs: [String]
    public let priorStatesJSON: String
    public var status: AgentActionStatus
    public let createdAt: Double
    public var undoneAt: Double?

    public init(
        id: String,
        sessionID: String?,
        messageID: String?,
        tool: String,
        argumentsJSON: String,
        affectedIDs: [String],
        priorStatesJSON: String,
        status: AgentActionStatus,
        createdAt: Double,
        undoneAt: Double? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.affectedIDs = affectedIDs
        self.priorStatesJSON = priorStatesJSON
        self.status = status
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }
}

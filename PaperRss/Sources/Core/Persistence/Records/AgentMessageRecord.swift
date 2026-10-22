import Foundation
import GRDB

public struct AgentMessageRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_messages"

    public var id: String
    public var sessionID: String
    public var role: String
    public var content: String
    public var toolCallsJSON: String?
    public var toolCallID: String?
    public var createdAt: Double
    public var charCount: Int

    public init(
        id: String,
        sessionID: String,
        role: String,
        content: String,
        toolCallsJSON: String? = nil,
        toolCallID: String? = nil,
        createdAt: Double,
        charCount: Int
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.toolCallsJSON = toolCallsJSON
        self.toolCallID = toolCallID
        self.createdAt = createdAt
        self.charCount = charCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case role
        case content
        case toolCallsJSON = "tool_calls_json"
        case toolCallID = "tool_call_id"
        case createdAt = "created_at"
        case charCount = "char_count"
    }

    public var domain: AgentMessage {
        let calls: [AgentToolCall]
        if let toolCallsJSON, let data = toolCallsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AgentToolCall].self, from: data) {
            calls = decoded
        } else {
            calls = []
        }
        return AgentMessage(
            id: id,
            sessionID: sessionID,
            role: AgentChatRole(rawValue: role) ?? .assistant,
            content: content,
            toolCalls: calls,
            toolCallID: toolCallID,
            createdAt: createdAt
        )
    }
}

import Foundation
import GRDB

public struct AgentActionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_action_log"

    public var id: String
    public var sessionID: String?
    public var messageID: String?
    public var tool: String
    public var argsJSON: String
    public var affectedIDsJSON: String
    public var priorStatesJSON: String
    public var status: String
    public var createdAt: Double
    public var undoneAt: Double?

    public init(
        id: String,
        sessionID: String? = nil,
        messageID: String? = nil,
        tool: String,
        argsJSON: String,
        affectedIDsJSON: String,
        priorStatesJSON: String,
        status: String,
        createdAt: Double,
        undoneAt: Double? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.tool = tool
        self.argsJSON = argsJSON
        self.affectedIDsJSON = affectedIDsJSON
        self.priorStatesJSON = priorStatesJSON
        self.status = status
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case messageID = "message_id"
        case tool
        case argsJSON = "args_json"
        case affectedIDsJSON = "affected_ids_json"
        case priorStatesJSON = "prior_states_json"
        case status
        case createdAt = "created_at"
        case undoneAt = "undone_at"
    }

    public var domain: AgentAction {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(affectedIDsJSON.utf8))) ?? []
        return AgentAction(
            id: id,
            sessionID: sessionID,
            messageID: messageID,
            tool: tool,
            argumentsJSON: argsJSON,
            affectedIDs: ids,
            priorStatesJSON: priorStatesJSON,
            status: AgentActionStatus(rawValue: status) ?? .failed,
            createdAt: createdAt,
            undoneAt: undoneAt
        )
    }
}

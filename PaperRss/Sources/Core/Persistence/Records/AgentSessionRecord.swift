import Foundation
import GRDB

public struct AgentSessionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_sessions"

    public var id: String
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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case scopeJSON = "scope_json"
        case providerID = "provider_id"
        case modelID = "model_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isArchived = "is_archived"
    }

    public var domain: AgentSession {
        AgentSession(
            id: id,
            title: title,
            scopeJSON: scopeJSON,
            providerID: providerID,
            modelID: modelID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived
        )
    }
}

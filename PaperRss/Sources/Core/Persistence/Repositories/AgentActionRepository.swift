import Foundation
import GRDB

/// Append-only audit log for assistant write proposals. Kept separate from the
/// messages table so clearing a conversation never erases the record needed to
/// undo a state change.
public final class AgentActionRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    @discardableResult
    public func record(
        sessionID: String?,
        messageID: String?,
        tool: String,
        argumentsJSON: String,
        affectedIDs: [String],
        priorStatesJSON: String,
        status: AgentActionStatus = .executed,
        now: Date = .now
    ) throws -> AgentAction {
        let idsJSON = String(data: try JSONEncoder().encode(affectedIDs), encoding: .utf8) ?? "[]"
        let record = AgentActionRecord(
            id: UUID().uuidString,
            sessionID: sessionID,
            messageID: messageID,
            tool: tool,
            argsJSON: argumentsJSON,
            affectedIDsJSON: idsJSON,
            priorStatesJSON: priorStatesJSON,
            status: status.rawValue,
            createdAt: now.timeIntervalSince1970
        )
        try database.write { db in try record.insert(db) }
        return record.domain
    }

    public func fetchRecent(limit: Int = 50) throws -> [AgentAction] {
        try database.read { db in
            try AgentActionRecord
                .order(Column("created_at").desc)
                .limit(max(1, limit))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    public func fetchAction(id: String) throws -> AgentAction? {
        try database.read { db in
            try AgentActionRecord.fetchOne(db, key: id)?.domain
        }
    }

    public func markUndone(id: String, now: Date = .now) throws {
        try database.write { db in
            guard var record = try AgentActionRecord.fetchOne(db, key: id) else {
                throw AgentActionRepositoryError.actionNotFound
            }
            record.status = AgentActionStatus.undone.rawValue
            record.undoneAt = now.timeIntervalSince1970
            try record.update(db)
        }
    }

    public enum AgentActionRepositoryError: LocalizedError, Equatable, Sendable {
        case actionNotFound

        public var errorDescription: String? {
            I18N.localized("操作记录不存在。", englishFallback: "The action record no longer exists.")
        }
    }

    public func clear(olderThan seconds: TimeInterval, now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-max(0, seconds)).timeIntervalSince1970
        try database.write { db in
            _ = try AgentActionRecord
                .filter(Column("created_at") < cutoff)
                .deleteAll(db)
        }
    }
}

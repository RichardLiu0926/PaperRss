import Foundation
import GRDB

/// Local-only storage for assistant sessions and messages. Article bodies are
/// never copied here; messages keep entry ids so the reader remains the source
/// of truth for content and state.
public final class AgentSessionRepository: Sendable {
    /// Messages are capped to keep a runaway tool result or pasted article from
    /// bloating the SQLite file. The UI shows a truncation marker when needed.
    public static let maximumMessageCharacters = 32_000

    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    public func createSession(
        title: String = "",
        scopeJSON: String = "{}",
        providerID: String? = nil,
        modelID: String? = nil,
        now: Date = .now
    ) throws -> AgentSession {
        let timestamp = now.timeIntervalSince1970
        let record = AgentSessionRecord(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            scopeJSON: scopeJSON,
            providerID: providerID,
            modelID: modelID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try database.write { db in try record.insert(db) }
        return record.domain
    }

    public func fetchSessions(includeArchived: Bool = false, limit: Int = 50) throws -> [AgentSession] {
        try database.read { db in
            var request = AgentSessionRecord.all()
            if !includeArchived {
                request = request.filter(Column("is_archived") == false)
            }
            return try request
                .order(Column("updated_at").desc)
                .limit(max(1, limit))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    public func fetchSession(id: String) throws -> AgentSession? {
        try database.read { db in
            try AgentSessionRecord.fetchOne(db, key: id)?.domain
        }
    }

    @discardableResult
    public func appendMessage(
        sessionID: String,
        role: AgentChatRole,
        content: String,
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil,
        now: Date = .now
    ) throws -> AgentMessage {
        let timestamp = now.timeIntervalSince1970
        let bounded = Self.boundedContent(content)
        let callsJSON: String?
        if toolCalls.isEmpty {
            callsJSON = nil
        } else {
            callsJSON = String(data: try JSONEncoder().encode(toolCalls), encoding: .utf8)
        }
        let record = AgentMessageRecord(
            id: UUID().uuidString,
            sessionID: sessionID,
            role: role.rawValue,
            content: bounded,
            toolCallsJSON: callsJSON,
            toolCallID: toolCallID,
            createdAt: timestamp,
            charCount: bounded.count
        )
        try database.write { db in
            guard var session = try AgentSessionRecord.fetchOne(db, key: sessionID) else {
                throw AgentSessionRepositoryError.sessionNotFound
            }
            try record.insert(db)
            session.updatedAt = timestamp
            if session.title.isEmpty, role == .user {
                session.title = Self.derivedTitle(from: content)
            }
            try session.update(db)
        }
        return record.domain
    }

    public func fetchMessages(sessionID: String) throws -> [AgentMessage] {
        try database.read { db in
            try AgentMessageRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("created_at").asc, Column("rowid").asc)
                .fetchAll(db)
                .map(\.domain)
        }
    }

    public func updateScope(id: String, scopeJSON: String, now: Date = .now) throws {
        try database.write { db in
            guard var record = try AgentSessionRecord.fetchOne(db, key: id) else {
                throw AgentSessionRepositoryError.sessionNotFound
            }
            record.scopeJSON = scopeJSON
            record.updatedAt = now.timeIntervalSince1970
            try record.update(db)
        }
    }

    public func renameSession(id: String, title: String, now: Date = .now) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { db in
            guard var record = try AgentSessionRecord.fetchOne(db, key: id) else {
                throw AgentSessionRepositoryError.sessionNotFound
            }
            record.title = clean
            record.updatedAt = now.timeIntervalSince1970
            try record.update(db)
        }
    }

    public func setArchived(id: String, archived: Bool, now: Date = .now) throws {
        try database.write { db in
            guard var record = try AgentSessionRecord.fetchOne(db, key: id) else {
                throw AgentSessionRepositoryError.sessionNotFound
            }
            record.isArchived = archived
            record.updatedAt = now.timeIntervalSince1970
            try record.update(db)
        }
    }

    public func deleteSession(id: String) throws {
        try database.write { db in
            _ = try AgentSessionRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    /// Deletes the oldest sessions beyond `keep`, including their messages via
    /// the foreign-key cascade. Callers run this during idle maintenance.
    @discardableResult
    public func pruneSessions(keep: Int) throws -> Int {
        guard keep >= 0 else { return 0 }
        return try database.write { db in
            let stale = try AgentSessionRecord
                .order(Column("updated_at").desc)
                .limit(-1, offset: keep)
                .fetchAll(db)
                .map(\.id)
            guard !stale.isEmpty else { return 0 }
            return try AgentSessionRecord
                .filter(stale.contains(Column("id")))
                .deleteAll(db)
        }
    }

    private static func boundedContent(_ content: String) -> String {
        guard content.count > maximumMessageCharacters else { return content }
        return String(content.prefix(maximumMessageCharacters)) + "\n[Message truncated]"
    }

    private static func derivedTitle(from content: String) -> String {
        let flattened = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }
        return String(flattened.prefix(40))
    }
}

public enum AgentSessionRepositoryError: LocalizedError, Equatable, Sendable {
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            I18N.localized("会话不存在或已被删除。", englishFallback: "The conversation no longer exists.")
        }
    }
}

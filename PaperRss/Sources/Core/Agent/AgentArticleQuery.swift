import Foundation
import GRDB

/// A lightweight article projection for assistant prompts and result cards.
/// Full HTML never leaves the database through this type.
public struct AgentArticleSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let feedID: String
    public let feedTitle: String
    public let accountID: String
    public let title: String
    public let url: URL?
    public let publishedAt: Date?
    public let isRead: Bool
    public let isStarred: Bool
    public let summary: String

    public init(
        id: String,
        feedID: String,
        feedTitle: String,
        accountID: String,
        title: String,
        url: URL?,
        publishedAt: Date?,
        isRead: Bool,
        isStarred: Bool,
        summary: String
    ) {
        self.id = id
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.accountID = accountID
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.isRead = isRead
        self.isStarred = isStarred
        self.summary = summary
    }
}

/// Composable query used by the assistant scope picker and digest pipeline.
/// `TimelineScope` intentionally remains single-dimensional; this type adds the
/// source × time composition without changing the reader's query contract.
public final class AgentArticleQuery: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    public func count(scope: AgentScope, accountID: String? = nil) throws -> Int {
        let (whereClause, arguments) = Self.filter(scope: scope, accountID: accountID)
        return try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(DISTINCT i.id)
                FROM items i
                INNER JOIN feeds f ON f.id = i.feed_id
                LEFT JOIN articles a ON a.item_id = i.id
                LEFT JOIN article_states s ON s.item_id = i.id
                WHERE \(whereClause)
                """,
                arguments: StatementArguments(arguments)
            ) ?? 0
        }
    }

    public func fetch(
        scope: AgentScope,
        accountID: String? = nil,
        limit: Int = 30,
        offset: Int = 0
    ) throws -> [AgentArticleSummary] {
        let (whereClause, arguments) = Self.filter(scope: scope, accountID: accountID)
        let boundedLimit = max(1, min(limit, 500))
        let boundedOffset = max(0, offset)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    i.id AS id,
                    i.feed_id AS feed_id,
                    i.account_id AS account_id,
                    COALESCE(NULLIF(f.custom_title, ''), f.title) AS feed_title,
                    COALESCE(a.title, '') AS title,
                    a.url AS url,
                    a.published_at AS published_at,
                    COALESCE(a.summary, '') AS summary,
                    COALESCE(s.is_read, 0) AS is_read,
                    COALESCE(s.is_starred, 0) AS is_starred
                FROM items i
                INNER JOIN feeds f ON f.id = i.feed_id
                LEFT JOIN articles a ON a.item_id = i.id
                LEFT JOIN article_states s ON s.item_id = i.id
                WHERE \(whereClause)
                ORDER BY COALESCE(a.published_at, i.created_at) DESC, i.id DESC
                LIMIT \(boundedLimit) OFFSET \(boundedOffset)
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.compactMap(Self.summary(from:))
        }
    }

    public func feedOptions(accountID: String? = nil, limit: Int = 500) throws -> [AgentSourceOption] {
        try database.read { db in
            var whereClauses = ["f.is_deleted = 0"]
            var arguments: [String: (any DatabaseValueConvertible)?] = [:]
            if let accountID {
                whereClauses.append("f.account_id = :account_id")
                arguments["account_id"] = accountID
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    f.id AS id,
                    f.account_id AS account_id,
                    COALESCE(NULLIF(f.custom_title, ''), f.title) AS title,
                    COUNT(DISTINCT CASE WHEN COALESCE(s.is_read, 0) = 0 THEN i.id END) AS unread
                FROM feeds f
                LEFT JOIN items i ON i.feed_id = f.id
                LEFT JOIN article_states s ON s.item_id = i.id
                WHERE \(whereClauses.joined(separator: " AND "))
                GROUP BY f.id
                ORDER BY unread DESC, title COLLATE NOCASE ASC
                LIMIT \(max(1, min(limit, 1_000)))
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.map { row in
                AgentSourceOption(
                    id: row["id"],
                    title: HTMLTextDecoder.decoded(row["title"]),
                    unreadCount: row["unread"],
                    kind: .feed,
                    accountID: row["account_id"]
                )
            }
        }
    }

    public func folderOptions(accountID: String? = nil, limit: Int = 200) throws -> [AgentSourceOption] {
        try database.read { db in
            var whereClauses = ["fo.is_deleted = 0"]
            var arguments: [String: (any DatabaseValueConvertible)?] = [:]
            if let accountID {
                whereClauses.append("fo.account_id = :account_id")
                arguments["account_id"] = accountID
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    fo.id AS id,
                    fo.account_id AS account_id,
                    fo.name AS name,
                    COUNT(DISTINCT CASE WHEN COALESCE(s.is_read, 0) = 0 THEN i.id END) AS unread
                FROM folders fo
                INNER JOIN feed_folders ff ON ff.folder_id = fo.id
                INNER JOIN feeds f ON f.id = ff.feed_id AND f.is_deleted = 0
                LEFT JOIN items i ON i.feed_id = f.id
                LEFT JOIN article_states s ON s.item_id = i.id
                WHERE \(whereClauses.joined(separator: " AND "))
                GROUP BY fo.id
                ORDER BY unread DESC, fo.name COLLATE NOCASE ASC
                LIMIT \(max(1, min(limit, 500)))
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.map { row in
                AgentSourceOption(
                    id: row["id"],
                    title: row["name"],
                    unreadCount: row["unread"],
                    kind: .folder,
                    accountID: row["account_id"],
                    folderName: row["name"]
                )
            }
        }
    }

    private static func filter(
        scope: AgentScope,
        accountID: String?
    ) -> (String, [String: (any DatabaseValueConvertible)?]) {
        var whereClauses = ["f.is_deleted = 0"]
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        if let accountID {
            whereClauses.append("i.account_id = :account_id")
            arguments["account_id"] = accountID
        }
        switch scope.source {
        case .all:
            break
        case .feeds(let feedIDs):
            if feedIDs.isEmpty {
                whereClauses.append("1 = 0")
            } else {
                let placeholders = feedIDs.enumerated().map { index, id -> String in
                    let key = "feed_\(index)"
                    arguments[key] = id
                    return ":\(key)"
                }.joined(separator: ", ")
                whereClauses.append("i.feed_id IN (\(placeholders))")
            }
        case .folders(let folders):
            if folders.isEmpty {
                whereClauses.append("1 = 0")
            } else {
                let placeholders = folders.enumerated().map { index, folder -> String in
                    let key = "folder_\(index)"
                    arguments[key] = folder.id
                    return ":\(key)"
                }.joined(separator: ", ")
                whereClauses.append("""
                i.feed_id IN (
                    SELECT ff.feed_id
                    FROM feed_folders ff
                    INNER JOIN folders fo ON fo.id = ff.folder_id
                    WHERE fo.is_deleted = 0 AND fo.id IN (\(placeholders))
                )
                """)
            }
        }
        if let from = scope.from {
            let key = "from"
            arguments[key] = from.timeIntervalSince1970
            whereClauses.append("(a.published_at >= :from OR (a.published_at IS NULL AND i.created_at >= :from))")
        }
        if let to = scope.to {
            let key = "to"
            arguments[key] = to.timeIntervalSince1970
            whereClauses.append("(a.published_at <= :to OR (a.published_at IS NULL AND i.created_at <= :to))")
        }
        if scope.unreadOnly {
            whereClauses.append("COALESCE(s.is_read, 0) = 0")
        }
        return (whereClauses.joined(separator: " AND "), arguments)
    }

    private static func summary(from row: Row) -> AgentArticleSummary? {
        guard let id: String = row["id"],
              let accountID: String = row["account_id"] else { return nil }
        let publishedTimestamp: Double? = row["published_at"]
        let urlString: String? = row["url"]
        let rawSummary: String = row["summary"]
        let decodedSummary = HTMLTextDecoder.decoded(rawSummary)
        let summary = decodedSummary.count > 600
            ? String(decodedSummary.prefix(600)) + "…"
            : decodedSummary
        return AgentArticleSummary(
            id: id,
            feedID: row["feed_id"],
            feedTitle: HTMLTextDecoder.decoded(row["feed_title"]),
            accountID: accountID,
            title: HTMLTextDecoder.decoded(row["title"]),
            url: urlString.flatMap(URL.init(string:)),
            publishedAt: publishedTimestamp.map { Date(timeIntervalSince1970: $0) },
            isRead: (row["is_read"] as Int) == 1,
            isStarred: (row["is_starred"] as Int) == 1,
            summary: summary
        )
    }
}

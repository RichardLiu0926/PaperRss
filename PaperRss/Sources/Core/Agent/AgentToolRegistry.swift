import Foundation

public struct AgentToolContext: Sendable {
    public let accountID: String?
    public let scope: AgentScope
    public let sessionID: String?

    public init(accountID: String?, scope: AgentScope, sessionID: String?) {
        self.accountID = accountID
        self.scope = scope
        self.sessionID = sessionID
    }
}

public struct AgentUIAction: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case openArticle
    }

    public let kind: Kind
    public let entryID: String

    public init(kind: Kind, entryID: String) {
        self.kind = kind
        self.entryID = entryID
    }
}

public enum AgentToolOutcome: Equatable, Sendable {
    case result(json: String)
    case action(AgentUIAction)
}

public enum AgentToolError: LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case articleNotFound(String)
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            I18N.localizedFormat("未知工具：%@", arguments: [name])
        case .invalidArguments(let detail):
            I18N.localizedFormat("工具参数无效：%@", arguments: [detail])
        case .articleNotFound(let id):
            I18N.localizedFormat("文章不存在或不在当前账号：%@", arguments: [id])
        case .emptyQuery:
            I18N.localized("搜索词不能为空。", englishFallback: "The search query must not be empty.")
        }
    }
}

/// Executes the assistant's read-only tools. Scope authority stays with the UI:
/// tools can narrow within the session scope but cannot widen it, and no tool
/// here mutates read/starred state.
public final class AgentToolRegistry: Sendable {
    private let query: AgentArticleQuery
    private let articles: ArticleRepository
    private let cache: CacheRepository

    public init(database: LibraryDatabase) {
        self.query = AgentArticleQuery(database: database)
        self.articles = ArticleRepository(database: database)
        self.cache = CacheRepository(database: database)
    }

    public static let readOnlyDefinitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "list_articles",
            description: "List articles in the current analysis scope. Use this before summarizing or recommending.",
            parameters: [
                AgentToolParameter(name: "limit", kind: .integer, description: "Maximum articles to return, 1-50. Defaults to 20."),
                AgentToolParameter(name: "offset", kind: .integer, description: "Pagination offset. Defaults to 0.")
            ]
        ),
        AgentToolDefinition(
            name: "get_article",
            description: "Read one article's cached text or summary by id. Does not fetch the web and does not mark it read.",
            parameters: [
                AgentToolParameter(name: "id", kind: .string, description: "Article id from list_articles or search_articles.", isRequired: true),
                AgentToolParameter(name: "maxChars", kind: .integer, description: "Maximum content characters, 1000-40000. Defaults to 20000.")
            ]
        ),
        AgentToolDefinition(
            name: "search_articles",
            description: "Search titles and summaries inside the current analysis scope.",
            parameters: [
                AgentToolParameter(name: "query", kind: .string, description: "Case-insensitive substring to search for.", isRequired: true),
                AgentToolParameter(name: "limit", kind: .integer, description: "Maximum articles to return, 1-50. Defaults to 10.")
            ]
        ),
        AgentToolDefinition(
            name: "get_unread_stats",
            description: "Unread counts grouped by feed inside the current analysis scope.",
            parameters: []
        ),
        AgentToolDefinition(
            name: "get_feeds",
            description: "List feeds and their unread counts for the active account.",
            parameters: []
        ),
        AgentToolDefinition(
            name: "open_article",
            description: "Ask the UI to select and open an article. This never changes read state.",
            parameters: [
                AgentToolParameter(name: "id", kind: .string, description: "Article id to open.", isRequired: true)
            ]
        )
    ]

    public func execute(_ call: AgentToolCall, context: AgentToolContext) async throws -> AgentToolOutcome {
        let arguments: AgentToolArguments
        do {
            arguments = try AgentToolArguments(json: call.arguments)
        } catch {
            throw AgentToolError.invalidArguments(call.arguments)
        }
        switch call.name {
        case "list_articles":
            return try listArticles(arguments, context: context)
        case "get_article":
            return try await getArticle(arguments, context: context)
        case "search_articles":
            return try searchArticles(arguments, context: context)
        case "get_unread_stats":
            return try unreadStats(context: context)
        case "get_feeds":
            return try feeds(context: context)
        case "open_article":
            return try openArticle(arguments, context: context)
        default:
            throw AgentToolError.unknownTool(call.name)
        }
    }

    // MARK: - Read tools

    private func listArticles(_ arguments: AgentToolArguments, context: AgentToolContext) throws -> AgentToolOutcome {
        let limit = try arguments.int("limit", default: 20, range: 1...50)
        let offset = try arguments.int("offset", default: 0, range: 0...10_000)
        let total = try query.count(scope: context.scope, accountID: context.accountID)
        let items = try query.fetch(scope: context.scope, accountID: context.accountID, limit: limit, offset: offset)
        return .result(json: try Self.encode(ListPayload(
            articles: items.map(ArticlePayload.init),
            total: total,
            hasMore: offset + items.count < total
        )))
    }

    private func getArticle(_ arguments: AgentToolArguments, context: AgentToolContext) async throws -> AgentToolOutcome {
        let id = try arguments.requiredString("id")
        let maxChars = try arguments.int("maxChars", default: 20_000, range: 1_000...40_000)
        guard let summary = try query.summary(id: id, accountID: context.accountID) else {
            throw AgentToolError.articleNotFound(id)
        }
        let entry = try await articles.fetchEntry(id: id)
        let cached = try await cache.fetchCacheModel(itemID: id)
        let cachedText = cached?.text.nilIfEmpty
        let entryText = entry?.sourceText.nilIfEmpty
        let rawContent = cachedText ?? entryText ?? summary.summary
        let truncated = rawContent.count > maxChars
        let content = truncated ? String(rawContent.prefix(maxChars)) + "\n[Content truncated]" : rawContent
        return .result(json: try Self.encode(ArticleDetailPayload(
            id: summary.id,
            title: summary.title,
            feed: summary.feedTitle,
            url: summary.url?.absoluteString,
            publishedAt: summary.publishedAt.map { ISO8601DateFormatter().string(from: $0) },
            isRead: summary.isRead,
            isStarred: summary.isStarred,
            summary: summary.summary,
            content: content,
            contentSource: cachedText != nil ? "cache" : (entryText != nil ? "entry" : "summary"),
            truncated: truncated
        )))
    }

    private func searchArticles(_ arguments: AgentToolArguments, context: AgentToolContext) throws -> AgentToolOutcome {
        let term = try arguments.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw AgentToolError.emptyQuery }
        let limit = try arguments.int("limit", default: 10, range: 1...50)
        let items = try query.search(scope: context.scope, query: term, accountID: context.accountID, limit: limit)
        return .result(json: try Self.encode(ListPayload(
            articles: items.map(ArticlePayload.init),
            total: items.count,
            hasMore: false
        )))
    }

    private func unreadStats(context: AgentToolContext) throws -> AgentToolOutcome {
        let total = try query.count(scope: context.scope, accountID: context.accountID)
        let stats = try query.unreadCountsByFeed(scope: context.scope, accountID: context.accountID, limit: 30)
        return .result(json: try Self.encode(UnreadStatsPayload(
            totalUnread: total,
            feeds: stats.map { FeedStatPayload(id: $0.id, title: $0.title, unread: $0.unreadCount) }
        )))
    }

    private func feeds(context: AgentToolContext) throws -> AgentToolOutcome {
        let options = try query.feedOptions(accountID: context.accountID, limit: 100)
        return .result(json: try Self.encode(FeedsPayload(
            feeds: options.map { FeedStatPayload(id: $0.id, title: $0.title, unread: $0.unreadCount) }
        )))
    }

    private func openArticle(_ arguments: AgentToolArguments, context: AgentToolContext) throws -> AgentToolOutcome {
        let id = try arguments.requiredString("id")
        guard try query.summary(id: id, accountID: context.accountID) != nil else {
            throw AgentToolError.articleNotFound(id)
        }
        return .action(AgentUIAction(kind: .openArticle, entryID: id))
    }

    // MARK: - Encoding

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct ListPayload: Encodable {
        let articles: [ArticlePayload]
        let total: Int
        let hasMore: Bool
    }

    private struct ArticlePayload: Encodable {
        let id: String
        let title: String
        let feed: String
        let publishedAt: String?
        let isRead: Bool
        let isStarred: Bool
        let summary: String
        let url: String?

        init(_ article: AgentArticleSummary) {
            self.id = article.id
            self.title = article.title
            self.feed = article.feedTitle
            self.publishedAt = article.publishedAt.map { ISO8601DateFormatter().string(from: $0) }
            self.isRead = article.isRead
            self.isStarred = article.isStarred
            self.summary = article.summary
            self.url = article.url?.absoluteString
        }
    }

    private struct ArticleDetailPayload: Encodable {
        let id: String
        let title: String
        let feed: String
        let url: String?
        let publishedAt: String?
        let isRead: Bool
        let isStarred: Bool
        let summary: String
        let content: String
        let contentSource: String
        let truncated: Bool
    }

    private struct UnreadStatsPayload: Encodable {
        let totalUnread: Int
        let feeds: [FeedStatPayload]
    }

    private struct FeedsPayload: Encodable {
        let feeds: [FeedStatPayload]
    }

    private struct FeedStatPayload: Encodable {
        let id: String
        let title: String
        let unread: Int
    }
}

private struct AgentToolArguments {
    private let values: [String: Any]

    init(json: String) throws {
        let data = Data(json.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentToolError.invalidArguments(json)
        }
        self.values = object
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = values[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("missing string '\(key)'")
        }
        return value
    }

    func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key] else { return defaultValue }
        let value: Int
        if let number = raw as? NSNumber {
            value = number.intValue
        } else if let string = raw as? String, let parsed = Int(string) {
            value = parsed
        } else {
            throw AgentToolError.invalidArguments("'\(key)' must be an integer")
        }
        guard range.contains(value) else {
            throw AgentToolError.invalidArguments("'\(key)' must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

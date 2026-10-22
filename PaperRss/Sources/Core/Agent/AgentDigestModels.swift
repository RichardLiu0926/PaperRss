import Foundation

public enum AgentTriageVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case worthReading = "worth_reading"
    case skippable = "skippable"
    case later = "later"

    public var titleZH: String {
        switch self {
        case .worthReading: "值得读"
        case .skippable: "可跳过"
        case .later: "稍后读"
        }
    }

    public var titleEN: String {
        switch self {
        case .worthReading: "Worth reading"
        case .skippable: "Skippable"
        case .later: "Read later"
        }
    }

    /// Accepts the canonical value plus common Chinese/English aliases emitted
    /// by local models. Unknown values are rejected by the parser.
    public static func parse(_ raw: String) -> AgentTriageVerdict? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "worth_reading", "worthreading", "worth", "值得读", "值得", "推荐":
            return .worthReading
        case "skippable", "skip", "可跳过", "跳过", "不用读":
            return .skippable
        case "later", "read_later", "稍后读", "稍后", "待读":
            return .later
        default:
            return AgentTriageVerdict(rawValue: value)
        }
    }
}

public struct AgentDuplicatePreview: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let feedTitle: String

    public init(id: String, title: String, feedTitle: String) {
        self.id = id
        self.title = title
        self.feedTitle = feedTitle
    }
}

public struct AgentDigestItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let feedTitle: String
    public let url: URL?
    public let publishedAt: Date?
    public let verdict: AgentTriageVerdict
    public let reason: String
    public let bullets: [String]
    public let isRead: Bool
    public let isStarred: Bool
    public let analysisFailed: Bool
    /// Other articles in the same story cluster. The digest keeps one item per
    /// cluster, so the UI can show "3 篇同题" without duplicating verdicts.
    public let duplicateIDs: [String]
    public let duplicatePreviews: [AgentDuplicatePreview]
    public let clusterReason: String?

    public init(
        id: String,
        title: String,
        feedTitle: String,
        url: URL?,
        publishedAt: Date?,
        verdict: AgentTriageVerdict,
        reason: String,
        bullets: [String] = [],
        isRead: Bool,
        isStarred: Bool,
        analysisFailed: Bool = false,
        duplicateIDs: [String] = [],
        duplicatePreviews: [AgentDuplicatePreview] = [],
        clusterReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.feedTitle = feedTitle
        self.url = url
        self.publishedAt = publishedAt
        self.verdict = verdict
        self.reason = reason
        self.bullets = bullets
        self.isRead = isRead
        self.isStarred = isStarred
        self.analysisFailed = analysisFailed
        self.duplicateIDs = duplicateIDs
        self.duplicatePreviews = duplicatePreviews
        self.clusterReason = clusterReason
    }

    public var clusterSize: Int { duplicateIDs.count + 1 }
}

public struct AgentDigest: Codable, Hashable, Sendable {
    public let scope: AgentScope
    public let generatedAt: Date
    public let unreadCount: Int
    public let analyzedCount: Int
    public let deepReadCount: Int
    public let model: String
    public let items: [AgentDigestItem]

    public init(
        scope: AgentScope,
        generatedAt: Date,
        unreadCount: Int,
        analyzedCount: Int,
        deepReadCount: Int,
        model: String,
        items: [AgentDigestItem]
    ) {
        self.scope = scope
        self.generatedAt = generatedAt
        self.unreadCount = unreadCount
        self.analyzedCount = analyzedCount
        self.deepReadCount = deepReadCount
        self.model = model
        self.items = items
    }

    public func items(for verdict: AgentTriageVerdict) -> [AgentDigestItem] {
        items.filter { $0.verdict == verdict }
    }

    public var worthReadingCount: Int { items(for: .worthReading).count }
    public var skippableCount: Int { items(for: .skippable).count }
    public var laterCount: Int { items(for: .later).count }
    public var failedCount: Int { items.filter(\.analysisFailed).count }
    public var clusteredArticleCount: Int { items.reduce(0) { $0 + $1.duplicateIDs.count } }

    /// Marks the selected articles (including same-story duplicates) as read
    /// without rebuilding the whole triage. Used after a confirmed write so the
    /// result card does not keep offering an already-applied action.
    public func markingRead(_ selectedIDs: Set<String>) -> AgentDigest {
        var newlyRead = 0
        var changed = false
        let updated = items.map { item -> AgentDigestItem in
            guard !item.isRead else { return item }
            let matched = selectedIDs.contains(item.id)
                || item.duplicateIDs.contains { selectedIDs.contains($0) }
            guard matched else { return item }
            changed = true
            newlyRead += 1 + item.duplicateIDs.count
            return AgentDigestItem(
                id: item.id,
                title: item.title,
                feedTitle: item.feedTitle,
                url: item.url,
                publishedAt: item.publishedAt,
                verdict: item.verdict,
                reason: item.reason,
                bullets: item.bullets,
                isRead: true,
                isStarred: item.isStarred,
                analysisFailed: item.analysisFailed,
                duplicateIDs: item.duplicateIDs,
                duplicatePreviews: item.duplicatePreviews,
                clusterReason: item.clusterReason
            )
        }
        guard changed else { return self }
        return AgentDigest(
            scope: scope,
            generatedAt: generatedAt,
            unreadCount: max(0, unreadCount - newlyRead),
            analyzedCount: analyzedCount,
            deepReadCount: deepReadCount,
            model: model,
            items: updated
        )
    }
}

public enum AgentDigestProgress: Equatable, Sendable {
    case counting
    case analyzing(completed: Int, total: Int)
    case deepReading(completed: Int, total: Int)
    case finished
}

public enum AgentDigestError: LocalizedError, Equatable, Sendable {
    case emptyScope
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .emptyScope:
            I18N.localized("当前范围没有未读文章。", englishFallback: "No unread articles in the selected scope.")
        case .invalidResponse:
            I18N.localized("模型返回的分析结果无法识别，请重试。", englishFallback: "The model returned an unreadable analysis. Try again.")
        }
    }
}

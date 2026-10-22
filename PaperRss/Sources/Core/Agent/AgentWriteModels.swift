import Foundation

public enum AgentWriteKind: String, Codable, Hashable, Sendable {
    case markRead
    case markStarred

    public var toolName: String {
        switch self {
        case .markRead: "propose_mark_read"
        case .markStarred: "propose_mark_starred"
        }
    }

    public var titleZH: String {
        switch self {
        case .markRead: "标记已读"
        case .markStarred: "加星标"
        }
    }

    public var titleEN: String {
        switch self {
        case .markRead: "Mark read"
        case .markStarred: "Star"
        }
    }
}

public struct AgentWriteItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let feedTitle: String
    public let isRead: Bool
    public let isStarred: Bool

    public init(id: String, title: String, feedTitle: String, isRead: Bool, isStarred: Bool) {
        self.id = id
        self.title = title
        self.feedTitle = feedTitle
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

public struct AgentWriteProposal: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: AgentWriteKind
    public let items: [AgentWriteItem]
    public let desiredValue: Bool
    public let reason: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: AgentWriteKind,
        items: [AgentWriteItem],
        desiredValue: Bool,
        reason: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.items = items
        self.desiredValue = desiredValue
        self.reason = reason
        self.createdAt = createdAt
    }

    public var title: String { kind.titleZH }
    public var count: Int { items.count }
}

public enum AgentWriteError: LocalizedError, Equatable, Sendable {
    case noItems
    case tooManyItems(Int)
    case nothingToDo
    case writerUnavailable

    public var errorDescription: String? {
        switch self {
        case .noItems:
            I18N.localized("没有可执行的文章。", englishFallback: "No articles were selected.")
        case .tooManyItems(let count):
            I18N.localizedFormat("一次最多处理 50 篇，当前为 %lld 篇。", arguments: [count])
        case .nothingToDo:
            I18N.localized("这些文章已经处于目标状态。", englishFallback: "Those articles already have the requested state.")
        case .writerUnavailable:
            I18N.localized("当前会话没有写权限。", englishFallback: "This conversation cannot change article state.")
        }
    }
}

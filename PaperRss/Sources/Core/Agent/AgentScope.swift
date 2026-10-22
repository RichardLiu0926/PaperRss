import Foundation

/// Identifies a folder independently of its display name. `id` is the local
/// `folders.id`, so renaming a folder does not invalidate a saved scope.
public struct AgentFolderRef: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let accountID: String
    public let name: String

    public init(id: String, accountID: String, name: String) {
        self.id = id
        self.accountID = accountID
        self.name = name
    }
}

/// Source selection is deliberately mutually exclusive: explicit feeds OR
/// folders. The UI enforces the same rule, so the query layer never needs to
/// guess whether two filters should be intersected or unioned.
public enum AgentSourceScope: Codable, Hashable, Sendable {
    case all
    case feeds([String])
    case folders([AgentFolderRef])

    public var isEmpty: Bool {
        switch self {
        case .all: false
        case .feeds(let ids): ids.isEmpty
        case .folders(let refs): refs.isEmpty
        }
    }
}

public struct AgentScope: Codable, Hashable, Sendable {
    public var source: AgentSourceScope
    public var from: Date?
    public var to: Date?
    public var unreadOnly: Bool

    public init(
        source: AgentSourceScope = .all,
        from: Date? = nil,
        to: Date? = nil,
        unreadOnly: Bool = true
    ) {
        self.source = source
        self.from = from
        self.to = to
        self.unreadOnly = unreadOnly
    }

    public static let allUnread = AgentScope()

    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    public static func decode(jsonString: String) -> AgentScope? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentScope.self, from: data)
    }
}

/// One selectable feed or folder for the scope picker.
public struct AgentSourceOption: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case feed
        case folder
    }

    public let id: String
    public let title: String
    public let unreadCount: Int
    public let kind: Kind
    public let accountID: String
    public let folderName: String?

    public init(
        id: String,
        title: String,
        unreadCount: Int,
        kind: Kind,
        accountID: String,
        folderName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.unreadCount = unreadCount
        self.kind = kind
        self.accountID = accountID
        self.folderName = folderName
    }
}

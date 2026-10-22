import Foundation

/// Validates write proposals against the local library. A proposal never
/// mutates state; it only resolves ids to titles and records the prior flags so
/// the UI can show exactly what will change.
public final class AgentWritePlanner: Sendable {
    public static let maximumBatchSize = 50

    private let query: AgentArticleQuery

    public init(database: LibraryDatabase) {
        self.query = AgentArticleQuery(database: database)
    }

    public func propose(
        kind: AgentWriteKind,
        ids: [String],
        desiredValue: Bool,
        reason: String,
        accountID: String?
    ) throws -> AgentWriteProposal {
        let uniqueIDs = Array(NSOrderedSet(array: ids).compactMap { $0 as? String })
        guard !uniqueIDs.isEmpty else { throw AgentWriteError.noItems }
        guard uniqueIDs.count <= Self.maximumBatchSize else {
            throw AgentWriteError.tooManyItems(uniqueIDs.count)
        }

        var items: [AgentWriteItem] = []
        for id in uniqueIDs {
            guard let summary = try query.summary(id: id, accountID: accountID) else { continue }
            if kind == .markRead, summary.isRead == desiredValue { continue }
            if kind == .markStarred, summary.isStarred == desiredValue { continue }
            items.append(AgentWriteItem(
                id: summary.id,
                title: summary.title,
                feedTitle: summary.feedTitle,
                isRead: summary.isRead,
                isStarred: summary.isStarred
            ))
        }
        guard !items.isEmpty else { throw AgentWriteError.nothingToDo }
        return AgentWriteProposal(
            kind: kind,
            items: items,
            desiredValue: desiredValue,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@MainActor
public protocol AgentStateWriting: AnyObject {
    func applyReadState(entryIDs: [String], read: Bool)
    func applyStarredState(entryIDs: [String], starred: Bool)
}

/// Executes a user-confirmed proposal through the app's existing write path and
/// records an audit row that can be undone.
@MainActor
public final class AgentWriteExecutor {
    private let writer: any AgentStateWriting
    private let actions: AgentActionRepository

    public init(writer: any AgentStateWriting, actions: AgentActionRepository) {
        self.writer = writer
        self.actions = actions
    }

    public func execute(
        proposal: AgentWriteProposal,
        selectedIDs: Set<String>? = nil,
        sessionID: String?,
        messageID: String?
    ) throws -> AgentAction {
        let selected = proposal.items.filter { selectedIDs?.contains($0.id) ?? true }
        guard !selected.isEmpty else { throw AgentWriteError.noItems }

        switch proposal.kind {
        case .markRead:
            writer.applyReadState(entryIDs: selected.map(\.id), read: proposal.desiredValue)
        case .markStarred:
            writer.applyStarredState(entryIDs: selected.map(\.id), starred: proposal.desiredValue)
        }

        let priorData = try JSONEncoder().encode(selected)
        let priorJSON = String(data: priorData, encoding: .utf8) ?? "[]"
        let args: [String: Any] = [
            "ids": selected.map(\.id),
            "value": proposal.desiredValue
        ]
        let argsJSON = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try actions.record(
            sessionID: sessionID,
            messageID: messageID,
            tool: proposal.kind.toolName,
            argumentsJSON: argsJSON,
            affectedIDs: selected.map(\.id),
            priorStatesJSON: priorJSON
        )
    }

    public func undo(action: AgentAction) throws {
        guard let data = action.priorStatesJSON.data(using: .utf8),
              let items = try? JSONDecoder().decode([AgentWriteItem].self, from: data) else {
            return
        }
        switch action.tool {
        case AgentWriteKind.markRead.toolName:
            for item in items {
                writer.applyReadState(entryIDs: [item.id], read: item.isRead)
            }
        case AgentWriteKind.markStarred.toolName:
            for item in items {
                writer.applyStarredState(entryIDs: [item.id], starred: item.isStarred)
            }
        default:
            return
        }
        try actions.markUndone(id: action.id)
    }
}

import Foundation

/// Caches a triage result as one global AI artifact keyed by scope, model and
/// limits. Reopening the same scope can show the previous result immediately;
/// "analyze again" bypasses the cache.
public final class AgentDigestCache: Sendable {
    public static let promptVersion = 1
    public static let maximumAge: TimeInterval = 60 * 60

    private let database: LibraryDatabase
    private let repository: AIArtifactRepository

    public init(database: LibraryDatabase) {
        self.database = database
        self.repository = AIArtifactRepository(database: database)
    }

    public func load(
        scope: AgentScope,
        accountID: String?,
        configuration: LLMConfiguration,
        maximumArticles: Int,
        deepReadLimit: Int,
        now: Date = .now
    ) throws -> AgentDigest? {
        let key = cacheKey(
            scope: scope,
            accountID: accountID,
            configuration: configuration,
            maximumArticles: maximumArticles,
            deepReadLimit: deepReadLimit
        )
        guard let record = try database.read({ db in
            try repository.fetchGlobalArtifact(
                subjectKey: key.subjectKey,
                kind: AIArtifactKind.triage.rawValue,
                contentHash: key.contentHash,
                in: db
            )
        }) else { return nil }
        guard now.timeIntervalSince1970 - record.createdAt <= Self.maximumAge else { return nil }
        guard let data = record.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentDigest.self, from: data)
    }

    public func save(
        _ digest: AgentDigest,
        accountID: String?,
        configuration: LLMConfiguration,
        maximumArticles: Int,
        deepReadLimit: Int
    ) throws {
        let key = cacheKey(
            scope: digest.scope,
            accountID: accountID,
            configuration: configuration,
            maximumArticles: maximumArticles,
            deepReadLimit: deepReadLimit
        )
        let data = try JSONEncoder().encode(digest)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let artifact = AIArtifact(
            entryID: key.subjectKey,
            kind: .triage,
            contentHash: key.contentHash,
            model: configuration.model,
            targetLanguage: configuration.targetLanguage,
            promptVersion: Self.promptVersion,
            providerID: nil,
            configurationFingerprint: key.contentHash,
            content: json,
            isComplete: true
        )
        try database.write { db in
            try repository.saveArtifactModel(artifact, accountID: nil, in: db)
        }
    }

    private func cacheKey(
        scope: AgentScope,
        accountID: String?,
        configuration: LLMConfiguration,
        maximumArticles: Int,
        deepReadLimit: Int
    ) -> (subjectKey: String, contentHash: String) {
        let raw = [
            scope.jsonString,
            accountID ?? "*",
            configuration.baseURL,
            configuration.model,
            String(maximumArticles),
            String(deepReadLimit),
            String(Self.promptVersion)
        ].joined(separator: "|")
        let hash = raw.stableDigest
        return ("agent-digest-v1:\(hash)", hash)
    }
}

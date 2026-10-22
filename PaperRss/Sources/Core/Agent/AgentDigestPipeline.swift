import Foundation

/// Deterministic unread-analysis pipeline: fetch the scope, screen in small
/// batches, then deep-read only the top-ranked articles. Clustering and cached
/// artifacts are layered on top later; this type already keeps the prompt,
/// parsing, and limits testable without any UI.
public final class AgentDigestPipeline: Sendable {
    private struct ScreeningUnit {
        let cluster: AgentArticleCluster
        let representative: AgentArticleSummary
        let duplicates: [AgentArticleSummary]
    }

    private let query: AgentArticleQuery
    private let articles: ArticleRepository
    private let cache: CacheRepository
    private let llm: LLMService

    public init(
        database: LibraryDatabase,
        llm: LLMService = LLMService()
    ) {
        self.query = AgentArticleQuery(database: database)
        self.articles = ArticleRepository(database: database)
        self.cache = CacheRepository(database: database)
        self.llm = llm
    }

    public func run(
        scope: AgentScope,
        accountID: String? = nil,
        configuration: LLMConfiguration,
        apiKey: String,
        maximumArticles: Int = 30,
        deepReadLimit: Int = 5,
        batchSize: Int = 8,
        onProgress: (@Sendable (AgentDigestProgress) async -> Void)? = nil
    ) async throws -> AgentDigest {
        await onProgress?(.counting)
        let unreadCount = try query.count(scope: scope, accountID: accountID)
        guard unreadCount > 0 else { throw AgentDigestError.emptyScope }

        let limit = max(1, min(maximumArticles, 100))
        let summaries = try query.fetch(scope: scope, accountID: accountID, limit: limit)
        guard !summaries.isEmpty else { throw AgentDigestError.emptyScope }

        let units = try await screeningUnits(for: summaries)
        let batchLength = max(1, min(batchSize, 10))
        var verdicts: [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)] = [:]
        var completed = 0

        for batch in stride(from: 0, to: units.count, by: batchLength) {
            try Task.checkCancellation()
            let slice = Array(units[batch..<min(batch + batchLength, units.count)])
            // A malformed batch must not abort the whole digest; retry each
            // article once and degrade only the failures.
            let parsed: [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)]
            do {
                parsed = try await analyzeBatch(
                    slice,
                    configuration: configuration,
                    apiKey: apiKey
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                parsed = [:]
            }
            for unit in slice {
                let id = unit.representative.id
                if let result = parsed[id] {
                    verdicts[id] = result
                } else {
                    let single: [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)]
                    do {
                        single = try await analyzeBatch(
                            [unit],
                            configuration: configuration,
                            apiKey: apiKey
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        single = [:]
                    }
                    verdicts[id] = single[id] ?? (
                        .later,
                        I18N.localized("分析失败，可重试。", englishFallback: "Analysis failed; retry when ready."),
                        true
                    )
                }
            }
            completed += slice.count
            await onProgress?(.analyzing(completed: completed, total: summaries.count))
        }

        var items = units.map { unit -> AgentDigestItem in
            let summary = unit.representative
            let outcome = verdicts[summary.id] ?? (
                .later,
                I18N.localized("未分析。", englishFallback: "Not analyzed."),
                true
            )
            return AgentDigestItem(
                id: summary.id,
                title: summary.title,
                feedTitle: summary.feedTitle,
                url: summary.url,
                publishedAt: summary.publishedAt,
                verdict: outcome.verdict,
                reason: outcome.reason,
                isRead: summary.isRead,
                isStarred: summary.isStarred,
                analysisFailed: outcome.failed,
                duplicateIDs: unit.cluster.duplicateIDs,
                duplicatePreviews: unit.duplicates.map {
                    AgentDuplicatePreview(id: $0.id, title: $0.title, feedTitle: $0.feedTitle)
                },
                clusterReason: unit.cluster.similarityReason
            )
        }
        items.sort(by: Self.rank)

        let deepReadTargets = items
            .filter { $0.verdict == .worthReading && !$0.analysisFailed }
            .prefix(max(0, min(deepReadLimit, 10)))
        var deepReadCount = 0
        for (index, target) in deepReadTargets.enumerated() {
            try Task.checkCancellation()
            if let bullets = try await deepRead(
                id: target.id,
                accountID: accountID,
                configuration: configuration,
                apiKey: apiKey
            ) {
                if let itemIndex = items.firstIndex(where: { $0.id == target.id }) {
                    let old = items[itemIndex]
                    items[itemIndex] = AgentDigestItem(
                        id: old.id,
                        title: old.title,
                        feedTitle: old.feedTitle,
                        url: old.url,
                        publishedAt: old.publishedAt,
                        verdict: old.verdict,
                        reason: old.reason,
                        bullets: bullets,
                        isRead: old.isRead,
                        isStarred: old.isStarred,
                        analysisFailed: old.analysisFailed,
                        duplicateIDs: old.duplicateIDs,
                        duplicatePreviews: old.duplicatePreviews,
                        clusterReason: old.clusterReason
                    )
                    deepReadCount += 1
                }
            }
            await onProgress?(.deepReading(completed: index + 1, total: deepReadTargets.count))
        }

        await onProgress?(.finished)
        return AgentDigest(
            scope: scope,
            generatedAt: .now,
            unreadCount: unreadCount,
            analyzedCount: units.count,
            deepReadCount: deepReadCount,
            model: configuration.model,
            items: items
        )
    }

    // MARK: - Screening

    private func screeningUnits(for summaries: [AgentArticleSummary]) async throws -> [ScreeningUnit] {
        var candidates: [AgentClusterCandidate] = []
        for summary in summaries {
            let cached = try? await cache.fetchCacheModel(itemID: summary.id)
            let text = cached?.text
            candidates.append(AgentClusterCandidate(
                id: summary.id,
                title: summary.title,
                summary: summary.summary,
                url: summary.url?.absoluteString,
                feedID: summary.feedID,
                publishedAt: summary.publishedAt,
                contentHash: text.flatMap { $0.isEmpty ? nil : $0.stableDigest },
                contentCharacters: text?.count ?? summary.summary.count
            ))
        }
        let clusters = AgentTopicClusterer().cluster(candidates)
        let summariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        return clusters.compactMap { cluster in
            guard let representative = summariesByID[cluster.representativeID] else { return nil }
            let duplicates = cluster.duplicateIDs.compactMap { summariesByID[$0] }
            return ScreeningUnit(cluster: cluster, representative: representative, duplicates: duplicates)
        }
    }

    private func analyzeBatch(
        _ units: [ScreeningUnit],
        configuration: LLMConfiguration,
        apiKey: String
    ) async throws -> [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)] {
        let language = configuration.targetLanguage
        let system = """
        You triage unread articles for a reader. Return ONLY a JSON array. Each element must be:
        {"id":"<id from input>","verdict":"worth_reading|skippable|later","reason":"<one sentence, max 40 characters>"}
        Use only ids from the input. Judge by relevance, information density, and duplication; do not invent facts. Reasons must be written in \(language).
        Input items may list same-story duplicates. Return ONE verdict per id; it covers all duplicates in that group.
        """
        let prompt = units.enumerated().map { index, unit -> String in
            let summary = unit.representative
            let date = summary.publishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            var line = "\(index + 1). id=\(summary.id)\nfeed=\(summary.feedTitle)\npublished=\(date)\ntitle=\(summary.title)\nsummary=\(summary.summary)"
            if !unit.cluster.duplicateIDs.isEmpty {
                line += "\nsame_story_duplicates=\(unit.cluster.duplicateIDs.count)"
            }
            return line
        }.joined(separator: "\n\n")

        let completion = try await llm.chat(
            messages: [.system(system), .user(prompt)],
            configuration: configuration,
            apiKey: apiKey
        )
        let allowed = Set(units.map { $0.representative.id })
        return try Self.parseVerdicts(completion.content, allowedIDs: allowed, language: language)
    }

    static func parseVerdicts(
        _ content: String,
        allowedIDs: Set<String>,
        language: String
    ) throws -> [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)] {
        let json = extractJSON(content)
        guard let data = json.data(using: .utf8) else { throw AgentDigestError.invalidResponse }
        let decoder = JSONDecoder()
        var raw: [RawVerdict] = []
        if let array = try? decoder.decode([RawVerdict].self, from: data) {
            raw = array
        } else if let wrapper = try? decoder.decode(WrappedVerdicts.self, from: data) {
            raw = wrapper.items
        } else {
            throw AgentDigestError.invalidResponse
        }

        var result: [String: (verdict: AgentTriageVerdict, reason: String, failed: Bool)] = [:]
        for entry in raw {
            guard allowedIDs.contains(entry.id),
                  let verdict = AgentTriageVerdict.parse(entry.verdict) else { continue }
            let reason = (entry.reason ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = language.lowercased().contains("english") ? verdict.titleEN : verdict.titleZH
            result[entry.id] = (verdict, reason.isEmpty ? fallback : String(reason.prefix(80)), false)
        }
        guard !result.isEmpty else { throw AgentDigestError.invalidResponse }
        return result
    }

    private struct RawVerdict: Decodable {
        let id: String
        let verdict: String
        let reason: String?
    }

    private struct WrappedVerdicts: Decodable {
        let items: [RawVerdict]
    }

    /// Accepts fenced JSON and prose around it; models frequently add a short
    /// sentence before the array even when told not to.
    static func extractJSON(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            return String(text[start...end])
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        return text
    }

    // MARK: - Deep read

    private func deepRead(
        id: String,
        accountID: String?,
        configuration: LLMConfiguration,
        apiKey: String
    ) async throws -> [String]? {
        guard let summary = try query.summary(id: id, accountID: accountID) else { return nil }
        let entry = try await articles.fetchEntry(id: id)
        let cached = try await cache.fetchCacheModel(itemID: id)
        let content = cached?.text.nilIfEmpty ?? entry?.sourceText.nilIfEmpty ?? summary.summary
        guard !content.isEmpty else { return nil }
        let excerpt = String(content.prefix(12_000))
        let system = """
        Read the article and give exactly three concise bullet points in \(configuration.targetLanguage).
        Start each line with "- ". No preamble, no conclusion, no extra bullets.
        """
        let completion = try await llm.chat(
            messages: [
                .system(system),
                .user("Title: \(summary.title)\n\n\(excerpt)")
            ],
            configuration: configuration,
            apiKey: apiKey
        )
        return Self.parseBullets(completion.content)
    }

    static func parseBullets(_ content: String) -> [String] {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var bullets: [String] = []
        for line in lines {
            var value = line
            for prefix in ["- ", "* ", "• ", "· "] where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
            }
            if let range = value.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                value.removeSubrange(range)
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            bullets.append(value)
            if bullets.count == 3 { break }
        }
        return bullets
    }

    // MARK: - Ordering

    private static func rank(_ lhs: AgentDigestItem, _ rhs: AgentDigestItem) -> Bool {
        let order: [AgentTriageVerdict: Int] = [.worthReading: 0, .later: 1, .skippable: 2]
        let left = order[lhs.verdict] ?? 3
        let right = order[rhs.verdict] ?? 3
        if left != right { return left < right }
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (l?, r?): return l > r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.id < rhs.id
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

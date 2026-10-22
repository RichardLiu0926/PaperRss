import Foundation

/// A small, deterministic representation of one article for local clustering.
/// `contentHash` is only set when cached text is available, so exact duplicate
/// detection never triggers on a missing/empty body.
public struct AgentClusterCandidate: Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let url: String?
    public let feedID: String
    public let publishedAt: Date?
    public let contentHash: String?
    public let contentCharacters: Int

    public init(
        id: String,
        title: String,
        summary: String,
        url: String?,
        feedID: String,
        publishedAt: Date?,
        contentHash: String? = nil,
        contentCharacters: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.url = url
        self.feedID = feedID
        self.publishedAt = publishedAt
        self.contentHash = contentHash
        self.contentCharacters = contentCharacters
    }
}

public struct AgentArticleCluster: Identifiable, Hashable, Sendable {
    public let id: String
    public let representativeID: String
    public let memberIDs: [String]
    public let similarityReason: String?

    public init(
        id: String,
        representativeID: String,
        memberIDs: [String],
        similarityReason: String? = nil
    ) {
        self.id = id
        self.representativeID = representativeID
        self.memberIDs = memberIDs
        self.similarityReason = similarityReason
    }

    public var isDuplicate: Bool { memberIDs.count > 1 }
    public var duplicateIDs: [String] { memberIDs.filter { $0 != representativeID } }
}

public struct AgentClusterThresholds: Sendable, Equatable {
    public var titleSimilarity: Double
    public var summarySimilarity: Double
    public var timeWindow: TimeInterval
    public var maximumClusterSize: Int

    public init(
        titleSimilarity: Double = 0.72,
        summarySimilarity: Double = 0.45,
        timeWindow: TimeInterval = 72 * 3600,
        maximumClusterSize: Int = 6
    ) {
        self.titleSimilarity = titleSimilarity
        self.summarySimilarity = summarySimilarity
        self.timeWindow = timeWindow
        self.maximumClusterSize = max(2, maximumClusterSize)
    }

    /// Precision-first defaults. Lowering either threshold increases false
    /// merges and must be accompanied by new fixture evidence.
    public static let standard = AgentClusterThresholds()
}

/// Groups articles that cover the same story. This is intentionally local and
/// deterministic: no model tokens, no network, and every merge can be explained
/// by a stable reason string shown in the UI.
public final class AgentTopicClusterer: Sendable {
    private let thresholds: AgentClusterThresholds

    public init(thresholds: AgentClusterThresholds = .standard) {
        self.thresholds = thresholds
    }

    public func cluster(_ candidates: [AgentClusterCandidate]) -> [AgentArticleCluster] {
        guard candidates.count > 1 else {
            return candidates.map { candidate in
                AgentArticleCluster(id: candidate.id, representativeID: candidate.id, memberIDs: [candidate.id])
            }
        }

        var parent = Array(0..<candidates.count)
        var size = Array(repeating: 1, count: candidates.count)
        func find(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ lhs: Int, _ rhs: Int) -> Bool {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return true }
            guard size[left] + size[right] <= thresholds.maximumClusterSize else { return false }
            if size[left] < size[right] {
                parent[left] = right
                size[right] += size[left]
            } else {
                parent[right] = left
                size[left] += size[right]
            }
            return true
        }

        var edges: [(lhs: Int, rhs: Int, strength: Double, reason: String)] = []
        for lhs in candidates.indices {
            for rhs in (lhs + 1)..<candidates.count {
                guard let edge = edge(between: candidates[lhs], and: candidates[rhs], lhs: lhs, rhs: rhs) else { continue }
                edges.append(edge)
            }
        }
        edges.sort {
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            if $0.lhs != $1.lhs { return $0.lhs < $1.lhs }
            return $0.rhs < $1.rhs
        }
        var accepted: [(lhs: Int, rhs: Int, strength: Double, reason: String)] = []
        for edge in edges where union(edge.lhs, edge.rhs) {
            accepted.append(edge)
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in candidates.indices {
            membersByRoot[find(index), default: []].append(index)
        }
        var reasonByRoot: [Int: (Double, String)] = [:]
        for edge in accepted {
            let root = find(edge.lhs)
            if let existing = reasonByRoot[root], existing.0 >= edge.strength { continue }
            reasonByRoot[root] = (edge.strength, edge.reason)
        }

        return membersByRoot
            .sorted { $0.value.min() ?? 0 < $1.value.min() ?? 0 }
            .map { root, indices in
                let representativeIndex = indices.max { lhs, rhs in
                    let left = candidates[lhs]
                    let right = candidates[rhs]
                    if left.contentCharacters != right.contentCharacters {
                        return left.contentCharacters < right.contentCharacters
                    }
                    switch (left.publishedAt, right.publishedAt) {
                    case let (l?, r?): return l > r // earlier wins
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: return left.id > right.id
                    }
                } ?? indices[0]
                let ids = indices.map { candidates[$0].id }
                let representative = candidates[representativeIndex].id
                let ordered = [representative] + ids.filter { $0 != representative }
                return AgentArticleCluster(
                    id: representative,
                    representativeID: representative,
                    memberIDs: ordered,
                    similarityReason: reasonByRoot[root]?.1
                )
            }
    }

    private func edge(
        between lhs: AgentClusterCandidate,
        and rhs: AgentClusterCandidate,
        lhs lhsIndex: Int,
        rhs rhsIndex: Int
    ) -> (lhs: Int, rhs: Int, strength: Double, reason: String)? {
        if Self.isRoundup(lhs.title) || Self.isRoundup(rhs.title) { return nil }

        if let leftURL = Self.canonicalURL(lhs.url), let rightURL = Self.canonicalURL(rhs.url), leftURL == rightURL {
            return (lhsIndex, rhsIndex, 1.0, "同一链接")
        }
        if let leftHash = lhs.contentHash, let rightHash = rhs.contentHash,
           !leftHash.isEmpty, leftHash == rightHash {
            return (lhsIndex, rhsIndex, 0.99, "正文完全一致")
        }
        // Similarity merging is only safe when both timestamps exist and the
        // story is inside the duplicate window.
        guard let leftDate = lhs.publishedAt, let rightDate = rhs.publishedAt,
              abs(leftDate.timeIntervalSince(rightDate)) <= thresholds.timeWindow else { return nil }
        if Self.containsCJK(lhs.title) != Self.containsCJK(rhs.title) { return nil }

        let titleScore = Self.jaccard(Self.ngrams(Self.normalizedTitle(lhs.title), n: 3),
                                      Self.ngrams(Self.normalizedTitle(rhs.title), n: 3))
        guard titleScore >= thresholds.titleSimilarity else { return nil }
        let summaryScore = Self.jaccard(Self.shingles(Self.normalizedBody(lhs.summary), n: 5),
                                        Self.shingles(Self.normalizedBody(rhs.summary), n: 5))
        guard summaryScore >= thresholds.summarySimilarity else { return nil }
        let reason = "标题 \(Int((titleScore * 100).rounded()))% · 摘要 \(Int((summaryScore * 100).rounded()))%"
        return (lhsIndex, rhsIndex, (titleScore + summaryScore) / 2, reason)
    }

    // MARK: - Normalization

    static func canonicalURL(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: raw) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        var host = components.host?.lowercased() ?? ""
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        components.host = host
        var path = components.path
        for suffix in ["/amp", "/amp/"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path.isEmpty ? "/" : path
        let tracking: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "fbclid", "gclid", "spm", "ref", "ref_src", "source", "from",
            "output", "amp", "share", "share_token"
        ]
        components.queryItems = components.queryItems?
            .filter { !tracking.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString.lowercased()
    }

    static func normalizedTitle(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let lowered = stripped.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        let filtered = lowered.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    static func normalizedBody(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let lowered = stripped.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        return String(String.UnicodeScalarView(lowered.unicodeScalars.filter { allowed.contains($0) }))
    }

    static func ngrams(_ text: String, n: Int) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= n else { return characters.isEmpty ? [] : [text] }
        var result = Set<String>()
        for index in 0...(characters.count - n) {
            result.insert(String(characters[index..<(index + n)]))
        }
        return result
    }

    static func shingles(_ text: String, n: Int) -> Set<String> {
        ngrams(String(text.prefix(800)), n: n)
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func isRoundup(_ title: String) -> Bool {
        let keywords = ["周报", "日报", "早报", "晚报", "速览", "盘点", "合集", "周刊", "本周", "一周", "roundup", "digest", "newsletter", "weekly"]
        let lowered = title.lowercased()
        return keywords.contains { lowered.contains($0) }
    }
}


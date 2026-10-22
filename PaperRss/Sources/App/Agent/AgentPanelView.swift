import SwiftUI
import Combine
#if SWIFT_PACKAGE
import PaperRssCore
#endif

extension AppStore: AgentStateWriting {
    public func applyReadState(entryIDs: [String], read: Bool) {
        markRead(entryIDs: entryIDs, read: read)
    }

    public func applyStarredState(entryIDs: [String], starred: Bool) {
        markStarred(entryIDs: entryIDs, starred: starred)
    }
}

@MainActor
final class AgentPanelModel: ObservableObject {
    let store: AppStore
    let controller: AgentSessionController
    @Published var draft = ""

    @Published var actionError: String?
    @Published private(set) var feedOptions: [AgentSourceOption] = []
    @Published private(set) var folderOptions: [AgentSourceOption] = []
    @Published private(set) var scopeCount = 0
    @Published var scope: AgentScope = .allUnread
    @Published private(set) var digest: AgentDigest?
    @Published private(set) var digestProgress: AgentDigestProgress?
    @Published private(set) var isDigesting = false
    @Published var digestError: String?
    @Published private(set) var sessions: [AgentSession] = []

    private let sessionRepository: AgentSessionRepository
    private let query: AgentArticleQuery
    private let digestPipeline: AgentDigestPipeline
    private let digestCache: AgentDigestCache
    private let writePlanner: AgentWritePlanner
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()
    private var undoClearTask: Task<Void, Never>?
    private var digestTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
        let database = store.libraryDatabase
        self.sessionRepository = AgentSessionRepository(database: database)
        self.query = AgentArticleQuery(database: database)
        self.digestPipeline = AgentDigestPipeline(database: database)
        self.digestCache = AgentDigestCache(database: database)
        self.writePlanner = AgentWritePlanner(database: database)
        let permission = store.aiSettings.features.agentWritePermission
        let actions = AgentActionRepository(database: database)
        let executor = AgentWriteExecutor(writer: store, actions: actions)
        self.controller = AgentSessionController(
            repository: sessionRepository,
            llm: LLMService(),
            toolRegistry: AgentToolRegistry(database: database, writePermission: permission),
            writeExecutor: executor
        )
        // SwiftUI observes the model, not the nested controller; forward
        // controller changes so streaming text and messages update the panel.
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var configuration: LLMConfiguration? {
        store.aiSettings.resolvedConfiguration(for: .agent)
    }

    var modelLabel: String {
        guard let configuration,
              let reference = store.aiSettings.configuration(for: .agent)?.model else {
            return I18N.shared.localized("未配置模型", "No model")
        }
        let providerName = store.aiProvider(id: reference.providerID)?.name ?? configuration.providerName
        return "\(providerName) · \(configuration.model)"
    }

    var canSend: Bool {
        configuration != nil
            && !controller.isStreaming
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        if let latest = try? store.agentSessionRepository.fetchSessions(limit: 1).first,
           (try? controller.loadSession(id: latest.id)) != nil {
            if let decoded = AgentScope.decode(jsonString: latest.scopeJSON) {
                scope = decoded
            }
            refreshScope()
            loadCachedDigest()
            refreshSessions()
            return
        }
        _ = try? controller.startNewSession(
            scopeJSON: scope.jsonString,
            providerID: store.aiSettings.configuration(for: .agent)?.model?.providerID,
            modelID: store.aiSettings.configuration(for: .agent)?.model?.modelID
        )
        refreshScope()
        loadCachedDigest()
        refreshSessions()
    }

    func refreshSessions() {
        sessions = (try? sessionRepository.fetchSessions(limit: 12)) ?? []
    }

    func newSession() {
        guard let reference = store.aiSettings.configuration(for: .agent)?.model else { return }
        _ = try? controller.startNewSession(
            scopeJSON: scope.jsonString,
            providerID: reference.providerID,
            modelID: reference.modelID
        )
        digest = nil
        digestError = nil
        refreshSessions()
    }

    func loadSession(_ id: String) {
        guard (try? controller.loadSession(id: id)) != nil else { return }
        if let stored = controller.session,
           let decoded = AgentScope.decode(jsonString: stored.scopeJSON) {
            scope = decoded
        }
        digest = nil
        digestError = nil
        refreshScope()
        loadCachedDigest()
        refreshSessions()
    }

    func deleteCurrentSession() {
        try? controller.deleteCurrentSession()
        digest = nil
        digestError = nil
        newSession()
    }

    func refreshScope() {
        scopeCount = previewCount(for: scope)
        feedOptions = (try? query.feedOptions(accountID: store.activeAccountID)) ?? []
        folderOptions = (try? query.folderOptions(accountID: store.activeAccountID)) ?? []
    }

    func previewCount(for candidate: AgentScope) -> Int {
        (try? query.count(scope: candidate, accountID: store.activeAccountID)) ?? 0
    }

    func applyScope(_ next: AgentScope) {
        scope = next
        refreshScope()
        digest = nil
        digestError = nil
        loadCachedDigest()
        try? controller.updateScope(next.jsonString)
    }

    var scopeSummary: String {
        var parts: [String] = []
        switch scope.source {
        case .all:
            parts.append(I18N.shared.localized("全部源", "All feeds"))
        case .feeds(let ids):
            parts.append(AgentL10n.format("%lld 个源", "%lld feeds", [ids.count]))
        case .folders(let refs):
            parts.append(AgentL10n.format("%lld 个分组", "%lld groups", [refs.count]))
        }
        if let from = scope.from {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: from), to: Calendar.current.startOfDay(for: .now)).day ?? 0
            switch days {
            case 0: parts.append(I18N.shared.localized("今天", "Today"))
            case 1...3: parts.append(AgentL10n.format("近 %lld 天", "Last %lld days", [days + 1]))
            case 4...7: parts.append(I18N.shared.localized("近 7 天", "Last 7 days"))
            default:
                let formatter = DateFormatter()
                formatter.dateFormat = "MM/dd"
                parts.append(formatter.string(from: from))
            }
        }
        return parts.joined(separator: " · ")
    }

    func analyzeUnread(force: Bool = false) {
        guard let configuration, !isDigesting else { return }
        let providerID = store.aiSettings.configuration(for: .agent)?.model?.providerID ?? ""
        let apiKey = store.apiKey(for: providerID)
        let scope = self.scope
        let accountID = store.activeAccountID
        if !force,
           let cached = try? digestCache.load(
                scope: scope,
                accountID: accountID,
                configuration: configuration,
                maximumArticles: 30,
                deepReadLimit: 5
           ) {
            digest = cached
            digestProgress = .finished
            return
        }
        digestTask?.cancel()
        isDigesting = true
        digestError = nil
        digest = nil
        digestProgress = .counting
        digestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.digestPipeline.run(
                    scope: scope,
                    accountID: accountID,
                    configuration: configuration,
                    apiKey: apiKey,
                    maximumArticles: 30,
                    deepReadLimit: 5,
                    onProgress: { progress in
                        await MainActor.run { self.digestProgress = progress }
                    }
                )
                self.digest = result
                self.isDigesting = false
                self.digestProgress = .finished
                try? self.digestCache.save(
                    result,
                    accountID: accountID,
                    configuration: configuration,
                    maximumArticles: 30,
                    deepReadLimit: 5
                )
            } catch is CancellationError {
                self.isDigesting = false
                self.digestProgress = nil
            } catch {
                self.isDigesting = false
                self.digestProgress = nil
                self.digestError = error.localizedDescription
            }
        }
    }

    private func loadCachedDigest() {
        guard let configuration else { return }
        if let cached = try? digestCache.load(
            scope: scope,
            accountID: store.activeAccountID,
            configuration: configuration,
            maximumArticles: 30,
            deepReadLimit: 5
        ) {
            digest = cached
            digestProgress = .finished
        }
    }

    func cancelDigest() {
        digestTask?.cancel()
        digestTask = nil
        isDigesting = false
        digestProgress = nil
    }

    var digestProgressText: String {
        switch digestProgress {
        case .counting:
            I18N.shared.localized("正在统计未读…", "Counting unread…")
        case .analyzing(let completed, let total):
            AgentL10n.format("正在分析 %lld / %lld…", "Analyzing %lld / %lld…", [completed, total])
        case .deepReading(let completed, let total):
            AgentL10n.format("正在深读 %lld / %lld…", "Deep reading %lld / %lld…", [completed, total])
        case .finished, .none:
            ""
        }
    }

    func proposeRead(item: AgentDigestItem) {
        proposeRead(ids: [item.id] + item.duplicateIDs, reason: item.reason)
    }

    func proposeSkippable() {
        guard let digest else { return }
        let ids = digest.items(for: .skippable).flatMap { [$0.id] + $0.duplicateIDs }
        proposeRead(ids: ids, reason: I18N.shared.localized("可跳过", "Skippable"))
    }

    private func proposeRead(ids: [String], reason: String) {
        guard store.aiSettings.features.agentWritePermission.allowsMarkRead else {
            actionError = I18N.localized(
                "请先在设置中开启助手写权限。",
                englishFallback: "Enable assistant write permission in Settings first."
            )
            return
        }
        do {
            let proposal = try writePlanner.propose(
                kind: .markRead,
                ids: ids,
                desiredValue: true,
                reason: reason,
                accountID: store.activeAccountID
            )
            controller.presentProposal(proposal)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func send() {
        guard canSend, let configuration else { return }
        let providerID = store.aiSettings.configuration(for: .agent)?.model?.providerID ?? ""
        let apiKey = store.apiKey(for: providerID)
        var tools = AgentToolRegistry.readOnlyDefinitions
        let permission = store.aiSettings.features.agentWritePermission
        controller.updateWritePermission(permission)
        if permission.allowsMarkRead {
            tools += AgentToolRegistry.writeDefinitions(allowsStar: permission.allowsStar)
        }
        controller.send(
            draft,
            configuration: configuration,
            apiKey: apiKey,
            tools: tools,
            toolContext: AgentToolContext(
                accountID: store.activeAccountID,
                scope: scope,
                sessionID: controller.currentSessionID
            ),
            toolProtocol: store.aiSettings.features.agentToolProtocol
        )
        draft = ""
    }

    func confirmPendingProposal(selectedIDs: Set<String>) {
        do {
            try controller.confirmPendingProposal(selectedIDs: selectedIDs)
            actionError = nil
            scheduleUndoClear()
        } catch {
            actionError = error.localizedDescription
        }
    }

    func rejectPendingProposal() {
        controller.rejectPendingProposal()
    }

    func undoLastAction() {
        do {
            try controller.undoLastAction()
            undoClearTask?.cancel()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func stop() {
        controller.cancel()
    }

    private func scheduleUndoClear() {
        undoClearTask?.cancel()
        guard let actionID = controller.lastExecutedAction?.id else { return }
        undoClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, self?.controller.lastExecutedAction?.id == actionID else { return }
            self?.controller.clearLastAction()
        }
    }
}

struct AgentPanelView: View {
    @StateObject private var model: AgentPanelModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var composerFocused: Bool
    @State private var showsScopePicker = false

    let onClose: () -> Void
    let onOpenEntry: (String) -> Void
    let onOpenSettings: () -> Void

    init(
        store: AppStore,
        onClose: @escaping () -> Void,
        onOpenEntry: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: AgentPanelModel(store: store))
        self.onClose = onClose
        self.onOpenEntry = onOpenEntry
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeBar
            Divider().opacity(0.5)
            if let action = model.controller.lastExecutedAction {
                undoBar(action)
            }
            if model.configuration == nil {
                setupState
            } else {
                transcript
                if let actionError = model.actionError {
                    errorBanner(actionError)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                Divider().opacity(0.5)
                composer
            }
        }
        .background(PaperTheme.surface(.articleList, scheme: colorScheme))
        .overlay(alignment: .leading) { Divider().opacity(0.5) }
        .onExitCommand(perform: onClose)
        .onAppear {
            model.start()
            DispatchQueue.main.async { composerFocused = true }
        }
        .onChange(of: model.controller.pendingUIAction) { _, action in
            guard let action else { return }
            if action.kind == .openArticle {
                onOpenEntry(action.entryID)
            }
            _ = model.controller.consumeUIAction()
        }
        .sheet(isPresented: proposalPresented) {
            if let proposal = model.controller.pendingProposal {
                AgentWriteConfirmationView(
                    proposal: proposal,
                    errorMessage: model.actionError,
                    onCancel: {
                        model.rejectPendingProposal()
                    },
                    onConfirm: { selected in
                        model.confirmPendingProposal(selectedIDs: selected)
                    }
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(PaperTheme.warmAccent)
            Text(I18N.shared.localized("AI 助手", "AI Assistant"))
                .font(.system(size: 14, weight: .semibold))
            sessionMenu
            Spacer(minLength: 6)
            Text(model.modelLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(I18N.shared.localized("关闭助手", "Close assistant"))
            .accessibilityLabel(I18N.shared.localized("关闭助手", "Close assistant"))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var sessionMenu: some View {
        Menu {
            Button(I18N.shared.localized("新建对话", "New conversation")) {
                model.newSession()
            }
            if !model.sessions.isEmpty {
                Divider()
                ForEach(model.sessions) { session in
                    Button {
                        model.loadSession(session.id)
                    } label: {
                        if session.id == model.controller.currentSessionID {
                            Label(session.title.isEmpty ? I18N.shared.localized("未命名对话", "Untitled") : session.title, systemImage: "checkmark")
                        } else {
                            Text(session.title.isEmpty ? I18N.shared.localized("未命名对话", "Untitled") : session.title)
                        }
                    }
                }
            }
            if model.controller.currentSessionID != nil {
                Divider()
                Button(I18N.shared.localized("删除当前对话", "Delete conversation"), role: .destructive) {
                    model.deleteCurrentSession()
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(I18N.shared.localized("会话记录", "Conversation history"))
        .accessibilityLabel(I18N.shared.localized("会话记录", "Conversation history"))
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Button {
                showsScopePicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 10))
                    Text(model.scopeSummary)
                        .font(.system(size: 10))
                    Text("\(model.scopeCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.shared.localized("分析范围", "Analysis scope"))
            .popover(isPresented: $showsScopePicker, arrowEdge: .bottom) {
                AgentScopePickerView(
                    current: model.scope,
                    feeds: model.feedOptions,
                    folders: model.folderOptions,
                    count: model.scopeCount,
                    countProvider: { model.previewCount(for: $0) },
                    onCancel: { showsScopePicker = false },
                    onApply: { scope in
                        model.applyScope(scope)
                        showsScopePicker = false
                    }
                )
            }

            Spacer(minLength: 4)

            if model.isDigesting {
                ProgressView()
                    .controlSize(.small)
                Text(model.digestProgressText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(I18N.shared.localized("停止", "Stop")) {
                    model.cancelDigest()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityLabel(I18N.shared.localized("停止分析", "Stop analysis"))
            } else if model.configuration != nil && model.scopeCount > 0 {
                Button {
                    model.analyzeUnread()
                } label: {
                    Label(I18N.shared.localized("分析未读", "Triage"), systemImage: "sparkles")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var proposalPresented: Binding<Bool> {
        Binding(
            get: { model.controller.pendingProposal != nil },
            set: { isPresented in
                if !isPresented { model.rejectPendingProposal() }
            }
        )
    }

    private func undoBar(_ action: AgentAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(PaperTheme.accent)
            Text(AgentL10n.format("已处理 %lld 篇", "%lld articles processed", [action.affectedIDs.count]))
                .font(.system(size: 11))
            Spacer()
            Button(I18N.shared.localized("撤销", "Undo")) {
                model.undoLastAction()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .accessibilityLabel(I18N.shared.localized("撤销上一次标记", "Undo the last change"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PaperTheme.accent.opacity(0.08))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let digest = model.digest {
                        AgentDigestCard(
                            digest: digest,
                            onOpen: onOpenEntry,
                            onMarkRead: { model.proposeRead(item: $0) },
                            onApplySkippable: { model.proposeSkippable() },
                            onRefresh: { model.analyzeUnread(force: true) }
                        )
                    } else if model.isDigesting {
                        digestProgressCard
                    }
                    if let digestError = model.digestError {
                        errorBanner(digestError)
                    }
                    if model.controller.messages.isEmpty && model.controller.streamingText.isEmpty && model.digest == nil && !model.isDigesting {
                        welcome
                    }
                    ForEach(model.controller.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if !model.controller.streamingText.isEmpty {
                        assistantText(model.controller.streamingText)
                    }
                    if let error = model.controller.errorMessage {
                        errorBanner(error)
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: model.controller.streamingText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: model.controller.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear { scrollToBottom(proxy: proxy) }
        }
    }

    private var digestProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(model.digestProgressText)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(I18N.shared.localized(
                "先按标题和摘要快筛，再对最值得读的文章做深读。已完成的条目会先显示。",
                "Screens titles and summaries first, then deep-reads the best articles. Finished items appear as they complete."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18N.shared.localized("从当前未读开始", "Start with your unread articles"))
                .font(.system(size: 14, weight: .semibold))
            Text(I18N.shared.localized(
                "我可以按范围查找、总结和比较文章；标记已读之前一定会先向你确认。",
                "I can search, summarize, and compare articles in scope. Read state only changes after you confirm."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            suggestion(I18N.shared.localized("分析当前未读", "Triage unread"), prompt: "分析当前范围的未读文章，按值得读/可跳过/稍后读分组，并说明理由。")
            suggestion(I18N.shared.localized("今天值得读什么？", "What should I read today?"), prompt: "今天有哪些值得读的文章？先列出最值得读的 5 篇。")
            suggestion(I18N.shared.localized("解释这篇在讲什么", "Explain the current article"), prompt: "用三句话解释当前这篇在讲什么，再列出三个关键点。")
        }
        .padding(.top, 8)
    }

    private func suggestion(_ title: String, prompt: String) -> some View {
        Button {
            model.draft = prompt
            model.send()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func messageRow(_ message: AgentMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.content)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(PaperTheme.warmAccent.opacity(0.14))
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.content.isEmpty {
                    assistantText(message.content)
                }
                ForEach(message.toolCalls, id: \.id) { call in
                    toolCallRow(call)
                }
            }
        case .tool:
            toolResultRow(message.content)
        case .system:
            EmptyView()
        }
    }

    private func assistantText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("AI")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(PaperTheme.warmAccent, in: RoundedRectangle(cornerRadius: 4))
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolCallRow(_ call: AgentToolCall) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(call.name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            Text(call.arguments)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func toolResultRow(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(I18N.shared.localized("工具结果", "Tool result"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PaperTheme.warmAccent)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(PaperTheme.warmAccent.opacity(0.1)))
    }

    private var setupState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18N.shared.localized("先为助手选择一个模型", "Choose a model for the assistant"))
                .font(.system(size: 14, weight: .semibold))
            Text(I18N.shared.localized(
                "助手复用现有的供应商与模型配置，不会单独保存 API Key。",
                "The assistant reuses the existing providers and models and never stores a separate API key."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Button(I18N.shared.localized("打开 AI 设置", "Open AI settings"), action: onOpenSettings)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(I18N.shared.localized("问点什么，或让我分析未读…", "Ask something, or triage unread…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.draft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .accessibilityLabel(I18N.shared.localized("给 AI 助手发消息", "Message the AI assistant"))
                    .frame(minHeight: 44, maxHeight: 100)
                    .padding(4)
            }
            .background(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))

            HStack(spacing: 8) {
                Text(I18N.shared.localized("分析不会自动改已读", "Analysis never marks articles read"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                if model.controller.isStreaming {
                    Button(I18N.shared.localized("停止", "Stop"), action: model.stop)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(Circle().fill(model.canSend ? PaperTheme.warmAccent : Color.secondary.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(I18N.shared.localized("发送（⌘↩）", "Send (⌘↩)"))
                .accessibilityLabel(I18N.shared.localized("发送", "Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("agent-bottom", anchor: .bottom)
        }
    }
}


private struct AgentWriteConfirmationView: View {
    let proposal: AgentWriteProposal
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: (Set<String>) -> Void

    @State private var selected: Set<String>

    init(
        proposal: AgentWriteProposal,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<String>) -> Void
    ) {
        self.proposal = proposal
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selected = State(initialValue: Set(proposal.items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(selected.count) / \(proposal.items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(I18N.shared.localized(
                "只影响以下文章；执行后可在面板顶部撤销。",
                "Only the articles below are affected. You can undo from the panel header."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if !proposal.reason.isEmpty {
                Text(proposal.reason)
                    .font(.system(size: 11))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(proposal.items) { item in
                        HStack(spacing: 9) {
                            Button {
                                if selected.contains(item.id) {
                                    selected.remove(item.id)
                                } else {
                                    selected.insert(item.id)
                                }
                            } label: {
                                Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(selected.contains(item.id) ? PaperTheme.warmAccent : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                Text(item.feedTitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 7)
                        Divider().opacity(0.25)
                    }
                }
            }
            .frame(maxHeight: 280)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.warmAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(I18N.shared.localized("取消", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle) {
                    onConfirm(selected)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var title: String {
        let count = proposal.items.count
        if proposal.kind == .markRead {
            return proposal.desiredValue
                ? AgentL10n.format("确认标记 %lld 篇为已读？", "Mark %lld articles as read?", [count])
                : AgentL10n.format("确认将 %lld 篇标为未读？", "Mark %lld articles as unread?", [count])
        }
        return proposal.desiredValue
            ? AgentL10n.format("确认给 %lld 篇加星标？", "Star %lld articles?", [count])
            : AgentL10n.format("确认取消 %lld 篇的星标？", "Unstar %lld articles?", [count])
    }

    private var confirmTitle: String {
        AgentL10n.format("确认处理 %lld 篇", "Confirm %lld articles", [selected.count])
    }
}

private struct AgentScopePickerView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case all
        case feeds
        case folders
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: I18N.localized("全部", englishFallback: "All")
            case .feeds: I18N.localized("订阅源", englishFallback: "Feeds")
            case .folders: I18N.localized("订阅源组", englishFallback: "Groups")
            }
        }
    }

    enum TimePreset: String, CaseIterable, Identifiable {
        case all
        case today
        case threeDays
        case sevenDays
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: I18N.localized("全部时间", englishFallback: "Any time")
            case .today: I18N.localized("今天", englishFallback: "Today")
            case .threeDays: I18N.localized("近 3 天", englishFallback: "3 days")
            case .sevenDays: I18N.localized("近 7 天", englishFallback: "7 days")
            }
        }
    }

    let feeds: [AgentSourceOption]
    let folders: [AgentSourceOption]
    let count: Int
    let countProvider: (AgentScope) -> Int
    let onCancel: () -> Void
    let onApply: (AgentScope) -> Void

    @State private var mode: Mode
    @State private var timePreset: TimePreset
    @State private var selectedFeeds: Set<String>
    @State private var selectedFolders: Set<String>
    @State private var previewCount: Int

    init(
        current: AgentScope,
        feeds: [AgentSourceOption],
        folders: [AgentSourceOption],
        count: Int,
        countProvider: @escaping (AgentScope) -> Int,
        onCancel: @escaping () -> Void,
        onApply: @escaping (AgentScope) -> Void
    ) {
        self.feeds = feeds
        self.folders = folders
        self.count = count
        self.countProvider = countProvider
        self.onCancel = onCancel
        self.onApply = onApply
        _previewCount = State(initialValue: count)
        switch current.source {
        case .all:
            _mode = State(initialValue: .all)
            _selectedFeeds = State(initialValue: [])
            _selectedFolders = State(initialValue: [])
        case .feeds(let ids):
            _mode = State(initialValue: .feeds)
            _selectedFeeds = State(initialValue: Set(ids))
            _selectedFolders = State(initialValue: [])
        case .folders(let refs):
            _mode = State(initialValue: .folders)
            _selectedFeeds = State(initialValue: [])
            _selectedFolders = State(initialValue: Set(refs.map(\.id)))
        }
        if let from = current.from {
            let start = Calendar.current.startOfDay(for: from)
            let days = Calendar.current.dateComponents([.day], from: start, to: Calendar.current.startOfDay(for: .now)).day ?? 0
            _timePreset = State(initialValue: days <= 0 ? .today : (days <= 2 ? .threeDays : .sevenDays))
        } else {
            _timePreset = State(initialValue: .all)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(I18N.shared.localized("分析范围", "Analysis scope"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .all {
                Text(I18N.shared.localized("所有订阅源。也可以在下方按源或分组缩小范围。", "All feeds. Narrow by feeds or groups below."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if mode == .feeds {
                            ForEach(feeds) { feed in
                                choiceRow(
                                    title: feed.title,
                                    subtitle: AgentL10n.format("%lld 篇未读", "%lld unread", [feed.unreadCount]),
                                    selected: selectedFeeds.contains(feed.id)
                                ) {
                                    toggle(feed.id, in: &selectedFeeds)
                                }
                            }
                        } else {
                            ForEach(folders) { folder in
                                choiceRow(
                                    title: folder.title,
                                    subtitle: AgentL10n.format("%lld 篇未读", "%lld unread", [folder.unreadCount]),
                                    selected: selectedFolders.contains(folder.id)
                                ) {
                                    toggle(folder.id, in: &selectedFolders)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            }

            Picker(I18N.shared.localized("时间", "Time"), selection: $timePreset) {
                ForEach(TimePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)

            Text(AgentL10n.format("预计 %lld 篇未读", "About %lld unread", [previewCount]))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Button(I18N.shared.localized("取消", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(I18N.shared.localized("应用", "Apply")) {
                    onApply(buildScope())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invalidSelection)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: mode) { _, _ in refreshPreview() }
        .onChange(of: selectedFeeds) { _, _ in refreshPreview() }
        .onChange(of: selectedFolders) { _, _ in refreshPreview() }
        .onChange(of: timePreset) { _, _ in refreshPreview() }
    }

    private func refreshPreview() {
        previewCount = countProvider(buildScope())
    }

    private var invalidSelection: Bool {
        switch mode {
        case .all: false
        case .feeds: selectedFeeds.isEmpty
        case .folders: selectedFolders.isEmpty
        }
    }

    private func choiceRow(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? PaperTheme.warmAccent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func buildScope() -> AgentScope {
        let source: AgentSourceScope
        switch mode {
        case .all:
            source = .all
        case .feeds:
            source = .feeds(selectedFeeds.sorted())
        case .folders:
            let refs = folders
                .filter { selectedFolders.contains($0.id) }
                .map { AgentFolderRef(id: $0.id, accountID: $0.accountID, name: $0.folderName ?? $0.title) }
            source = .folders(refs)
        }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let from: Date?
        switch timePreset {
        case .all: from = nil
        case .today: from = startOfToday
        case .threeDays: from = Calendar.current.date(byAdding: .day, value: -2, to: startOfToday)
        case .sevenDays: from = Calendar.current.date(byAdding: .day, value: -6, to: startOfToday)
        }
        return AgentScope(source: source, from: from, unreadOnly: true)
    }
}

private struct AgentDigestCard: View {
    let digest: AgentDigest
    let onOpen: (String) -> Void
    let onMarkRead: (AgentDigestItem) -> Void
    let onApplySkippable: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(I18N.shared.localized("未读分析", "Unread triage"))
                    .font(.system(size: 13, weight: .semibold))
                Text(AgentL10n.format("%lld 篇 → %lld 个主题", "%lld articles → %lld topics", [digest.unreadCount, digest.items.count]))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(I18N.shared.localized("重新分析", "Analyze again"))
            }

            group(.worthReading, color: PaperTheme.accent)
            group(.later, color: .orange)
            group(.skippable, color: .secondary)

            let skippable = digest.items(for: .skippable)
            if !skippable.isEmpty {
                Button {
                    onApplySkippable()
                } label: {
                    HStack {
                        Text(AgentL10n.format("把可跳过的 %lld 篇标已读", "Mark %lld skippable as read", [skippable.count]))
                        Spacer()
                        Image(systemName: "checkmark.circle")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(PaperTheme.warmAccent.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            Text(I18N.shared.localized(
                "分析只给建议；标记已读前会再次确认。",
                "Triage only suggests. Read state changes only after confirmation."
            ))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.05)))
    }

    @ViewBuilder
    private func group(_ verdict: AgentTriageVerdict, color: Color) -> some View {
        let items = digest.items(for: verdict)
        if !items.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(verdict == .worthReading
                     ? I18N.shared.localized("值得读", "Worth reading")
                     : verdict == .later
                        ? I18N.shared.localized("稍后读", "Later")
                        : I18N.shared.localized("可跳过", "Skippable"))
                    .font(.system(size: 10, weight: .semibold))
                Text("\(items.count)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                        if item.clusterSize > 1 {
                            Text(AgentL10n.format("同题 %lld", "%lld same story", [item.clusterSize]))
                                .font(.system(size: 8))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(PaperTheme.warmAccent.opacity(0.12)))
                                .foregroundStyle(PaperTheme.warmAccent)
                        }
                        Spacer(minLength: 2)
                        Menu {
                            Button(I18N.shared.localized("打开", "Open")) { onOpen(item.id) }
                            Button(I18N.shared.localized("标记已读", "Mark read")) { onMarkRead(item) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Text("\(item.feedTitle) · \(item.reason)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    ForEach(item.bullets, id: \.self) { bullet in
                        Text("• \(bullet)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                Divider().opacity(0.2)
            }
        }
    }
}

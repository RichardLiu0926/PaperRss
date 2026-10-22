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

    private let scope = AgentScope.allUnread
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()
    private var undoClearTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
        let database = store.libraryDatabase
        let permission = store.aiSettings.features.agentWritePermission
        let actions = AgentActionRepository(database: database)
        let executor = AgentWriteExecutor(writer: store, actions: actions)
        self.controller = AgentSessionController(
            repository: AgentSessionRepository(database: database),
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
            return
        }
        _ = try? controller.startNewSession(
            scopeJSON: scope.jsonString,
            providerID: store.aiSettings.configuration(for: .agent)?.model?.providerID,
            modelID: store.aiSettings.configuration(for: .agent)?.model?.modelID
        )
    }

    func send() {
        guard canSend, let configuration else { return }
        let providerID = store.aiSettings.configuration(for: .agent)?.model?.providerID ?? ""
        let apiKey = store.apiKey(for: providerID)
        var tools = AgentToolRegistry.readOnlyDefinitions
        let permission = store.aiSettings.features.agentWritePermission
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
            )
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
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
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
            Text(I18N.localizedFormat("已处理 %lld 篇", arguments: [action.affectedIDs.count]))
                .font(.system(size: 11))
            Spacer()
            Button(I18N.shared.localized("撤销", "Undo")) {
                model.undoLastAction()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PaperTheme.accent.opacity(0.08))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.controller.messages.isEmpty && model.controller.streamingText.isEmpty {
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
                ? I18N.localizedFormat("确认标记 %lld 篇为已读？", arguments: [count])
                : I18N.localizedFormat("确认将 %lld 篇标为未读？", arguments: [count])
        }
        return proposal.desiredValue
            ? I18N.localizedFormat("确认给 %lld 篇加星标？", arguments: [count])
            : I18N.localizedFormat("确认取消 %lld 篇的星标？", arguments: [count])
    }

    private var confirmTitle: String {
        I18N.localizedFormat("确认处理 %lld 篇", arguments: [selected.count])
    }
}

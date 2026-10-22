import SwiftUI
import Combine
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@MainActor
final class AgentPanelModel: ObservableObject {
    let store: AppStore
    let controller: AgentSessionController
    @Published var draft = ""

    private let scope = AgentScope.allUnread
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()

    init(store: AppStore) {
        self.store = store
        let database = store.libraryDatabase
        self.controller = AgentSessionController(
            repository: AgentSessionRepository(database: database),
            llm: LLMService(),
            toolRegistry: AgentToolRegistry(database: database)
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
        controller.send(
            draft,
            configuration: configuration,
            apiKey: apiKey,
            toolContext: AgentToolContext(
                accountID: store.activeAccountID,
                scope: scope,
                sessionID: controller.currentSessionID
            )
        )
        draft = ""
    }

    func stop() {
        controller.cancel()
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
            if model.configuration == nil {
                setupState
            } else {
                transcript
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

import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct AgentActionHistoryView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [AgentAction] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18N.shared.localized("助手操作记录", "Assistant activity"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(I18N.shared.localized(
                        "只保存在本机；最近 24 小时内可撤销。",
                        "Stored locally only; undo is available for 24 hours."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(I18N.shared.localized("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if actions.isEmpty {
                Text(I18N.shared.localized("还没有操作记录。", "No activity yet."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(actions) { action in
                            row(action)
                            Divider().opacity(0.25)
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 380)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(PaperTheme.warmAccent)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear(perform: reload)
    }

    private func row(_ action: AgentAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.status == .undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .foregroundStyle(action.status == .undone ? Color.secondary : PaperTheme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: action))
                    .font(.system(size: 12, weight: .medium))
                Text(formattedDate(action.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if action.status == .executed, canUndo(action) {
                Button(I18N.shared.localized("撤销", "Undo")) {
                    undo(action)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
            } else {
                Text(action.status == .undone
                     ? I18N.shared.localized("已撤销", "Undone")
                     : I18N.shared.localized("已过期", "Expired"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func title(for action: AgentAction) -> String {
        let verb: String
        switch action.tool {
        case AgentWriteKind.markRead.toolName:
            verb = I18N.shared.localized("标记已读", "Marked read")
        case AgentWriteKind.markStarred.toolName:
            verb = I18N.shared.localized("加星标", "Starred")
        default:
            verb = action.tool
        }
        return "\(verb) · \(action.affectedIDs.count) 篇"
    }

    private func canUndo(_ action: AgentAction) -> Bool {
        Date().timeIntervalSince1970 - action.createdAt <= 24 * 3600
    }

    private func reload() {
        do {
            actions = try store.agentActionRepository.fetchRecent(limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undo(_ action: AgentAction) {
        do {
            let executor = AgentWriteExecutor(writer: store, actions: store.agentActionRepository)
            try executor.undo(action: action)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formattedDate(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

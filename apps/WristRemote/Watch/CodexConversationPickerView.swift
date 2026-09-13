import SwiftUI

struct CodexConversationPickerView: View {
    @ObservedObject var controller: WatchSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var requestedTarget: WatchCodexConversationTarget?
    @State private var newConversationCandidate: WatchCodexConversationEntry?

    var body: some View {
        List {
            if let catalog = controller.codexConversationCatalog {
                if let pickerStatusText {
                    Section("状态") {
                        Label(
                            pickerStatusText,
                            systemImage: controller.pendingCodexConversationTarget == nil
                                ? "info.circle"
                                : "ellipsis.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("会话选择状态：\(pickerStatusText)")

                        if controller.pendingCodexConversationTarget != nil {
                            Button("停止等待") {
                                requestedTarget = nil
                                controller.stopWaitingForCodexConversationTarget()
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityHint(
                                "解除手表上的等待锁定；不会谎称撤回 Mac 已收到的请求"
                            )
                        }
                    }
                }

                Section("新建会话") {
                    if !newConversationEntries.contains(where: { $0.target.isStandaloneNewConversation }) {
                        Text("空白任务暂不可用，请更新或检查 Mac 桥接")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(newConversationEntries.filter { $0.target.isStandaloneNewConversation }) { entry in
                            newConversationButton(entry)
                        }
                    }
                }

                let projectEntries = newConversationEntries.filter { !$0.target.isStandaloneNewConversation }
                if !projectEntries.isEmpty {
                    Section("在项目中新建") {
                        ForEach(projectEntries) { entry in
                            newConversationButton(entry)
                        }
                    }
                }

                if let selected = controller.selectedCodexTarget {
                    Section("已选") {
                        SelectedCodexTargetRow(target: selected)
                    }
                }

                Section("最近") {
                    if recentEntries.isEmpty {
                        Text("还没有最近会话")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentEntries) { entry in
                            conversationButton(entry)
                        }
                    }

                    if catalog.hasMore {
                        Text("显示 Mac 返回的最近 12 个；更早会话请先在 Mac 打开后刷新")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !controller.isCodexConversationRouteReady {
                Section("无法同步") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.codexConversationRouteStatusDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("重新连接") {
                            controller.requestStatus()
                            controller.requestCodexConversationCatalog()
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    .accessibilityElement(children: .contain)
                }
            } else if controller.isCodexConversationCatalogLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.wristRemoteAccent)
                        Text("正在同步会话…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Section("会话不可用") {
                    Text(unavailableStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新同步") {
                        controller.requestCodexConversationCatalog()
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .tint(.wristRemoteAccent)
        .navigationTitle("选择会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    WatchHaptics.play(.click)
                    stopWaitingIfNeeded()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("关闭会话选择")
                .accessibilityHint("返回首屏并停止等待选择结果；已交给 Mac 的新建请求可能已完成")
                .accessibilityIdentifier("codex-conversation-picker-close")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.requestCodexConversationCatalog()
                } label: {
                    if controller.isCodexConversationCatalogLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(controller.isCodexConversationCatalogLoading)
                .accessibilityLabel("刷新会话")
                .accessibilityHint("从 Mac 重新同步可用会话")
            }
        }
        .refreshable {
            controller.requestCodexConversationCatalog()
            while controller.isCodexConversationCatalogLoading, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .task {
            controller.requestCodexConversationCatalog()
        }
        .onDisappear(perform: stopWaitingIfNeeded)
        .alert(item: $newConversationCandidate) { entry in
            Alert(
                title: Text(entry.target.isStandaloneNewConversation ? "新建空白任务？" : "在项目中新建？"),
                message: Text(
                    entry.target.isStandaloneNewConversation
                        ? "使用独立空目录，不带旧会话消息或旧项目文件。沿用 Codex 全局设置。"
                        : "在 \(entry.workspaceLabel) 新建会话。没有旧聊天记录，但仍使用该项目的文件与规则。"
                ),
                primaryButton: .default(Text("新建并选择")) {
                    beginSelection(entry)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onChange(of: controller.selectedCodexTarget) { _, selected in
            guard let requestedTarget,
                  let selected,
                  WatchCodexConversationSelectionResolution.isSafeReplacement(
                      requested: requestedTarget,
                      selected: selected,
                      nowEpochMilliseconds: now
                  )
            else { return }
            self.requestedTarget = nil
            dismiss()
        }
    }

    private var newConversationEntries: [WatchCodexConversationEntry] {
        controller.codexConversationCatalog?.entries.filter { entry in
            entry.target.kind == .newConversation
        } ?? []
    }

    private func stopWaitingIfNeeded() {
        guard requestedTarget != nil else { return }
        requestedTarget = nil
        controller.stopWaitingForCodexConversationTarget()
    }

    private var recentEntries: [WatchCodexConversationEntry] {
        controller.codexConversationCatalog?.entries.filter { entry in
            entry.target.kind == .existing
                && !isSelected(entry.target)
        } ?? []
    }

    @ViewBuilder
    private func newConversationButton(_ entry: WatchCodexConversationEntry) -> some View {
        Button {
            WatchHaptics.play(.click)
            newConversationCandidate = entry
        } label: {
            CodexConversationRow(
                entry: entry,
                isSelected: false,
                isPending: controller.pendingCodexConversationTarget == entry.target
            )
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .disabled(
            controller.pendingCodexConversationTarget != nil
                || !entry.canAcceptInput
                || entry.target.isExpired(atEpochMilliseconds: now)
        )
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityValue(accessibilityValue(for: entry))
        .accessibilityIdentifier(entry.target.isStandaloneNewConversation
            ? "codex-new-blank-task" : "codex-new-project-task")
        .accessibilityHint(entry.target.isStandaloneNewConversation
            ? "创建独立空目录和空白会话，不带入旧项目或旧聊天"
            : "创建空白会话，但继续使用所选项目的文件与规则")
    }

    @ViewBuilder
    private func conversationButton(_ entry: WatchCodexConversationEntry) -> some View {
        Button {
            if isSelected(entry.target) {
                dismiss()
                return
            }
            beginSelection(entry)
        } label: {
            CodexConversationRow(
                entry: entry,
                isSelected: isSelected(entry.target),
                isPending: controller.pendingCodexConversationTarget == entry.target
            )
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .disabled(
            controller.pendingCodexConversationTarget != nil
                || !entry.canAcceptInput
                || entry.target.isExpired(atEpochMilliseconds: now)
        )
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityValue(accessibilityValue(for: entry))
        .accessibilityHint(
            accessibilityHint(for: entry)
        )
    }

    private var now: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private var unavailableStatusText: String {
        controller.codexVoiceStatusText ?? "Mac 暂时没有返回会话目录"
    }

    private var pickerStatusText: String? {
        if let pending = controller.pendingCodexConversationTarget {
            return "正在确认：\(pending.displayTitle)。关闭会停止等待；新建请求可能已在 Mac 完成，可刷新找回。"
        }
        guard let status = controller.codexVoiceStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty
        else { return nil }
        return status
    }

    private func isSelected(_ target: WatchCodexConversationTarget) -> Bool {
        guard let selected = controller.selectedCodexTarget else { return false }
        if selected.leaseID == target.leaseID { return true }
        guard selected.serverEpoch == target.serverEpoch,
              selected.kind == target.kind
        else { return false }
        switch target.kind {
        case .existing:
            return selected.threadID == target.threadID
        case .newConversation:
            return selected.workspaceID == target.workspaceID
        }
    }

    private func accessibilityLabel(for entry: WatchCodexConversationEntry) -> String {
        if entry.target.isStandaloneNewConversation { return "完全空白任务" }
        return entry.target.kind == .newConversation
            ? "在项目中新建，\(entry.workspaceLabel)" : entry.title
    }

    private func accessibilityValue(for entry: WatchCodexConversationEntry) -> String {
        var values = [entry.workspaceLabel, entry.state.accessibilityTitle]
        if isSelected(entry.target) { values.append("已选") }
        if !entry.canAcceptInput { values.append("当前不可输入") }
        return values.joined(separator: "，")
    }

    private func accessibilityHint(for entry: WatchCodexConversationEntry) -> String {
        if entry.target.isExpired(atEpochMilliseconds: now) {
            return "目标已过期，请刷新会话"
        }
        return entry.canAcceptInput ? "选择为语音发送目标" : "此会话当前不能接收输入"
    }

    private func beginSelection(_ entry: WatchCodexConversationEntry) {
        guard controller.pendingCodexConversationTarget == nil else { return }
        WatchHaptics.play(.click)
        requestedTarget = entry.target
        controller.selectCodexConversationTarget(entry.target)
    }
}

private struct SelectedCodexTargetRow: View {
    let target: WatchCodexConversationTarget

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.wristRemoteAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayTitle)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codex-selected-full-title")
                Text(target.workspaceLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已选目标：\(target.displayTitle)，\(target.workspaceLabel)")
        .accessibilityIdentifier("codex-selected-target-summary")
    }
}

private struct CodexConversationRow: View {
    let entry: WatchCodexConversationEntry
    let isSelected: Bool
    let isPending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.target.kind == .newConversation ? "plus.bubble" : "text.bubble")
                .foregroundStyle(
                    entry.canAcceptInput ? Color.wristRemoteAccent : Color.secondary
                )
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.target.kind == .newConversation
                    ? (entry.target.isStandaloneNewConversation ? "全新空白任务" : "新建项目会话")
                    : entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.target.isStandaloneNewConversation {
                    Text(entry.workspaceLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if entry.target.kind == .newConversation {
                    Text(entry.target.isStandaloneNewConversation
                        ? "不带旧项目与对话" : "沿用项目，不带旧对话")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        CodexConversationStateLabel(state: entry.state)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(updatedDate, style: .relative)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 2)
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.wristRemoteAccent)
                    .accessibilityLabel("正在向 Mac 确认")
            } else if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.wristRemoteAccent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var updatedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(entry.updatedAtEpochMilliseconds) / 1_000)
    }

}

private struct CodexConversationStateLabel: View {
    let state: WatchCodexConversationState

    var body: some View {
        Label(state.accessibilityTitle, systemImage: state.systemImage)
            .font(.footnote)
            .foregroundStyle(
                state == .running ? Color.wristRemoteAccent : Color.secondary
            )
            .labelStyle(.titleAndIcon)
    }
}

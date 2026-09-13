import SwiftUI

/// Codex-first Watch home. Conversation selection and reply confirmation stay
/// separate from the existing remote deck so neither interaction can trigger
/// the other subsystem.
struct WatchCodexConversationHomeView: View {
    @ObservedObject var controller: WatchSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsVoiceStatus = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CodexDestinationSection(controller: controller)

                Divider()

                CodexCurrentTaskSection(
                    controller: controller,
                    task: controller.codexTaskSnapshot,
                    selectedTarget: controller.selectedCodexTarget
                )

                Button {
                    showsVoiceStatus = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("语音状态", systemImage: "info.circle")
                            .font(.callout)
                        if let status = controller.codexVoiceStatusText {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codex-voice-status-entry")
                .accessibilityLabel("语音状态")
                .accessibilityValue(controller.codexVoiceStatusText ?? "尚未开始录音")
                .accessibilityHint("查看完整状态和操作说明")

                if !controller.isCodexConversationRouteReady {
                    CodexConnectionIssueRow(controller: controller)
                }

                if let draft = controller.codexConversationDraft {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        CodexConversationDraftView(
                            text: draft.text,
                            target: draft.target,
                            statusText: controller.codexVoiceStatusText,
                            isSubmitting: controller.isCodexReplySubmitting,
                            isExpired: draft.isExpired(
                                atEpochMilliseconds: Int64(
                                    context.date.timeIntervalSince1970 * 1_000
                                )
                            ),
                            submit: controller.submitCodexConversationDraft,
                            discard: controller.discardCodexConversationDraft
                        )
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .alert("语音状态", isPresented: $showsVoiceStatus) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(controller.codexVoiceStatusText ?? "先选择目标，按住到震动后说话。松开发送，移开取消。")
        }
        .tint(.wristRemoteAccent)
        .safeAreaInset(edge: .bottom, spacing: 2) {
            if controller.codexConversationDraft == nil {
                CodexConversationVoiceButton(controller: controller)
                    .padding(.horizontal, 8)
                    .background(Color.black)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RemoteDeckView(controller: controller)
                } label: {
                    Image(systemName: "appletvremote.gen1.fill")
                        .foregroundStyle(.black)
                }
                .accessibilityLabel("遥控器")
                .accessibilityIdentifier("remote-deck-entry")
                .accessibilityHint("打开方向、功能与收藏按键")
                .disabled(controller.isCodexVoiceInteractionInProgress)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: controller.codexConversationDraft?.draftID
        )
        .task {
            controller.requestCodexConversationCatalog()
        }
    }
}

private struct CodexConnectionIssueRow: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        Button {
            controller.requestStatus()
            controller.requestCodexConversationCatalog()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text(controller.codexConversationRouteStatusText)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Codex 连接异常：\(controller.codexConversationRouteStatusText)")
        .accessibilityValue(controller.codexConversationRouteStatusDetail)
        .accessibilityHint("轻点重新连接并刷新会话")
    }
}

private struct CodexDestinationSection: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink {
                CodexConversationPickerView(controller: controller)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("发送到 · \(destinationDetail)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(Color.wristRemoteAccent)
                    }

                    Text(controller.selectedCodexTarget?.displayTitle ?? "选择会话")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("codex-destination-title")
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.canChangeCodexDestination)
            .accessibilityLabel("发送到")
            .accessibilityIdentifier("codex-destination-entry")
            .accessibilityValue(accessibilityDestinationValue)
            .accessibilityHint("查看已选目标的完整名称，或选择新建和最近会话")
        }
    }

    private var destinationDetail: String {
        guard let target = controller.selectedCodexTarget else {
            return "尚未选择"
        }
        return target.workspaceLabel
    }

    private var accessibilityDestinationValue: String {
        guard let target = controller.selectedCodexTarget else { return "尚未选择" }
        let kind = target.kind == .newConversation ? "新建会话" : "现有会话"
        return "\(kind)，\(target.displayTitle)，\(target.workspaceLabel)"
    }
}

private struct CodexCurrentTaskSection: View {
    @ObservedObject var controller: WatchSessionController
    let task: WatchCodexTaskSnapshot?
    let selectedTarget: WatchCodexConversationTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sectionTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            if let task {
                NavigationLink {
                    WatchCodexTaskDetailView(controller: controller, initialTask: task)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        CodexTaskStateIcon(state: task.state)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(taskSummary(task))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            if taskIsOutsideSelectedDestination {
                                Label("不会发送到这个任务", systemImage: "arrow.turn.down.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前任务：\(task.title)")
                .accessibilityValue("\(task.state.accessibilityTitle)，\(taskSummary(task))")
                .accessibilityHint("打开任务完整摘要")
            } else {
                Text("选择会话后即可开始")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("当前没有正在同步的 Codex 任务")
            }
        }
    }

    private var sectionTitle: String {
        guard let task, let selectedTarget else { return "当前任务" }
        return selectedTarget.kind == .existing && selectedTarget.threadID == task.threadID
            ? "所选会话任务"
            : "其他会话任务"
    }

    private var taskIsOutsideSelectedDestination: Bool {
        guard let task, let selectedTarget else { return false }
        return selectedTarget.kind != .existing || selectedTarget.threadID != task.threadID
    }

    private func taskSummary(_ task: WatchCodexTaskSnapshot) -> String {
        let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, !summary.isEmpty { return summary }
        switch task.state {
        case .running: return "正在执行，完成后会同步摘要。"
        case .completed: return "任务已完成，摘要正在同步。"
        case .failed: return "任务未完成，请在 Mac 上查看详情。"
        }
    }
}

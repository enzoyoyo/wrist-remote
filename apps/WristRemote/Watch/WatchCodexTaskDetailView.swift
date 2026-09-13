import SwiftUI

struct WatchCodexTaskDetailView: View {
    @ObservedObject var controller: WatchSessionController
    let initialTask: WatchCodexTaskSnapshot

    private var task: WatchCodexTaskSnapshot {
        guard let current = controller.codexTaskSnapshot,
              current.threadID == initialTask.threadID else { return initialTask }
        return current
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    CodexTaskStateIcon(state: task.state)
                    Text(task.state.accessibilityTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(
                            task.state == .running ? Color.wristRemoteAccent : Color.secondary
                        )
                    Spacer(minLength: 4)
                    Text(updatedDate, style: .relative)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("摘要")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fullSummary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
    }

    private var updatedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(task.updatedAtEpochMilliseconds) / 1_000)
    }

    private var fullSummary: String {
        let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, !summary.isEmpty { return summary }
        switch task.state {
        case .running: return "任务正在执行，完成后会同步结果摘要。"
        case .completed: return "任务已完成，结果摘要正在同步。"
        case .failed: return "任务未完成，请在 Mac 上查看完整错误信息。"
        }
    }
}

struct CodexTaskStateIcon: View {
    let state: WatchCodexTaskState

    var body: some View {
        Group {
            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .tint(.wristRemoteAccent)
            } else {
                Image(systemName: state == .completed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(
                        state == .completed ? Color.wristRemoteAccent : Color.secondary
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

extension WatchCodexTaskState {
    var accessibilityTitle: String {
        switch self {
        case .running: return "执行中"
        case .completed: return "已完成"
        case .failed: return "未完成"
        }
    }
}

extension WatchCodexConversationState {
    var accessibilityTitle: String {
        switch self {
        case .running: return "执行中"
        case .idle: return "可输入"
        case .unavailable: return "暂不可用"
        }
    }

    var systemImage: String {
        switch self {
        case .running: return "circle.dotted"
        case .idle: return "circle.fill"
        case .unavailable: return "pause.circle"
        }
    }
}

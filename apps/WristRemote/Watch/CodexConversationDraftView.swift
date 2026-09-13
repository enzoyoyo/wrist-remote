import SwiftUI

struct CodexConversationDraftView: View {
    let text: String
    let target: WatchCodexConversationTarget
    let statusText: String?
    let isSubmitting: Bool
    let isExpired: Bool
    let submit: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("发送前确认")
                    .font(.headline)

                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.displayTitle)
                            .font(.footnote.weight(.semibold))
                        Text(target.workspaceLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color.wristRemoteAccent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "草稿已锁定发送到 \(target.displayTitle)，\(target.workspaceLabel)"
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.body)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("语音草稿：\(text)")

                if showsFullDraftLink {
                    NavigationLink {
                        CodexDraftTextDetailView(text: text, target: target)
                    } label: {
                        Label("查看完整草稿", systemImage: "doc.text.magnifyingglass")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开全文阅读，不会发送")
                }
            }

            if isExpired {
                Label("授权已过期，为防错发请重新录音", systemImage: "exclamationmark.shield.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("草稿授权已过期，不能发送，请重新录音")
            } else if isSubmitting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.wristRemoteAccent)
                    Text("正在发送到已选会话…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let visibleStatus {
                Text(visibleStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("发送状态：\(visibleStatus)")
            }

            if isExpired {
                Button(action: discard) {
                    Label("重新录音", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wristRemoteAccent)
                .foregroundStyle(.black)
                .accessibilityHint("删除过期草稿，保留当前会话选择")
            } else {
                HStack(spacing: 8) {
                    Button(action: discard) {
                        Text("重说")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                    .accessibilityHint("删除这份草稿，目标会话保持不变")

                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Label("发送", systemImage: "arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.wristRemoteAccent)
                    .foregroundStyle(.black)
                    .disabled(isSubmitting)
                    .accessibilityLabel(isSubmitting ? "正在发送" : "发送草稿")
                    .accessibilityHint("发送到上方锁定的目标会话")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibleStatus: String? {
        let normalized = statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private var showsFullDraftLink: Bool {
        text.count > 90 || text.filter(\.isNewline).count >= 3
    }
}

private struct CodexDraftTextDetailView: View {
    let text: String
    let target: WatchCodexConversationTarget

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(target.displayTitle, systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.wristRemoteAccent)

                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .navigationTitle("语音草稿")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
    }
}

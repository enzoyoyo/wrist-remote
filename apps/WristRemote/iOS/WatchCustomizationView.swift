import SwiftUI

struct WatchCustomizationView: View {
    @ObservedObject var settings: WatchLayoutSettings
    @ObservedObject var profileStore: WatchActionProfileStore
    @ObservedObject var connection: WristBridgeConnection
    @ObservedObject var relay: WatchRelayController

    @State private var pendingReset: ResetTarget?

    private enum ResetTarget: String, Identifiable {
        case favorites
        case mappings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .favorites: return "恢复默认收藏？"
            case .mappings: return "恢复默认独立映射？"
            }
        }

        var message: String {
            switch self {
            case .favorites:
                return "仅恢复 Apple Watch 的四个收藏位置，不会改动其他输入设备。"
            case .mappings:
                return "仅恢复 Apple Watch 的单击、双击和长按动作，不会改动其他输入设备。"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("互联网遥控")
                        Text(relay.internetRelayStatusDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: relay.isInternetProfileReady
                        ? "checkmark.circle.fill"
                        : "circle")
                        .foregroundStyle(
                            relay.isInternetProfileReady ? Color.accentColor : Color.secondary
                        )
                        .accessibilityLabel(
                            relay.isInternetProfileReady ? "公网映射已就绪" : "公网映射未就绪"
                        )
                }
                .frame(minHeight: 44)
            } header: {
                Text("同步状态")
            } footer: {
                Text("同一局域网内优先使用本地连接；离开局域网后才使用加密互联网通道。")
            }

            Section {
                ForEach(0..<WatchLayoutSettings.favoriteCount, id: \.self) { index in
                    NavigationLink {
                        WatchFavoriteSelectionView(
                            index: index,
                            settings: settings
                        )
                    } label: {
                        SettingsSelectionRow(
                            title: "快捷键 \(index + 1)",
                            value: settings.favorites[index].displayTitle,
                            systemImage: settings.favorites[index].systemImage
                        )
                    }
                }
            } header: {
                Text("Apple Watch 收藏键")
            } footer: {
                Text("四个位置保持唯一。选择已使用的按键时，两个位置会自动互换。")
            }

            Section {
                ForEach(WatchRemoteCommand.allCases) { command in
                    NavigationLink {
                        WatchButtonCustomizationView(
                            command: command,
                            profileStore: profileStore,
                            connection: connection
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.displayTitle)
                                Text(profileStore.title(
                                    for: command,
                                    applicationTitles: connection.watchApplicationTitles
                                ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: command.systemImage)
                        }
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("独立按键映射")
            } footer: {
                Text("每个按键可分别设置单击、双击和长按。此配置只属于腕上遥控。")
            }

            Section("恢复默认") {
                Button("恢复默认收藏", role: .destructive) {
                    pendingReset = .favorites
                }
                .frame(minHeight: 44)

                Button("恢复默认独立映射", role: .destructive) {
                    pendingReset = .mappings
                }
                .frame(minHeight: 44)
            }

            Section {
                Text("布局与独立映射会自动同步。只有 Mac 确认当前映射版本后，手表按键才会发送；不会回退到其他设备的映射。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("自定义按键")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $pendingReset) { target in
            Alert(
                title: Text(target.title),
                message: Text(target.message),
                primaryButton: .destructive(Text("确认恢复")) {
                    switch target {
                    case .favorites: settings.reset()
                    case .mappings: profileStore.reset()
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
}

private struct WatchFavoriteSelectionView: View {
    let index: Int
    @ObservedObject var settings: WatchLayoutSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(WatchRemoteCommand.allCases) { command in
            Button {
                settings.setFavorite(command, at: index)
                dismiss()
            } label: {
                SettingsChoiceRow(
                    title: command.displayTitle,
                    systemImage: command.systemImage,
                    isSelected: settings.favorites[index] == command
                )
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("快捷键 \(index + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchButtonCustomizationView: View {
    let command: WatchRemoteCommand
    @ObservedObject var profileStore: WatchActionProfileStore
    @ObservedObject var connection: WristBridgeConnection

    var body: some View {
        Form {
            ForEach(WatchActionTrigger.allCases) { trigger in
                Section(trigger.displayTitle) {
                    NavigationLink {
                        WatchActionSelectionView(
                            command: command,
                            trigger: trigger,
                            profileStore: profileStore,
                            connection: connection
                        )
                    } label: {
                        SettingsSelectionRow(
                            title: "动作",
                            value: binding(for: trigger).action.displayTitle,
                            systemImage: "bolt"
                        )
                    }

                    if binding(for: trigger).action == .customShortcut {
                        NavigationLink {
                            WatchShortcutEditorView(
                                command: command,
                                trigger: trigger,
                                profileStore: profileStore
                            )
                        } label: {
                            SettingsSelectionRow(
                                title: "快捷键",
                                value: binding(for: trigger).shortcut?.displayTitle ?? "未设置",
                                systemImage: "keyboard"
                            )
                        }
                    }

                    if binding(for: trigger).action == .openCustomApplication {
                        if sortedApplicationTitles.isEmpty {
                            Text("请先连接 Mac，并在腕上遥控桥中添加自定义 App。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44, alignment: .leading)
                        } else {
                            NavigationLink {
                                WatchApplicationSelectionView(
                                    command: command,
                                    trigger: trigger,
                                    profileStore: profileStore,
                                    applicationTitles: connection.watchApplicationTitles
                                )
                            } label: {
                                SettingsSelectionRow(
                                    title: "Mac App",
                                    value: selectedApplicationTitle(for: trigger),
                                    systemImage: "app"
                                )
                            }
                        }
                    }
                }
            }

            Section {
                Text("这些动作只在 Apple Watch 上使用，不会读取或改写其他设备的按键设置。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(command.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for trigger: WatchActionTrigger) -> WatchActionBindingWire {
        profileStore.binding(for: command, trigger: trigger)
    }

    private func selectedApplicationTitle(for trigger: WatchActionTrigger) -> String {
        guard let profileID = binding(for: trigger).applicationProfileID else {
            return "未设置"
        }
        return connection.watchApplicationTitles[profileID] ?? "不可用的 App"
    }

    private var sortedApplicationTitles: [(key: String, value: String)] {
        connection.watchApplicationTitles.sorted {
            $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }
}

private struct WatchActionSelectionView: View {
    let command: WatchRemoteCommand
    let trigger: WatchActionTrigger
    @ObservedObject var profileStore: WatchActionProfileStore
    @ObservedObject var connection: WristBridgeConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(WatchActionCategory.allCases) { category in
                Section(category.displayTitle) {
                    ForEach(actions(in: category), id: \.self) { action in
                        Button {
                            profileStore.setAction(
                                action,
                                for: command,
                                trigger: trigger,
                                defaultApplicationProfileID: sortedApplicationTitles.first?.key
                            )
                            dismiss()
                        } label: {
                            SettingsChoiceRow(
                                title: action.displayTitle,
                                systemImage: nil,
                                isSelected: currentAction == action
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            action == .openCustomApplication
                                && connection.watchApplicationTitles.isEmpty
                        )
                    }
                }
            }

            if connection.watchApplicationTitles.isEmpty {
                Section {
                    Text("连接 Mac 并添加自定义 App 后，才可选择“打开自定义 App”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(trigger.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentAction: WatchActionKindWire {
        profileStore.binding(for: command, trigger: trigger).action
    }

    private func actions(in category: WatchActionCategory) -> [WatchActionKindWire] {
        WatchActionKindWire.wristRemoteBridgeActions.filter { $0.category == category }
    }

    private var sortedApplicationTitles: [(key: String, value: String)] {
        connection.watchApplicationTitles.sorted {
            $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }
}

private struct WatchApplicationSelectionView: View {
    let command: WatchRemoteCommand
    let trigger: WatchActionTrigger
    @ObservedObject var profileStore: WatchActionProfileStore
    let applicationTitles: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(sortedApplicationTitles, id: \.key) { item in
                Button {
                    profileStore.setApplicationProfileID(
                        item.key,
                        for: command,
                        trigger: trigger
                    )
                    dismiss()
                } label: {
                    SettingsChoiceRow(
                        title: item.value,
                        systemImage: "app",
                        isSelected: selectedProfileID == item.key
                    )
                }
                .buttonStyle(.plain)
            }

            if let selectedProfileID,
               applicationTitles[selectedProfileID] == nil {
                SettingsChoiceRow(
                    title: "不可用的 App",
                    systemImage: "exclamationmark.triangle",
                    isSelected: true
                )
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("选择 Mac App")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedProfileID: String? {
        profileStore.binding(for: command, trigger: trigger).applicationProfileID
    }

    private var sortedApplicationTitles: [(key: String, value: String)] {
        applicationTitles.sorted {
            $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }
}

private struct WatchShortcutEditorView: View {
    let command: WatchRemoteCommand
    let trigger: WatchActionTrigger
    @ObservedObject var profileStore: WatchActionProfileStore

    var body: some View {
        Form {
            Section("按键") {
                NavigationLink {
                    WatchShortcutKeySelectionView(
                        command: command,
                        trigger: trigger,
                        profileStore: profileStore
                    )
                } label: {
                    SettingsSelectionRow(
                        title: "键",
                        value: currentShortcut.keyLabel,
                        systemImage: "keyboard"
                    )
                }
            }

            Section("修饰键") {
                ForEach(WatchShortcutModifier.allCases) { modifier in
                    Toggle(modifier.displayTitle, isOn: modifierBinding(modifier))
                        .frame(minHeight: 44)
                }
            }

            Section {
                LabeledContent("结果", value: currentShortcut.displayTitle)
            }
        }
        .navigationTitle("自定义快捷键")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentShortcut: WatchShortcutWire {
        profileStore.binding(for: command, trigger: trigger).shortcut
            ?? WatchShortcutKeyOption.returnKey.shortcut
    }

    private func modifierBinding(_ modifier: WatchShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { currentShortcut.modifierFlagsRawValue & modifier.rawValue != 0 },
            set: { isEnabled in
                var flags = currentShortcut.modifierFlagsRawValue
                if isEnabled {
                    flags |= modifier.rawValue
                } else {
                    flags &= ~modifier.rawValue
                }
                profileStore.setShortcut(
                    WatchShortcutWire(
                        keyCode: currentShortcut.keyCode,
                        modifierFlagsRawValue: flags,
                        keyLabel: currentShortcut.keyLabel
                    ),
                    for: command,
                    trigger: trigger
                )
            }
        )
    }
}

private struct WatchShortcutKeySelectionView: View {
    let command: WatchRemoteCommand
    let trigger: WatchActionTrigger
    @ObservedObject var profileStore: WatchActionProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(keyOptions) { option in
            Button {
                profileStore.setShortcut(
                    WatchShortcutWire(
                        keyCode: option.keyCode,
                        modifierFlagsRawValue: currentShortcut.modifierFlagsRawValue,
                        keyLabel: option.label
                    ),
                    for: command,
                    trigger: trigger
                )
                dismiss()
            } label: {
                SettingsChoiceRow(
                    title: option.label,
                    systemImage: nil,
                    isSelected: option.keyCode == currentShortcut.keyCode
                )
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("选择按键")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentShortcut: WatchShortcutWire {
        profileStore.binding(for: command, trigger: trigger).shortcut
            ?? WatchShortcutKeyOption.returnKey.shortcut
    }

    private var keyOptions: [WatchShortcutKeyOption] {
        if WatchShortcutKeyOption.all.contains(where: { $0.keyCode == currentShortcut.keyCode }) {
            return WatchShortcutKeyOption.all
        }
        return [
            WatchShortcutKeyOption(
                keyCode: currentShortcut.keyCode,
                label: currentShortcut.keyLabel
            )
        ] + WatchShortcutKeyOption.all
    }
}

private struct SettingsSelectionRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct SettingsChoiceRow: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 24)
            }
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension WatchRemoteCommand {
    var displayTitle: String {
        switch self {
        case .power: return "电源"
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        case .ok: return "确认"
        case .back: return "返回"
        case .home: return "主页"
        case .menu: return "菜单"
        case .tv: return "TV"
        case .volumeUp: return "音量加"
        case .volumeDown: return "音量减"
        }
    }

    var systemImage: String {
        switch self {
        case .power: return "power"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .ok: return "checkmark"
        case .back: return "arrow.uturn.backward"
        case .home: return "house"
        case .menu: return "line.3.horizontal"
        case .tv: return "tv"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        }
    }
}

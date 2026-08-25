import Combine
import Foundation

enum WatchActionTrigger: String, CaseIterable, Identifiable {
    case singleClick
    case doubleClick
    case longPress

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .singleClick: return "单击"
        case .doubleClick: return "双击"
        case .longPress: return "长按"
        }
    }
}

@MainActor
final class WatchActionProfileStore: ObservableObject {
    static let formatVersion = 1
    static let storageKey = "WristRemote.watchActionProfile.v1"

    @Published private(set) var profile: WatchActionProfileWire

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(WatchActionProfileWire.self, from: data),
           let normalized = try? Self.sanitizedForWristRemote(decoded).validatedAndNormalized() {
            profile = normalized
            if profile != decoded { persist() }
        } else {
            profile = Self.defaultProfile()
            persist()
        }
    }

    var revision: Int { profile.revision }

    func binding(
        for command: WatchRemoteCommand,
        trigger: WatchActionTrigger
    ) -> WatchActionBindingWire {
        profile.bindings[command.wireButtonID]?[trigger.rawValue]
            ?? WatchActionBindingWire(action: .disabled)
    }

    func setAction(
        _ action: WatchActionKindWire,
        for command: WatchRemoteCommand,
        trigger: WatchActionTrigger,
        defaultApplicationProfileID: String? = nil
    ) {
        var binding = self.binding(for: command, trigger: trigger)
        guard binding.action != action
                || (action == .openCustomApplication
                    && binding.applicationProfileID != defaultApplicationProfileID)
        else { return }

        switch action {
        case .customShortcut:
            binding = WatchActionBindingWire(
                action: action,
                shortcut: binding.shortcut ?? WatchShortcutKeyOption.returnKey.shortcut
            )
        case .openCustomApplication:
            guard let defaultApplicationProfileID,
                  UUID(uuidString: defaultApplicationProfileID) != nil
            else { return }
            binding = WatchActionBindingWire(
                action: action,
                applicationProfileID: UUID(uuidString: defaultApplicationProfileID)?.uuidString
            )
        default:
            binding = WatchActionBindingWire(action: action)
        }
        update(binding, for: command, trigger: trigger)
    }

    func setShortcut(
        _ shortcut: WatchShortcutWire,
        for command: WatchRemoteCommand,
        trigger: WatchActionTrigger
    ) {
        let current = binding(for: command, trigger: trigger)
        guard current.action == .customShortcut,
              current.shortcut != shortcut
        else { return }
        update(
            WatchActionBindingWire(action: .customShortcut, shortcut: shortcut),
            for: command,
            trigger: trigger
        )
    }

    func setApplicationProfileID(
        _ profileID: String,
        for command: WatchRemoteCommand,
        trigger: WatchActionTrigger
    ) {
        let current = binding(for: command, trigger: trigger)
        guard current.action == .openCustomApplication,
              let normalizedID = UUID(uuidString: profileID)?.uuidString,
              current.applicationProfileID != normalizedID
        else { return }
        update(
            WatchActionBindingWire(
                action: .openCustomApplication,
                applicationProfileID: normalizedID
            ),
            for: command,
            trigger: trigger
        )
    }

    func reset() {
        let defaults = Self.defaultProfile(revision: nextRevision)
        guard defaults != profile else { return }
        profile = defaults
        persist()
    }

    func title(
        for command: WatchRemoteCommand,
        applicationTitles: [String: String]
    ) -> String {
        let binding = binding(for: command, trigger: .singleClick)
        switch binding.action {
        case .customShortcut:
            return binding.shortcut?.displayTitle ?? binding.action.displayTitle
        case .openCustomApplication:
            if let id = binding.applicationProfileID,
               let title = applicationTitles[id] {
                return title
            }
            return binding.action.displayTitle
        default:
            return binding.action.displayTitle
        }
    }

    static func defaultProfile(revision: Int = 1) -> WatchActionProfileWire {
        let bindings = Dictionary(
            uniqueKeysWithValues: WatchRemoteCommand.allCases.map { command in
                let triggers = Dictionary(
                    uniqueKeysWithValues: WatchActionTrigger.allCases.map { trigger in
                        let action: WatchActionKindWire = trigger == .singleClick
                            ? command.defaultAction
                            : .disabled
                        return (trigger.rawValue, WatchActionBindingWire(action: action))
                    }
                )
                return (command.wireButtonID, triggers)
            }
        )
        return WatchActionProfileWire(
            formatVersion: formatVersion,
            revision: revision,
            bindings: bindings
        )
    }

    private static func sanitizedForWristRemote(
        _ profile: WatchActionProfileWire
    ) -> WatchActionProfileWire {
        var sanitized = profile
        var changed = false
        for buttonID in WatchActionProfileWire.buttonIDs {
            for triggerID in WatchActionProfileWire.triggerIDs {
                guard let binding = sanitized.bindings[buttonID]?[triggerID] else { continue }
                guard binding.action == .customShortcut,
                      let shortcut = binding.shortcut
                else { continue }
                let sanitizedFlags = shortcut.modifierFlagsRawValue
                    & WatchShortcutWire.supportedModifierFlagsMask
                guard sanitizedFlags != shortcut.modifierFlagsRawValue else { continue }
                sanitized.bindings[buttonID]?[triggerID] = WatchActionBindingWire(
                    action: .customShortcut,
                    shortcut: WatchShortcutWire(
                        keyCode: shortcut.keyCode,
                        modifierFlagsRawValue: sanitizedFlags,
                        keyLabel: shortcut.keyLabel
                    )
                )
                changed = true
            }
        }
        if changed {
            sanitized.revision = sanitized.revision == Int.max ? 0 : sanitized.revision + 1
        }
        return sanitized
    }

    private var nextRevision: Int {
        profile.revision == Int.max ? 0 : profile.revision + 1
    }

    private func update(
        _ binding: WatchActionBindingWire,
        for command: WatchRemoteCommand,
        trigger: WatchActionTrigger
    ) {
        var updated = profile
        updated.revision = nextRevision
        updated.bindings[command.wireButtonID]?[trigger.rawValue] = binding
        guard let normalized = try? updated.validatedAndNormalized(), normalized != profile else {
            return
        }
        profile = normalized
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension WatchRemoteCommand {
    var defaultAction: WatchActionKindWire {
        switch self {
        case .power: return .escape
        case .up: return .arrowUp
        case .down: return .arrowDown
        case .left: return .arrowLeft
        case .right: return .arrowRight
        case .ok: return .returnKey
        case .back: return .deleteBackward
        case .home: return .showDesktop
        case .menu: return .contextMenu
        case .tv: return .appSwitcher
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        }
    }
}

enum WatchActionCategory: String, CaseIterable, Identifiable {
    case basic
    case system
    case applications
    case custom

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .basic: return "基本按键"
        case .system: return "系统与媒体"
        case .applications: return "打开 App"
        case .custom: return "自定义"
        }
    }
}

extension WatchActionKindWire {
    static var wristRemoteBridgeActions: [WatchActionKindWire] {
        allCases
    }

    var category: WatchActionCategory {
        switch self {
        case .disabled, .escape, .returnKey, .commandReturn, .shiftReturn,
             .commandCopy, .commandPaste, .commandQuit, .arrowUp, .arrowDown,
             .arrowLeft, .arrowRight, .deleteBackward:
            return .basic
        case .showDesktop, .contextMenu, .appSwitcher, .volumeUp, .volumeDown,
             .volumeMute, .playPause, .previousCommandLeft, .nextCommandRight:
            return .system
        case .openCustomApplication:
            return .applications
        case .customShortcut:
            return .custom
        }
    }

    var displayTitle: String {
        switch self {
        case .disabled: return "未设置"
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .commandReturn: return "Command-Return"
        case .shiftReturn: return "Shift-Return"
        case .commandCopy: return "复制 Command-C"
        case .commandPaste: return "粘贴 Command-V"
        case .commandQuit: return "退出 Command-Q"
        case .arrowUp: return "上箭头"
        case .arrowDown: return "下箭头"
        case .arrowLeft: return "左箭头"
        case .arrowRight: return "右箭头"
        case .deleteBackward: return "退格删除"
        case .showDesktop: return "显示桌面"
        case .contextMenu: return "上下文菜单"
        case .appSwitcher: return "切换 App Command-Tab"
        case .volumeUp: return "系统音量加"
        case .volumeDown: return "系统音量减"
        case .volumeMute: return "系统静音"
        case .playPause: return "播放 / 暂停"
        case .previousCommandLeft: return "上一个 Command-Left"
        case .nextCommandRight: return "下一个 Command-Right"
        case .customShortcut: return "自定义快捷键"
        case .openCustomApplication: return "Mac 自定义 App"
        }
    }
}

struct WatchShortcutKeyOption: Identifiable, Equatable {
    let keyCode: UInt16
    let label: String

    var id: UInt16 { keyCode }

    var shortcut: WatchShortcutWire {
        WatchShortcutWire(keyCode: keyCode, modifierFlagsRawValue: 0, keyLabel: label)
    }

    static let returnKey = WatchShortcutKeyOption(keyCode: 36, label: "Return")

    static let all: [WatchShortcutKeyOption] = [
        .init(keyCode: 53, label: "Escape"),
        .returnKey,
        .init(keyCode: 48, label: "Tab"),
        .init(keyCode: 49, label: "Space"),
        .init(keyCode: 51, label: "⌫"),
        .init(keyCode: 117, label: "⌦"),
        .init(keyCode: 123, label: "←"),
        .init(keyCode: 124, label: "→"),
        .init(keyCode: 125, label: "↓"),
        .init(keyCode: 126, label: "↑"),
        .init(keyCode: 0, label: "A"),
        .init(keyCode: 11, label: "B"),
        .init(keyCode: 8, label: "C"),
        .init(keyCode: 2, label: "D"),
        .init(keyCode: 14, label: "E"),
        .init(keyCode: 3, label: "F"),
        .init(keyCode: 5, label: "G"),
        .init(keyCode: 4, label: "H"),
        .init(keyCode: 34, label: "I"),
        .init(keyCode: 38, label: "J"),
        .init(keyCode: 40, label: "K"),
        .init(keyCode: 37, label: "L"),
        .init(keyCode: 46, label: "M"),
        .init(keyCode: 45, label: "N"),
        .init(keyCode: 31, label: "O"),
        .init(keyCode: 35, label: "P"),
        .init(keyCode: 12, label: "Q"),
        .init(keyCode: 15, label: "R"),
        .init(keyCode: 1, label: "S"),
        .init(keyCode: 17, label: "T"),
        .init(keyCode: 32, label: "U"),
        .init(keyCode: 9, label: "V"),
        .init(keyCode: 13, label: "W"),
        .init(keyCode: 7, label: "X"),
        .init(keyCode: 16, label: "Y"),
        .init(keyCode: 6, label: "Z"),
        .init(keyCode: 18, label: "1"),
        .init(keyCode: 19, label: "2"),
        .init(keyCode: 20, label: "3"),
        .init(keyCode: 21, label: "4"),
        .init(keyCode: 23, label: "5"),
        .init(keyCode: 22, label: "6"),
        .init(keyCode: 26, label: "7"),
        .init(keyCode: 28, label: "8"),
        .init(keyCode: 25, label: "9"),
        .init(keyCode: 29, label: "0"),
        .init(keyCode: 122, label: "F1"),
        .init(keyCode: 120, label: "F2"),
        .init(keyCode: 99, label: "F3"),
        .init(keyCode: 118, label: "F4"),
        .init(keyCode: 96, label: "F5"),
        .init(keyCode: 97, label: "F6"),
        .init(keyCode: 98, label: "F7"),
        .init(keyCode: 100, label: "F8"),
        .init(keyCode: 101, label: "F9"),
        .init(keyCode: 109, label: "F10"),
        .init(keyCode: 103, label: "F11"),
        .init(keyCode: 111, label: "F12"),
    ]
}

extension WatchShortcutWire {
    var displayTitle: String {
        var result = ""
        if modifierFlagsRawValue & WatchShortcutModifier.control.rawValue != 0 { result += "⌃" }
        if modifierFlagsRawValue & WatchShortcutModifier.option.rawValue != 0 { result += "⌥" }
        if modifierFlagsRawValue & WatchShortcutModifier.shift.rawValue != 0 { result += "⇧" }
        if modifierFlagsRawValue & WatchShortcutModifier.command.rawValue != 0 { result += "⌘" }
        return result + keyLabel
    }
}

enum WatchShortcutModifier: UInt, CaseIterable, Identifiable {
    case control = 262_144
    case option = 524_288
    case shift = 131_072
    case command = 1_048_576

    var id: UInt { rawValue }

    var displayTitle: String {
        switch self {
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .shift: return "Shift ⇧"
        case .command: return "Command ⌘"
        }
    }
}

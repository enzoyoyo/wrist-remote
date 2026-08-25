import Foundation

enum WatchProfileUpdateRetryReason: String, Codable, Equatable, Sendable {
    case voiceActive
}

enum WatchProfileBusyRetryPolicy {
    static let fastAttemptCount = 15
    static let maximumAttemptCount = 55
    static let retryDelayMilliseconds = 2_000
    static let sustainedRetryDelayMilliseconds = 30_000

    static func delayMilliseconds(afterFailureCount failureCount: Int) -> Int? {
        guard failureCount >= 0, failureCount < maximumAttemptCount else { return nil }
        return failureCount < fastAttemptCount
            ? retryDelayMilliseconds
            : sustainedRetryDelayMilliseconds
    }

    static func shouldSchedule(
        isForeground: Bool,
        hasValidConnection: Bool
    ) -> Bool {
        isForeground && hasValidConnection
    }
}

enum WatchActionKindWire: String, Codable, CaseIterable, Sendable {
    case disabled
    case escape
    case returnKey
    case commandReturn
    case shiftReturn
    case commandCopy
    case commandPaste
    case commandQuit
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case showDesktop
    case contextMenu
    case appSwitcher
    case volumeUp
    case volumeDown
    case volumeMute
    case playPause
    case previousCommandLeft
    case nextCommandRight
    case customShortcut
    case openCustomApplication
}

struct WatchShortcutWire: Codable, Equatable, Sendable {
    static let supportedModifierFlagsMask: UInt =
        (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    var keyCode: UInt16
    var modifierFlagsRawValue: UInt
    var keyLabel: String

    init(keyCode: UInt16, modifierFlagsRawValue: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlagsRawValue
        self.keyLabel = keyLabel
    }

    fileprivate func validatedAndNormalized(
        buttonID: String,
        triggerID: String
    ) throws -> WatchShortcutWire {
        let label = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64 else {
            throw WatchActionProfileValidationError.invalidShortcut(
                buttonID: buttonID,
                triggerID: triggerID
            )
        }
        return WatchShortcutWire(
            keyCode: keyCode,
            modifierFlagsRawValue: modifierFlagsRawValue & Self.supportedModifierFlagsMask,
            keyLabel: label
        )
    }
}

struct WatchActionBindingWire: Codable, Equatable, Sendable {
    var action: WatchActionKindWire
    var shortcut: WatchShortcutWire?
    var applicationProfileID: String?

    init(
        action: WatchActionKindWire,
        shortcut: WatchShortcutWire? = nil,
        applicationProfileID: String? = nil
    ) {
        self.action = action
        self.shortcut = shortcut
        self.applicationProfileID = applicationProfileID
    }

    fileprivate func validatedAndNormalized(
        buttonID: String,
        triggerID: String
    ) throws -> WatchActionBindingWire {
        switch action {
        case .customShortcut:
            guard let shortcut else {
                throw WatchActionProfileValidationError.missingShortcut(
                    buttonID: buttonID,
                    triggerID: triggerID
                )
            }
            return WatchActionBindingWire(
                action: action,
                shortcut: try shortcut.validatedAndNormalized(
                    buttonID: buttonID,
                    triggerID: triggerID
                )
            )
        case .openCustomApplication:
            guard let applicationProfileID,
                  let identifier = UUID(uuidString: applicationProfileID)
            else {
                throw WatchActionProfileValidationError.invalidApplicationProfileID(
                    buttonID: buttonID,
                    triggerID: triggerID
                )
            }
            return WatchActionBindingWire(
                action: action,
                applicationProfileID: identifier.uuidString
            )
        default:
            return WatchActionBindingWire(action: action)
        }
    }
}

struct WatchActionProfileWire: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let buttonIDs = [
        "power", "up", "left", "ok", "right", "down", "back", "volume_up",
        "home", "volume_down", "menu", "tv",
    ]
    static let triggerIDs = ["singleClick", "doubleClick", "longPress"]

    var formatVersion: Int
    var revision: Int
    var bindings: [String: [String: WatchActionBindingWire]]

    init(
        formatVersion: Int = WatchActionProfileWire.currentFormatVersion,
        revision: Int,
        bindings: [String: [String: WatchActionBindingWire]]
    ) {
        self.formatVersion = formatVersion
        self.revision = revision
        self.bindings = bindings
    }

    func validatedAndNormalized() throws -> WatchActionProfileWire {
        guard formatVersion == Self.currentFormatVersion else {
            throw WatchActionProfileValidationError.unsupportedFormatVersion(formatVersion)
        }
        guard revision >= 0 else {
            throw WatchActionProfileValidationError.invalidRevision(revision)
        }
        guard Set(bindings.keys) == Set(Self.buttonIDs) else {
            throw WatchActionProfileValidationError.invalidButtonSet
        }

        let expectedTriggers = Set(Self.triggerIDs)
        var normalized: [String: [String: WatchActionBindingWire]] = [:]
        for buttonID in Self.buttonIDs {
            guard let buttonBindings = bindings[buttonID],
                  Set(buttonBindings.keys) == expectedTriggers
            else {
                throw WatchActionProfileValidationError.invalidTriggerSet(buttonID: buttonID)
            }
            var triggers: [String: WatchActionBindingWire] = [:]
            for triggerID in Self.triggerIDs {
                guard let binding = buttonBindings[triggerID] else {
                    throw WatchActionProfileValidationError.invalidTriggerSet(buttonID: buttonID)
                }
                triggers[triggerID] = try binding.validatedAndNormalized(
                    buttonID: buttonID,
                    triggerID: triggerID
                )
            }
            normalized[buttonID] = triggers
        }
        return WatchActionProfileWire(revision: revision, bindings: normalized)
    }

    func encodedBase64() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(validatedAndNormalized()).base64EncodedString()
    }

    static func decodeBase64(_ encoded: String) throws -> WatchActionProfileWire {
        guard let data = Data(base64Encoded: encoded), data.count <= 64 * 1_024 else {
            throw WatchActionProfileValidationError.invalidEncoding
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data).validatedAndNormalized()
        } catch let error as WatchActionProfileValidationError {
            throw error
        } catch {
            throw WatchActionProfileValidationError.invalidEncoding
        }
    }
}

enum WatchActionProfileValidationError: Error, Equatable, LocalizedError {
    case invalidEncoding
    case unsupportedFormatVersion(Int)
    case invalidRevision(Int)
    case invalidButtonSet
    case invalidTriggerSet(buttonID: String)
    case missingShortcut(buttonID: String, triggerID: String)
    case invalidShortcut(buttonID: String, triggerID: String)
    case invalidApplicationProfileID(buttonID: String, triggerID: String)
    case unsupportedAction(buttonID: String, triggerID: String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "Apple Watch 配置无法解码。"
        case .unsupportedFormatVersion: return "Apple Watch 配置版本不受支持。"
        case .invalidRevision: return "Apple Watch 配置修订号无效。"
        case .invalidButtonSet: return "Apple Watch 配置必须完整包含 12 个按键。"
        case let .invalidTriggerSet(buttonID):
            return "Apple Watch 按键 \(buttonID) 必须包含单击、双击和长按。"
        case let .missingShortcut(buttonID, triggerID):
            return "Apple Watch 按键 \(buttonID) 的 \(triggerID) 缺少快捷键。"
        case let .invalidShortcut(buttonID, triggerID):
            return "Apple Watch 按键 \(buttonID) 的 \(triggerID) 快捷键无效。"
        case let .invalidApplicationProfileID(buttonID, triggerID):
            return "Apple Watch 按键 \(buttonID) 的 \(triggerID) 应用 ID 无效。"
        case let .unsupportedAction(buttonID, triggerID):
            return "Apple Watch 按键 \(buttonID) 的 \(triggerID) 动作不受独立桥支持。"
        }
    }
}

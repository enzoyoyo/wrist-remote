import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WatchActionEngine {
    struct Dependencies {
        var isAccessibilityTrusted: @MainActor () -> Bool
        var postKey: @MainActor (CGKeyCode, CGEventFlags) -> Bool
        var postSystemKey: @MainActor (Int32) -> Bool
        var openCustomApplication: @MainActor (BridgeApplicationProfile) -> Bool

        static let live = Dependencies(
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            postKey: WatchActionEngine.postKey,
            postSystemKey: WatchActionEngine.postSystemKey,
            openCustomApplication: WatchActionEngine.openCustomApplication
        )
    }

    private let dependencies: Dependencies
    private var applicationProfiles: [UUID: BridgeApplicationProfile] = [:]

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func updateApplicationProfiles(_ profiles: [BridgeApplicationProfile]) {
        applicationProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func canInstall(_ profile: WatchActionProfileWire) -> Bool {
        guard let normalized = try? profile.validatedAndNormalized() else { return false }
        for button in WatchActionProfileWire.buttonIDs {
            for trigger in WatchActionProfileWire.triggerIDs {
                guard let binding = normalized.bindings[button]?[trigger] else { return false }
                if binding.action == .openCustomApplication {
                    guard let rawID = binding.applicationProfileID,
                          let id = UUID(uuidString: rawID),
                          applicationProfiles[id] != nil
                    else { return false }
                }
            }
        }
        return true
    }

    @discardableResult
    func perform(_ binding: WatchActionBindingWire) -> Bool {
        switch binding.action {
        case .disabled:
            return true
        case .openCustomApplication:
            guard let rawID = binding.applicationProfileID,
                  let id = UUID(uuidString: rawID),
                  let profile = applicationProfiles[id]
            else { return false }
            return dependencies.openCustomApplication(profile)
        default:
            break
        }

        guard dependencies.isAccessibilityTrusted() else { return false }
        switch binding.action {
        case .escape:
            return dependencies.postKey(53, [])
        case .returnKey:
            return dependencies.postKey(36, [])
        case .commandReturn:
            return dependencies.postKey(36, .maskCommand)
        case .shiftReturn:
            return dependencies.postKey(36, .maskShift)
        case .commandCopy:
            return dependencies.postKey(8, .maskCommand)
        case .commandPaste:
            return dependencies.postKey(9, .maskCommand)
        case .commandQuit:
            return dependencies.postKey(12, .maskCommand)
        case .arrowUp:
            return dependencies.postKey(126, [])
        case .arrowDown:
            return dependencies.postKey(125, [])
        case .arrowLeft:
            return dependencies.postKey(123, [])
        case .arrowRight:
            return dependencies.postKey(124, [])
        case .deleteBackward:
            return dependencies.postKey(51, [])
        case .showDesktop:
            return dependencies.postKey(103, [])
        case .contextMenu:
            return dependencies.postKey(110, [])
        case .appSwitcher:
            return dependencies.postKey(48, .maskCommand)
        case .volumeUp:
            return dependencies.postSystemKey(0)
        case .volumeDown:
            return dependencies.postSystemKey(1)
        case .volumeMute:
            return dependencies.postSystemKey(7)
        case .playPause:
            return dependencies.postSystemKey(16)
        case .previousCommandLeft:
            return dependencies.postKey(123, .maskCommand)
        case .nextCommandRight:
            return dependencies.postKey(124, .maskCommand)
        case .customShortcut:
            guard let shortcut = binding.shortcut else { return false }
            return dependencies.postKey(
                CGKeyCode(shortcut.keyCode),
                Self.cgEventFlags(from: shortcut.modifierFlagsRawValue)
            )
        case .disabled, .openCustomApplication:
            return false
        }
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func postKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postSystemKey(_ type: Int32) -> Bool {
        let downData = Int((type << 16) | (0xA << 8))
        let upData = Int((type << 16) | (0xB << 8))
        guard let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: downData,
            data2: -1
        ), let up = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: upData,
            data2: -1
        ) else { return false }
        down.cgEvent?.post(tap: .cghidEventTap)
        up.cgEvent?.post(tap: .cghidEventTap)
        return true
    }

    private static func openCustomApplication(_ profile: BridgeApplicationProfile) -> Bool {
        let savedURL = URL(fileURLWithPath: profile.applicationPath)
        let url: URL?
        if Bundle(url: savedURL)?.bundleIdentifier == profile.bundleIdentifier {
            url = savedURL
        } else {
            url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: profile.bundleIdentifier
            )
        }
        guard let url else { return false }
        openApplication(at: url)
        return true
    }

    private static func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func cgEventFlags(from rawValue: UInt) -> CGEventFlags {
        let modifiers = NSEvent.ModifierFlags(rawValue: rawValue)
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

}

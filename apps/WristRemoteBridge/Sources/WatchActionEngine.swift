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
        var showContextMenu: @MainActor () -> Bool = { false }

        static let live = Dependencies(
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            postKey: WatchActionEngine.postKey,
            postSystemKey: WatchActionEngine.postSystemKey,
            openCustomApplication: WatchActionEngine.openCustomApplication,
            showContextMenu: WatchActionEngine.showContextMenu
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
            // macOS Show Desktop is Fn-F11. A bare F11 can reach the front app
            // without showing the desktop. Never rewrite the user's shortcuts.
            return dependencies.postKey(103, .maskSecondaryFn)
        case .contextMenu:
            return dependencies.showContextMenu()
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
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let steps = keyboardSequence(
            keyCode: keyCode, flags: flags,
            heldFlags: CGEventSource.flagsState(.combinedSessionState)
        )
        let events = steps.compactMap { step -> CGEvent? in
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.isDown
            ) else { return nil }
            event.flags = step.flags
            if step.isModifier { event.type = .flagsChanged }
            return event
        }
        guard events.count == steps.count else { return false }
        events.forEach { $0.post(tap: .cghidEventTap) }
        return true
    }

    struct KeyboardStep: Equatable {
        let keyCode: CGKeyCode
        let isDown: Bool
        let flags: CGEventFlags
        let isModifier: Bool
    }

    static func keyboardSequence(
        keyCode: CGKeyCode, flags: CGEventFlags, heldFlags: CGEventFlags
    ) -> [KeyboardStep] {
        // Cmd-Tab commits the switch only after Command is released. Merely
        // putting Command on the Tab events never supplies that release.
        // Do not release modifiers the user was already holding.
        let modifiers: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56),
            (.maskCommand, 55), (.maskSecondaryFn, 63),
        ]
        // Function-key state may reflect a preceding synthesized navigation
        // event. Do not carry it (or undocumented bits) into a new Cmd-Tab.
        let held = heldFlags.intersection([.maskControl, .maskAlternate, .maskShift,
                                          .maskCommand, .maskAlphaShift])
        let added = modifiers.filter { flags.contains($0.0) && !held.contains($0.0) }
        var active = held
        var steps: [KeyboardStep] = []
        for (flag, code) in added {
            active.insert(flag)
            steps.append(.init(keyCode: code, isDown: true, flags: active, isModifier: true))
        }
        steps.append(.init(keyCode: keyCode, isDown: true, flags: active, isModifier: false))
        steps.append(.init(keyCode: keyCode, isDown: false, flags: active, isModifier: false))
        for (flag, code) in added.reversed() {
            active.remove(flag)
            steps.append(.init(keyCode: code, isDown: false, flags: active, isModifier: true))
        }
        return steps
    }

    private static func showContextMenu() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var rawFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &rawFocused
        ) == .success,
              let rawFocused, CFGetTypeID(rawFocused) == AXUIElementGetTypeID()
        else { return false }
        let focused = unsafeBitCast(rawFocused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.5)
        if AXUIElementPerformAction(focused, kAXShowMenuAction as CFString) == .success {
            return true
        }
        // Some apps expose a focused element but no AXShowMenu action. Use a
        // secondary click inside that element, never a Windows-only menu key
        // or a click at an unrelated cursor position in another application.
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return false }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else { return false }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        var display: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &displayCount) == .success,
              displayCount > 0,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                                 mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                               mouseCursorPosition: point, mouseButton: .right)
        else { return false }
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
        guard let downEvent = down.cgEvent, let upEvent = up.cgEvent else { return false }
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
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

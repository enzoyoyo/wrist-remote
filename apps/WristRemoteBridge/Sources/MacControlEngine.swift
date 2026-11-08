import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class MacControlEngine {
    @MainActor
    struct Dependencies {
        var trusted: () -> Bool
        var pointer: (Double, Double) -> Bool
        var click: (Bool) -> Bool
        var scroll: (Double, Double) -> Bool
        var mediaKey: (Int32) -> Bool = WatchActionEngine.postSystemKey
        var binding: (WatchActionBindingWire) -> Bool
    }
    private let dependencies: Dependencies

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    convenience init(actionEngine: WatchActionEngine) {
        self.init(dependencies: Dependencies(
            trusted: { AXIsProcessTrusted() }, pointer: Self.move,
            click: Self.click, scroll: Self.scroll,
            binding: { actionEngine.perform($0) }
        ))
    }

    static let actions: [WristControlCommand.Action] = [
        .pointer, .click, .secondaryClick, .scroll, .volumeUp, .volumeDown,
        .mute, .playPause, .previousTrack, .nextTrack, .previousPage, .nextPage,
        .presentationStart, .presentationStop
    ]

    func perform(_ command: WristControlCommand) -> WristControlReceipt {
        guard command.targetID == "mac", Self.actions.contains(command.action),
              command.isValid(now: Int64(Date().timeIntervalSince1970 * 1_000)) else {
            return .init(id: command.id, accepted: false, detail: "操作已过期或设备不支持")
        }
        guard dependencies.trusted() else {
            return .init(id: command.id, accepted: false, detail: "请在 Mac 允许辅助功能权限")
        }
        let succeeded: Bool
        switch command.action {
        case .pointer: succeeded = dependencies.pointer(command.x, command.y)
        case .click: succeeded = dependencies.click(false)
        case .secondaryClick: succeeded = dependencies.click(true)
        case .scroll: succeeded = dependencies.scroll(command.x, command.y)
        case .previousTrack: succeeded = dependencies.mediaKey(18)
        case .nextTrack: succeeded = dependencies.mediaKey(17)
        default:
            guard let binding = Self.binding(for: command.action) else {
                return .init(id: command.id, accepted: false, detail: "此操作不可用")
            }
            succeeded = dependencies.binding(binding)
        }
        return .init(id: command.id, accepted: succeeded,
                     detail: succeeded ? "已提交 Mac" : "Mac 未执行，请检查权限")
    }

    static func binding(for action: WristControlCommand.Action) -> WatchActionBindingWire? {
        let mapped: WatchActionKindWire
        switch action {
        case .volumeUp: mapped = .volumeUp
        case .volumeDown: mapped = .volumeDown
        case .mute: mapped = .volumeMute
        case .playPause: mapped = .playPause
        case .previousPage: mapped = .arrowLeft
        case .nextPage: mapped = .arrowRight
        case .presentationStop: mapped = .escape
        case .presentationStart:
            return .init(action: .customShortcut, shortcut: .init(keyCode: 35, modifierFlagsRawValue: UInt(CGEventFlags.maskCommand.union(.maskAlternate).rawValue), keyLabel: "⌥⌘P"))
        case .previousTrack:
            return .init(action: .customShortcut, shortcut: .init(keyCode: 123, modifierFlagsRawValue: UInt(CGEventFlags.maskCommand.rawValue), keyLabel: "⌘←/→"))
        case .nextTrack:
            return .init(action: .customShortcut, shortcut: .init(keyCode: 124, modifierFlagsRawValue: UInt(CGEventFlags.maskCommand.rawValue), keyLabel: "⌘←/→"))
        default: return nil
        }
        return .init(action: mapped)
    }

    private static func move(x: Double, y: Double) -> Bool {
        guard let source = CGEventSource(stateID: .privateState), let location = CGEvent(source: nil)?.location else { return false }
        // Clamp to the union of visible displays, including negative origins.
        let rectangles = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        let proposed = CGPoint(x: location.x + x, y: location.y + y)
        let nearest = rectangles.map { bounds in
            CGPoint(x: min(max(proposed.x, bounds.minX), bounds.maxX - 1),
                    y: min(max(proposed.y, bounds.minY), bounds.maxY - 1))
        }.min { hypot($0.x - proposed.x, $0.y - proposed.y) < hypot($1.x - proposed.x, $1.y - proposed.y) } ?? location
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: nearest, mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func click(secondary: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .privateState), let location = CGEvent(source: nil)?.location,
              let down = CGEvent(mouseEventSource: source, mouseType: secondary ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: location, mouseButton: secondary ? .right : .left),
              let up = CGEvent(mouseEventSource: source, mouseType: secondary ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: location, mouseButton: secondary ? .right : .left) else { return false }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    private static func scroll(x: Double, y: Double) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(y.rounded()), wheel2: Int32(x.rounded()), wheel3: 0) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}

final class WristControlCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [WristControlTarget] = []
    var snapshot: [WristControlTarget] { lock.lock(); defer { lock.unlock() }; return targets }
    func update(_ targets: [WristControlTarget]) { lock.lock(); defer { lock.unlock() }; self.targets = targets }
}

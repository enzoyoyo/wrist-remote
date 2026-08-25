import Foundation

struct WatchGestureRecognizer {
    enum Command: Equatable {
        case scheduleDoubleClickTimeout(WristRemoteButton)
        case cancelDoubleClickTimeout(WristRemoteButton)
        case scheduleLongPressTimeout(WristRemoteButton)
        case cancelLongPressTimeout(WristRemoteButton)
        case trigger(WristRemoteButton, WristRemoteTrigger)
    }

    private struct State {
        var isPressed = true
        var isSecondPress = false
        var waitingForSecondPress = false
        var longPressTriggered = false
        let recognizesDoubleClick: Bool
        let recognizesLongPress: Bool
    }

    private var states: [WristRemoteButton: State] = [:]

    mutating func handle(
        _ phase: WristRemoteButtonPhase,
        button: WristRemoteButton,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> [Command] {
        switch phase {
        case .press:
            if var state = states[button] {
                guard state.waitingForSecondPress else { return [] }
                state.isPressed = true
                state.isSecondPress = true
                state.waitingForSecondPress = false
                states[button] = state
                var commands: [Command] = [.cancelDoubleClickTimeout(button)]
                if state.recognizesLongPress {
                    commands.append(.scheduleLongPressTimeout(button))
                }
                return commands
            }
            states[button] = State(
                recognizesDoubleClick: recognizesDoubleClick,
                recognizesLongPress: recognizesLongPress
            )
            return recognizesLongPress ? [.scheduleLongPressTimeout(button)] : []

        case .release:
            guard var state = states[button], state.isPressed else { return [] }
            state.isPressed = false
            var commands: [Command] = []
            if state.recognizesLongPress {
                commands.append(.cancelLongPressTimeout(button))
            }
            if state.longPressTriggered {
                states.removeValue(forKey: button)
                return commands
            }
            if state.isSecondPress {
                states.removeValue(forKey: button)
                commands.append(.trigger(button, .doubleClick))
                return commands
            }
            if state.recognizesDoubleClick {
                state.waitingForSecondPress = true
                states[button] = state
                commands.append(.scheduleDoubleClickTimeout(button))
                return commands
            }
            states.removeValue(forKey: button)
            commands.append(.trigger(button, .singleClick))
            return commands
        }
    }

    mutating func doubleClickTimedOut(_ button: WristRemoteButton) -> [Command] {
        guard let state = states[button], state.waitingForSecondPress, !state.isPressed else {
            return []
        }
        states.removeValue(forKey: button)
        return [.trigger(button, .singleClick)]
    }

    mutating func longPressTimedOut(_ button: WristRemoteButton) -> [Command] {
        guard var state = states[button], state.isPressed, state.recognizesLongPress else {
            return []
        }
        state.longPressTriggered = true
        states[button] = state
        return [.trigger(button, .longPress)]
    }

    mutating func reset() {
        states.removeAll()
    }

    mutating func cancel(_ button: WristRemoteButton) {
        states.removeValue(forKey: button)
    }
}

@MainActor
final class WatchGestureDispatcher {
    static let doubleClickDelay: Duration = .milliseconds(320)
    static let longPressDelay: Duration = .milliseconds(620)

    private var recognizer = WatchGestureRecognizer()
    private var doubleClickTasks: [WristRemoteButton: Task<Void, Never>] = [:]
    private var longPressTasks: [WristRemoteButton: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private(set) var profile: WatchActionProfileWire?
    var onBinding: ((WatchActionBindingWire) -> Bool)?

    @discardableResult
    func install(_ profile: WatchActionProfileWire) -> Bool {
        guard let normalized = try? profile.validatedAndNormalized() else { return false }
        reset()
        self.profile = normalized
        return true
    }

    func handle(_ phase: WristRemoteButtonPhase, button: WristRemoteButton) -> Bool {
        guard let bindings = profile?.bindings[button.rawValue] else { return false }
        let commands = recognizer.handle(
            phase,
            button: button,
            recognizesDoubleClick: bindings[WristRemoteTrigger.doubleClick.rawValue]?.action != .disabled,
            recognizesLongPress: bindings[WristRemoteTrigger.longPress.rawValue]?.action != .disabled
        )
        execute(commands, generation: generation)
        return true
    }

    /// Executes a gesture already resolved on Apple Watch. Internet latency
    /// must not participate in click/double-click/hold classification.
    func trigger(_ trigger: WristRemoteTrigger, button: WristRemoteButton) -> Bool {
        guard let binding = profile?.bindings[button.rawValue]?[trigger.rawValue],
              binding.action != .disabled
        else { return false }
        return onBinding?(binding) == true
    }

    func reset() {
        generation &+= 1
        doubleClickTasks.values.forEach { $0.cancel() }
        longPressTasks.values.forEach { $0.cancel() }
        doubleClickTasks.removeAll()
        longPressTasks.removeAll()
        recognizer.reset()
        profile = nil
    }

    /// Drops an incomplete edge without turning it into single/double/long
    /// press. Used when an Internet relay disconnect makes the matching release
    /// unknowable.
    func cancel(_ button: WristRemoteButton) {
        doubleClickTasks.removeValue(forKey: button)?.cancel()
        longPressTasks.removeValue(forKey: button)?.cancel()
        recognizer.cancel(button)
    }

    private func execute(
        _ commands: [WatchGestureRecognizer.Command],
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                doubleClickTasks[button]?.cancel()
                let taskGeneration = generation
                doubleClickTasks[button] = Task { [weak self] in
                    try? await Task.sleep(for: Self.doubleClickDelay)
                    guard !Task.isCancelled,
                          let self,
                          self.generation == taskGeneration
                    else { return }
                    self.doubleClickTasks[button] = nil
                    self.execute(
                        self.recognizer.doubleClickTimedOut(button),
                        generation: taskGeneration
                    )
                }
            case let .cancelDoubleClickTimeout(button):
                doubleClickTasks.removeValue(forKey: button)?.cancel()
            case let .scheduleLongPressTimeout(button):
                longPressTasks[button]?.cancel()
                let taskGeneration = generation
                longPressTasks[button] = Task { [weak self] in
                    try? await Task.sleep(for: Self.longPressDelay)
                    guard !Task.isCancelled,
                          let self,
                          self.generation == taskGeneration
                    else { return }
                    self.longPressTasks[button] = nil
                    self.execute(
                        self.recognizer.longPressTimedOut(button),
                        generation: taskGeneration
                    )
                }
            case let .cancelLongPressTimeout(button):
                longPressTasks.removeValue(forKey: button)?.cancel()
            case let .trigger(button, trigger):
                guard generation == expectedGeneration,
                      let binding = profile?.bindings[button.rawValue]?[trigger.rawValue]
                else {
                    continue
                }
                _ = onBinding?(binding)
            }
        }
    }
}

import Foundation

/// Resolves a physical Watch press locally before a WAN request is sent.
/// Network round-trip time therefore has no influence on single/double/long
/// classification.
struct WristInternetButtonGestureResolver {
    struct PressOutcome: Equatable {
        let shouldCancelSingleClick: Bool
        let shouldScheduleLongPress: Bool
    }

    enum ReleaseOutcome: Equatable {
        case none
        case scheduleSingleClick
        case commit(WristInternetRelayButtonTrigger)
    }

    private struct State {
        let profileRevision: Int
        let recognizesDoubleClick: Bool
        let recognizesLongPress: Bool
        var isPressed = true
        var isSecondPress = false
        var waitingForSecondPress = false
        var longPressCommitted = false
    }

    private var states: [WatchRemoteCommand: State] = [:]

    func pendingRevision(for command: WatchRemoteCommand) -> Int? {
        states[command]?.profileRevision
    }

    mutating func press(
        _ command: WatchRemoteCommand,
        profileRevision: Int,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> PressOutcome? {
        if var state = states[command] {
            guard state.profileRevision == profileRevision,
                  state.waitingForSecondPress,
                  !state.isPressed
            else { return nil }
            state.isPressed = true
            state.isSecondPress = true
            state.waitingForSecondPress = false
            states[command] = state
            return PressOutcome(
                shouldCancelSingleClick: true,
                shouldScheduleLongPress: state.recognizesLongPress
            )
        }

        states[command] = State(
            profileRevision: profileRevision,
            recognizesDoubleClick: recognizesDoubleClick,
            recognizesLongPress: recognizesLongPress
        )
        return PressOutcome(
            shouldCancelSingleClick: false,
            shouldScheduleLongPress: recognizesLongPress
        )
    }

    mutating func release(
        _ command: WatchRemoteCommand,
        profileRevision: Int
    ) -> ReleaseOutcome? {
        guard var state = states[command],
              state.profileRevision == profileRevision,
              state.isPressed
        else { return nil }

        state.isPressed = false
        if state.longPressCommitted {
            states.removeValue(forKey: command)
            return ReleaseOutcome.none
        }
        if state.isSecondPress {
            states.removeValue(forKey: command)
            return .commit(.doubleClick)
        }
        if state.recognizesDoubleClick {
            state.waitingForSecondPress = true
            states[command] = state
            return .scheduleSingleClick
        }
        states.removeValue(forKey: command)
        return .commit(.singleClick)
    }

    mutating func longPressTimedOut(
        _ command: WatchRemoteCommand,
        profileRevision: Int
    ) -> WristInternetRelayButtonTrigger? {
        guard var state = states[command],
              state.profileRevision == profileRevision,
              state.isPressed,
              state.recognizesLongPress,
              !state.longPressCommitted
        else { return nil }
        state.longPressCommitted = true
        states[command] = state
        return .longPress
    }

    mutating func singleClickTimedOut(
        _ command: WatchRemoteCommand,
        profileRevision: Int
    ) -> WristInternetRelayButtonTrigger? {
        guard let state = states[command],
              state.profileRevision == profileRevision,
              state.waitingForSecondPress,
              !state.isPressed
        else { return nil }
        states.removeValue(forKey: command)
        return .singleClick
    }

    mutating func cancel(_ command: WatchRemoteCommand) {
        states.removeValue(forKey: command)
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: false)
    }
}

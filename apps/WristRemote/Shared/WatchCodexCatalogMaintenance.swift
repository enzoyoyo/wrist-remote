/// Defers destination maintenance for the whole voice interaction, including
/// preparation before a receipt exists. Resuming performs no network action.
struct WatchCodexCatalogMaintenance {
    private(set) var needsReconciliation = false

    mutating func mayUpdateSelection(voiceIsBusy: Bool) -> Bool {
        needsReconciliation = voiceIsBusy
        return !voiceIsBusy
    }

    func mayResume(isSceneActive: Bool, voiceIsBusy: Bool) -> Bool {
        needsReconciliation && isSceneActive && !voiceIsBusy
    }
}

/// A cold launch can reach the phone before the phone has reconnected to Mac.
/// Defer the catalog request until a live status confirms the complete route.
/// This gate only refreshes metadata; it never retries a user submission.
struct WatchCodexCatalogStartupGate {
    private(set) var isWaitingForRoute = false

    mutating func request(routeIsReady: Bool) -> Bool {
        isWaitingForRoute = !routeIsReady
        return routeIsReady
    }

    mutating func consumeReadyStatus(routeIsReady: Bool, sceneIsActive: Bool) -> Bool {
        guard isWaitingForRoute, routeIsReady, sceneIsActive else { return false }
        isWaitingForRoute = false
        return true
    }

    mutating func cancel() { isWaitingForRoute = false }
}

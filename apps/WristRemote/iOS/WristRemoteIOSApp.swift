import SwiftUI

@main
@MainActor
struct WristRemoteIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var connection: WristBridgeConnection
    @StateObject private var layoutSettings: WatchLayoutSettings
    @StateObject private var actionProfileStore: WatchActionProfileStore
    @StateObject private var relay: WatchRelayController

    init() {
        let connection = WristBridgeConnection()
        let layoutSettings = WatchLayoutSettings()
        let actionProfileStore = WatchActionProfileStore()
        let relay = WatchRelayController(
            connection: connection,
            layoutSettings: layoutSettings,
            actionProfileStore: actionProfileStore
        )

        _connection = StateObject(wrappedValue: connection)
        _layoutSettings = StateObject(wrappedValue: layoutSettings)
        _actionProfileStore = StateObject(wrappedValue: actionProfileStore)
        _relay = StateObject(wrappedValue: relay)

        relay.activate()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WristRemoteHomeView(
                    connection: connection,
                    relay: relay,
                    settings: layoutSettings,
                    profileStore: actionProfileStore
                )
            }
            .task {
                applyScenePhase(scenePhase)
            }
            .onChange(of: scenePhase) { _, phase in
                applyScenePhase(phase)
            }
        }
    }

    private func applyScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            connection.sceneDidBecomeActive()
            relay.sceneDidBecomeActive()
        } else {
            connection.sceneDidBecomeInactive()
            relay.sceneDidBecomeInactive()
        }
    }
}

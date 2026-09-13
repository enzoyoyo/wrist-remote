import SwiftUI

@main
@MainActor
struct WristRemoteIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationResetID = UUID()

    private static var isUIPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--wristremote-ui-preview")
            || isRemoteUIPreview
        #else
        false
        #endif
    }

    private static var isRemoteUIPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--wristremote-ui-preview-remote")
        #else
        false
        #endif
    }

    @StateObject private var connection: WristBridgeConnection
    @StateObject private var layoutSettings: WatchLayoutSettings
    @StateObject private var actionProfileStore: WatchActionProfileStore
    @StateObject private var relay: WatchRelayController

    init() {
        let connection = WristBridgeConnection(networkingEnabled: !Self.isUIPreview)
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

        if !Self.isUIPreview { relay.activate() }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if Self.isRemoteUIPreview {
                    WristPhoneRemoteView(connection: connection, profileStore: actionProfileStore)
                } else {
                    WristRemoteHomeView(
                        connection: connection,
                        relay: relay,
                        settings: layoutSettings,
                        profileStore: actionProfileStore
                    )
                }
            }
            .id(navigationResetID)
            .task {
                applyScenePhase(scenePhase)
            }
            .onChange(of: scenePhase) { _, phase in
                applyScenePhase(phase)
            }
            .onOpenURL { url in
                guard !Self.isUIPreview else { return }
                connection.importPairingLink(url)
                navigationResetID = UUID()
            }
        }
    }

    private func applyScenePhase(_ phase: ScenePhase) {
        guard !Self.isUIPreview else { return }
        if phase == .active {
            connection.sceneDidBecomeActive()
            relay.sceneDidBecomeActive()
        } else {
            connection.sceneDidBecomeInactive()
            relay.sceneDidBecomeInactive()
        }
    }
}

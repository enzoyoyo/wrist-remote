import SwiftUI

@main
struct WristRemoteWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = WatchSessionController()

    var body: some Scene {
        WindowGroup {
            WatchRemoteRootView(controller: controller)
                .tint(.wristRemoteAccent)
                .preferredColorScheme(.dark)
                .task {
                    controller.start()
                    if scenePhase == .active {
                        controller.sceneDidBecomeActive()
                    } else {
                        controller.sceneDidBecomeInactive()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        controller.sceneDidBecomeActive()
                    case .inactive, .background:
                        controller.sceneDidBecomeInactive()
                    @unknown default:
                        controller.sceneDidBecomeInactive()
                    }
                }
        }
    }
}

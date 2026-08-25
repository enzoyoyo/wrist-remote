import SwiftUI

@main
@MainActor
struct WristRemoteBridgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BridgeAppModel()

    var body: some Scene {
        WindowGroup("腕上遥控桥") {
            BridgeContentView(model: model)
                .onAppear { model.start() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.refreshSystemStatus() }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

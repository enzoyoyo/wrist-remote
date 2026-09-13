import SwiftUI

@main
@MainActor
struct WristRemoteBridgeApp: App {
    @StateObject private var runtimeOwner = BridgeRuntimeOwner(
        isUnitTestHost: BridgeLaunchPolicy.isUnitTestHost(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            xctestLoaded: NSClassFromString("XCTestCase") != nil
        ),
        makeRuntime: { BridgeAppModel() }
    )

    var body: some Scene {
        WindowGroup("腕上遥控桥") {
            if let model = runtimeOwner.runtime {
                BridgeRuntimeView(model: model)
            } else {
                // XCTest hosts must not instantiate production Keychain,
                // listeners, login-item handling or user-facing error alerts.
                Color.clear
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

enum BridgeLaunchPolicy {
    static func isUnitTestHost(
        environment: [String: String], bundleIdentifier: String?, xctestLoaded: Bool
    ) -> Bool {
        xctestLoaded || bundleIdentifier?.hasSuffix(".testsession") == true
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

private struct BridgeRuntimeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        BridgeContentView(model: model)
            .onAppear { model.start() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.refreshSystemStatus() }
            }
    }
}

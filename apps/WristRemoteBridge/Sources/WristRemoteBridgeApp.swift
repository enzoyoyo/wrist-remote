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
        makeRuntime: {
            #if DEBUG
            if BridgeLaunchPolicy.isPresentationPreview {
                return BridgeAppModel(
                    preferences: BridgePreferences(
                        defaults: UserDefaults(suiteName: "dev.wristremote.presentation-preview")!,
                        trustedIdentityStore: PreviewIdentityStore()),
                    isPresentationPreview: true)
            }
            #endif
            return BridgeAppModel()
        }
    )

    init() {
        // Before any window appears and before the runtime binds 60927/60928/60929.
        // A second copy cannot serve, so it hands off to the running bridge.
        guard !BridgeLaunchPolicy.isUnitTestHost(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            xctestLoaded: NSClassFromString("XCTestCase") != nil
        ) else { return }
        #if DEBUG
        if BridgeLaunchPolicy.isPresentationPreview { return }
        #endif
        SingleInstanceGate.enforceAtLaunch()
    }

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

#if DEBUG
private struct PreviewIdentityStore: TrustedIdentityFingerprintStoring {
    func load() -> TrustedIdentityFingerprintLoadResult { .loaded([]) }
    func save(_ fingerprints: Set<String>) -> Bool { false }
}
#endif

enum BridgeLaunchPolicy {
    static var isPresentationPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--control-center-preview")
            || Bundle.main.bundleIdentifier == "dev.wristremote.control-center-preview"
        #else
        false
        #endif
    }

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
            .onAppear {
                #if DEBUG
                if BridgeLaunchPolicy.isPresentationPreview { return }
                #endif
                model.start()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.refreshSystemStatus() }
            }
    }
}

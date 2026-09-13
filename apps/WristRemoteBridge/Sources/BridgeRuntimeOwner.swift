import Combine

/// Owned by the App, not a WindowGroup's content. Closing the last window must
/// not discard the active bridge or create a second set of listeners on reopen.
@MainActor
final class BridgeRuntimeOwner<Runtime: AnyObject>: ObservableObject {
    let runtime: Runtime?

    init(isUnitTestHost: Bool, makeRuntime: () -> Runtime) {
        // Keep the factory lazy at this boundary: even constructing the real
        // model reads Keychain and preferences, which XCTest hosts must avoid.
        runtime = isUnitTestHost ? nil : makeRuntime()
    }
}

import Foundation
import WatchKit

@MainActor
enum WatchHaptics {
    static let isEnabledDefaultsKey = "WristRemote.hapticsEnabled"

    static var isEnabled: Bool {
        if let storedValue = UserDefaults.standard.object(
            forKey: isEnabledDefaultsKey
        ) as? Bool {
            return storedValue
        }
        return true
    }

    static func play(_ type: WKHapticType) {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }
}

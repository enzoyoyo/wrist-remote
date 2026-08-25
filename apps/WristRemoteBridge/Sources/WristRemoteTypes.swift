import Foundation

enum WristRemoteButton: String, CaseIterable, Codable, Identifiable {
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv

    var id: String { rawValue }
}

enum WristRemoteButtonPhase: String, Codable {
    case press
    case release
}

enum WristRemoteTrigger: String, CaseIterable, Codable {
    case singleClick
    case doubleClick
    case longPress
}

struct BridgeApplicationProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var bundleIdentifier: String
    var applicationPath: String

    init(
        id: UUID = UUID(),
        title: String,
        bundleIdentifier: String,
        applicationPath: String
    ) {
        self.id = id
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
    }
}

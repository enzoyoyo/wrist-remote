import Combine
import Foundation

@MainActor
final class WatchLayoutSettings: ObservableObject {
    static let favoriteCount = 4
    static let defaultFavorites: [WatchRemoteCommand] = [
        .back,
        .home,
        .volumeUp,
        .volumeDown,
    ]

    @Published private(set) var favorites: [WatchRemoteCommand]

    private enum Keys {
        static let favorites = "WristRemote.favoriteCommands.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedCommands = defaults.stringArray(forKey: Keys.favorites)?
            .compactMap(WatchRemoteCommand.init(rawValue:)) ?? []
        favorites = Self.normalizedFavorites(storedCommands)
    }

    func setFavorite(_ command: WatchRemoteCommand, at index: Int) {
        guard favorites.indices.contains(index), favorites[index] != command else { return }

        if let existingIndex = favorites.firstIndex(of: command) {
            favorites.swapAt(index, existingIndex)
        } else {
            favorites[index] = command
        }
        persist()
    }

    func replaceFavorites(_ commands: [WatchRemoteCommand]) {
        let normalized = Self.normalizedFavorites(commands)
        guard normalized != favorites else { return }
        favorites = normalized
        persist()
    }

    func reset() {
        replaceFavorites(Self.defaultFavorites)
    }

    static func normalizedFavorites(
        _ commands: [WatchRemoteCommand]
    ) -> [WatchRemoteCommand] {
        var result: [WatchRemoteCommand] = []
        for command in commands + defaultFavorites + WatchRemoteCommand.allCases
        where !result.contains(command) {
            result.append(command)
            if result.count == favoriteCount { break }
        }
        return result
    }

    private func persist() {
        defaults.set(favorites.map(\.rawValue), forKey: Keys.favorites)
    }
}

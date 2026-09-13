import Foundation

enum TrustedIdentityFingerprintLoadResult: Equatable {
    case loaded(Set<String>)
    case notFound
    case unavailable
}

protocol TrustedIdentityFingerprintStoring {
    func load() -> TrustedIdentityFingerprintLoadResult

    @discardableResult
    func save(_ fingerprints: Set<String>) -> Bool
}

struct KeychainTrustedIdentityFingerprintStore: TrustedIdentityFingerprintStoring {
    private static let account = "trusted-identity-fingerprints-v1"
    private let service: String

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = "\(bundleIdentifier ?? "dev.wristremote.bridge").trusted-identities"
    }

    func load() -> TrustedIdentityFingerprintLoadResult {
        switch WristInternetRelayKeychain.loadResult(
            [String].self,
            account: Self.account,
            service: service
        ) {
        case let .loaded(fingerprints):
            return .loaded(Set(fingerprints))
        case .notFound:
            return .notFound
        case .unavailable:
            return .unavailable
        }
    }

    @discardableResult
    func save(_ fingerprints: Set<String>) -> Bool {
        WristInternetRelayKeychain.save(
            fingerprints.sorted(),
            account: Self.account,
            service: service
        )
    }
}

final class BridgePreferences {
    /// Legacy UserDefaults key retained only for one-way Keychain migration.
    static let trustedIdentityFingerprintsKey = "trustedIdentityFingerprints"
    static let applicationProfilesKey = "applicationProfiles"
    static let codexPinnedThreadIDKey = "codexPinnedThreadID"
    static let codexTaskStateRevisionKey = "codexTaskStateRevision"
    static let watchActionProfileKey = "watchActionProfile"
    static let tailnetAccessEnabledKey = "tailnetAccessEnabled"

    private let defaults: UserDefaults
    private let trustedIdentityStore: any TrustedIdentityFingerprintStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        trustedIdentityStore: any TrustedIdentityFingerprintStoring =
            KeychainTrustedIdentityFingerprintStore()
    ) {
        self.defaults = defaults
        self.trustedIdentityStore = trustedIdentityStore
        migrateLegacyTrustedIdentityFingerprints()
    }

    var trustedIdentityFingerprints: Set<String> {
        guard case let .loaded(fingerprints) = trustedIdentityStore.load() else {
            return []
        }
        return fingerprints
    }

    var applicationProfiles: [BridgeApplicationProfile] {
        get {
            guard let data = defaults.data(forKey: Self.applicationProfilesKey),
                  let profiles = try? decoder.decode([BridgeApplicationProfile].self, from: data)
            else { return [] }
            return Self.normalizedProfiles(profiles)
        }
        set {
            let profiles = Self.normalizedProfiles(newValue)
            defaults.set(try? encoder.encode(profiles), forKey: Self.applicationProfilesKey)
        }
    }

    var codexPinnedThreadID: String? {
        get {
            guard let value = defaults.string(forKey: Self.codexPinnedThreadIDKey),
                  CodexThreadIdentifier.isValid(value)
            else { return nil }
            return value
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.codexPinnedThreadIDKey)
                return
            }
            guard CodexThreadIdentifier.isValid(newValue) else { return }
            defaults.set(newValue, forKey: Self.codexPinnedThreadIDKey)
        }
    }

    var watchActionProfile: WatchActionProfileWire? {
        get {
            guard let data = defaults.data(forKey: Self.watchActionProfileKey),
                  let profile = try? decoder.decode(WatchActionProfileWire.self, from: data),
                  let normalized = try? profile.validatedAndNormalized()
            else { return nil }
            return normalized
        }
        set {
            guard let newValue,
                  let normalized = try? newValue.validatedAndNormalized(),
                  let data = try? encoder.encode(normalized)
            else {
                defaults.removeObject(forKey: Self.watchActionProfileKey)
                return
            }
            defaults.set(data, forKey: Self.watchActionProfileKey)
        }
    }

    var tailnetAccessEnabled: Bool {
        get { defaults.bool(forKey: Self.tailnetAccessEnabledKey) }
        set { defaults.set(newValue, forKey: Self.tailnetAccessEnabledKey) }
    }

    /// A process-independent ordering token for both task snapshots and clear
    /// tombstones. It is intentionally separate from a Codex turn revision.
    func nextCodexTaskStateRevision() -> Int {
        let current = max(0, defaults.integer(forKey: Self.codexTaskStateRevisionKey))
        guard current < Int.max else { return current }
        let next = current + 1
        defaults.set(next, forKey: Self.codexTaskStateRevisionKey)
        return next
    }

    func trusts(_ fingerprint: String) -> Bool {
        trustedIdentityFingerprints.contains(fingerprint)
    }

    @discardableResult
    func trust(_ fingerprint: String) -> Bool {
        var fingerprints: Set<String>
        switch trustedIdentityStore.load() {
        case let .loaded(existing):
            fingerprints = existing
        case .notFound:
            fingerprints = []
        case .unavailable:
            return false
        }
        fingerprints.insert(fingerprint)
        return trustedIdentityStore.save(fingerprints)
    }

    private func migrateLegacyTrustedIdentityFingerprints() {
        guard let legacyFingerprints = defaults.stringArray(
            forKey: Self.trustedIdentityFingerprintsKey
        ) else { return }
        let existing: Set<String>
        switch trustedIdentityStore.load() {
        case let .loaded(fingerprints):
            existing = fingerprints
        case .notFound:
            existing = []
        case .unavailable:
            return
        }
        let migrated = existing.union(legacyFingerprints)
        guard trustedIdentityStore.save(migrated) else { return }
        defaults.removeObject(forKey: Self.trustedIdentityFingerprintsKey)
    }

    static func normalizedProfiles(
        _ profiles: [BridgeApplicationProfile]
    ) -> [BridgeApplicationProfile] {
        var seen = Set<UUID>()
        return profiles.compactMap { profile in
            let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleIdentifier = profile.bundleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let applicationPath = profile.applicationPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(profile.id).inserted,
                  !title.isEmpty,
                  title.count <= 80,
                  !bundleIdentifier.isEmpty,
                  bundleIdentifier.count <= 255,
                  !applicationPath.isEmpty,
                  applicationPath.count <= 4_096
            else { return nil }
            return BridgeApplicationProfile(
                id: profile.id,
                title: title,
                bundleIdentifier: bundleIdentifier,
                applicationPath: applicationPath
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

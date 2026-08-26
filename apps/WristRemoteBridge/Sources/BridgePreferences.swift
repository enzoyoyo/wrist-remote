import Foundation

protocol TrustedIdentityFingerprintStoring {
    func load() -> Set<String>

    @discardableResult
    func save(_ fingerprints: Set<String>) -> Bool
}

struct KeychainTrustedIdentityFingerprintStore: TrustedIdentityFingerprintStoring {
    private static let account = "trusted-identity-fingerprints-v1"
    private let service: String

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = "\(bundleIdentifier ?? "dev.wristremote.bridge").trusted-identities"
    }

    func load() -> Set<String> {
        Set(
            WristInternetRelayKeychain.load(
                [String].self,
                account: Self.account,
                service: service
            ) ?? []
        )
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
        get {
            trustedIdentityStore.load()
        }
        set {
            trustedIdentityStore.save(newValue)
        }
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

    func trust(_ fingerprint: String) {
        var fingerprints = trustedIdentityFingerprints
        fingerprints.insert(fingerprint)
        trustedIdentityFingerprints = fingerprints
    }

    private func migrateLegacyTrustedIdentityFingerprints() {
        guard let legacyFingerprints = defaults.stringArray(
            forKey: Self.trustedIdentityFingerprintsKey
        ) else { return }
        let migrated = trustedIdentityStore.load().union(legacyFingerprints)
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

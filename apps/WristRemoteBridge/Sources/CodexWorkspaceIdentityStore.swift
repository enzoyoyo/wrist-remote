import Foundation

/// Owner-only, Mac-local workspace aliases used to keep one opaque workspace
/// identity stable when Codex threads run inside managed detached worktrees.
///
/// Paths never leave the Mac and this file is not a request or submission
/// ledger. A corrupt or conflicting persistent state fails closed so a new
/// task cannot silently move to a different workspace identity.
struct CodexWorkspaceIdentityStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let cwd: String
        let workspaceID: String
        let isCanonicalRoot: Bool

        fileprivate var isValid: Bool {
            !cwd.isEmpty
                && cwd.utf8.count <= 4_096
                && !cwd.contains("\0")
                && (cwd as NSString).isAbsolutePath
                && URL(fileURLWithPath: cwd, isDirectory: true)
                    .standardizedFileURL.path == cwd
                && WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID)
        }
    }

    struct State: Codable, Equatable, Sendable {
        let version: Int
        var records: [Record]

        fileprivate var isValid: Bool {
            version == CodexWorkspaceIdentityStore.currentVersion
                && records.count <= CodexWorkspaceIdentityStore.maximumRecordCount
                && Set(records.map(\.cwd)).count == records.count
                && records.allSatisfy(\.isValid)
                && Dictionary(grouping: records.filter(\.isCanonicalRoot), by: \.workspaceID)
                    .values.allSatisfy { $0.count == 1 }
        }

        func workspaceID(for cwd: String) -> String? {
            records.first { $0.cwd == cwd }?.workspaceID
        }

        func canonicalCWD(for workspaceID: String) -> String? {
            records.first {
                $0.workspaceID == workspaceID && $0.isCanonicalRoot
            }?.cwd
        }

        mutating func register(
            cwd: String,
            workspaceID: String,
            preferCanonicalRoot: Bool
        ) throws -> Bool {
            guard Record(
                cwd: cwd,
                workspaceID: workspaceID,
                isCanonicalRoot: false
            ).isValid else { throw StoreError.invalidState }
            if let index = records.firstIndex(where: { $0.cwd == cwd }) {
                let existing = records[index]
                guard existing.workspaceID == workspaceID else {
                    throw StoreError.identityConflict
                }
                if preferCanonicalRoot,
                   !existing.isCanonicalRoot,
                   canonicalCWD(for: workspaceID) == nil {
                    records[index] = Record(
                        cwd: existing.cwd,
                        workspaceID: existing.workspaceID,
                        isCanonicalRoot: true
                    )
                    guard isValid else { throw StoreError.invalidState }
                    return true
                }
                return false
            }
            guard records.count < CodexWorkspaceIdentityStore.maximumRecordCount else {
                throw StoreError.capacityExceeded
            }
            let hasCanonicalRoot = canonicalCWD(for: workspaceID) != nil
            records.append(Record(
                cwd: cwd,
                workspaceID: workspaceID,
                isCanonicalRoot: preferCanonicalRoot && !hasCanonicalRoot
            ))
            guard isValid else { throw StoreError.invalidState }
            return true
        }
    }

    enum StoreError: Error, Equatable {
        case unavailable
        case invalidState
        case identityConflict
        case capacityExceeded
    }

    fileprivate static let currentVersion = 1
    fileprivate static let maximumRecordCount = 128
    private static let maximumFileBytes = 128 * 1_024

    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    static func persistentDefault() -> CodexWorkspaceIdentityStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return CodexWorkspaceIdentityStore(
            fileURL: base
                .appendingPathComponent("WristRemoteBridge", isDirectory: true)
                .appendingPathComponent("CodexWorkspaceIdentities.json", isDirectory: false)
        )
    }

    func load() throws -> State {
        guard let fileURL else {
            return State(version: Self.currentVersion, records: [])
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return State(version: Self.currentVersion, records: [])
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= Self.maximumFileBytes,
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.isValid
        else { throw StoreError.unavailable }
        return state
    }

    func save(_ state: State) throws {
        guard state.isValid,
              let data = try? JSONEncoder().encode(state),
              data.count <= Self.maximumFileBytes
        else { throw StoreError.invalidState }
        guard let fileURL else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw StoreError.unavailable
        }
    }
}

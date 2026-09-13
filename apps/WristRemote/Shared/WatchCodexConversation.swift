import Foundation

enum WatchCodexConversationState: String, Codable, Equatable, Sendable {
    case running
    case idle
    case unavailable
}

enum WatchCodexTargetKind: String, Codable, Equatable, Sendable {
    case existing
    case newConversation
}

/// A short-lived, Mac-issued capability for one exact Codex destination.
///
/// The Watch never supplies a working directory or an arbitrary destination.
/// It can only echo this capability while it remains valid.
struct WatchCodexConversationTarget: Codable, Equatable, Hashable, Sendable {
    // A presentation hint only. The Mac still validates the complete issued
    // capability; a caller cannot grant itself access by inventing this ID.
    static let standaloneWorkspaceID = "standalone-blank-task"
    let leaseID: UUID
    let kind: WatchCodexTargetKind
    let serverEpoch: UUID
    let catalogRevision: Int
    let entryRevision: Int64
    let threadID: String?
    let displayTitle: String
    let workspaceID: String
    let workspaceLabel: String
    let expiresAtEpochMilliseconds: Int64

    init?(
        leaseID: UUID,
        kind: WatchCodexTargetKind,
        serverEpoch: UUID,
        catalogRevision: Int,
        entryRevision: Int64,
        threadID: String?,
        displayTitle: String,
        workspaceID: String,
        workspaceLabel: String,
        expiresAtEpochMilliseconds: Int64
    ) {
        guard catalogRevision >= 0,
              entryRevision >= 0,
              expiresAtEpochMilliseconds > 0,
              WatchCodexConversationWireValidation.isValidTitle(displayTitle),
              WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID),
              WatchCodexConversationWireValidation.isValidWorkspaceLabel(workspaceLabel)
        else { return nil }

        switch kind {
        case .existing:
            guard CodexThreadIdentifier.isValid(threadID) else { return nil }
        case .newConversation:
            guard threadID == nil else { return nil }
        }

        self.leaseID = leaseID
        self.kind = kind
        self.serverEpoch = serverEpoch
        self.catalogRevision = catalogRevision
        self.entryRevision = entryRevision
        self.threadID = threadID
        self.displayTitle = displayTitle
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
    }

    var id: UUID { leaseID }

    var isStandaloneNewConversation: Bool {
        kind == .newConversation && workspaceID == Self.standaloneWorkspaceID
    }

    func isExpired(atEpochMilliseconds now: Int64) -> Bool {
        now >= expiresAtEpochMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case leaseID
        case kind
        case serverEpoch
        case catalogRevision
        case entryRevision
        case threadID
        case displayTitle
        case workspaceID
        case workspaceLabel
        case expiresAtEpochMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            leaseID: try container.decode(UUID.self, forKey: .leaseID),
            kind: try container.decode(WatchCodexTargetKind.self, forKey: .kind),
            serverEpoch: try container.decode(UUID.self, forKey: .serverEpoch),
            catalogRevision: try container.decode(Int.self, forKey: .catalogRevision),
            entryRevision: try container.decode(Int64.self, forKey: .entryRevision),
            threadID: try container.decodeIfPresent(String.self, forKey: .threadID),
            displayTitle: try container.decode(String.self, forKey: .displayTitle),
            workspaceID: try container.decode(String.self, forKey: .workspaceID),
            workspaceLabel: try container.decode(String.self, forKey: .workspaceLabel),
            expiresAtEpochMilliseconds: try container.decode(
                Int64.self,
                forKey: .expiresAtEpochMilliseconds
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex conversation target"
                )
            )
        }
        self = value
    }
}

/// Durable Watch-side identity for one unresolved "new conversation" action.
///
/// It intentionally stores only the opaque operation UUID and the stable,
/// Mac-issued workspace identifier. Short-lived target leases, server epochs,
/// local paths, audio, and transcripts never enter this record.
struct WatchCodexConversationSelectionOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let workspaceID: String

    init?(operationID: UUID, target: WatchCodexConversationTarget) {
        guard target.kind == .newConversation,
              WatchCodexConversationWireValidation.isValidWorkspaceID(target.workspaceID)
        else { return nil }
        self.operationID = operationID
        workspaceID = target.workspaceID
    }

    func matches(_ target: WatchCodexConversationTarget) -> Bool {
        target.kind == .newConversation && target.workspaceID == workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case operationID
        case workspaceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workspaceID = try container.decode(String.self, forKey: .workspaceID)
        guard WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex selection workspace identity"
                )
            )
        }
        operationID = try container.decode(UUID.self, forKey: .operationID)
        self.workspaceID = workspaceID
    }
}

struct WatchCodexConversationSelectionOperationBook: Codable, Equatable, Sendable {
    static let maximumPendingCount = 8
    static let empty = WatchCodexConversationSelectionOperationBook(operations: [])!

    private(set) var operations: [WatchCodexConversationSelectionOperation]

    init?(operations: [WatchCodexConversationSelectionOperation]) {
        guard operations.count <= Self.maximumPendingCount,
              Set(operations.map(\.workspaceID)).count == operations.count,
              Set(operations.map(\.operationID)).count == operations.count
        else { return nil }
        self.operations = operations.sorted { $0.workspaceID < $1.workspaceID }
    }

    var pendingCount: Int { operations.count }

    mutating func operationID(
        for target: WatchCodexConversationTarget,
        creating candidate: UUID
    ) -> UUID? {
        guard target.kind == .newConversation else { return nil }
        if let existing = operations.first(where: { $0.matches(target) }) {
            return existing.operationID
        }
        guard operations.count < Self.maximumPendingCount,
              let operation = WatchCodexConversationSelectionOperation(
                  operationID: candidate,
                  target: target
              ),
              !operations.contains(where: { $0.operationID == candidate })
        else { return nil }
        operations.append(operation)
        operations.sort { $0.workspaceID < $1.workspaceID }
        return candidate
    }

    mutating func markCompleted(_ target: WatchCodexConversationTarget) {
        guard target.kind == .newConversation else { return }
        operations.removeAll { $0.matches(target) }
    }

    private enum CodingKeys: String, CodingKey {
        case operations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operations = try container.decode(
            [WatchCodexConversationSelectionOperation].self,
            forKey: .operations
        )
        guard let value = Self(operations: operations) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex selection operation book"
                )
            )
        }
        self = value
    }
}

enum WatchCodexConversationSelectionOperationStore {
    enum LoadResult: Equatable {
        case loaded(WatchCodexConversationSelectionOperationBook)
        case notFound
        case unavailable
    }

    static let defaultsKey = "WristRemote.codexConversationSelectionOperations.v1"

    static func load(defaults: UserDefaults = .standard) -> LoadResult {
        guard defaults.object(forKey: defaultsKey) != nil else { return .notFound }
        guard let data = defaults.data(forKey: defaultsKey),
              data.count <= 16 * 1_024,
              let value = try? JSONDecoder().decode(
                  WatchCodexConversationSelectionOperationBook.self,
                  from: data
              )
        else { return .unavailable }
        return .loaded(value)
    }

    @discardableResult
    static func save(
        _ value: WatchCodexConversationSelectionOperationBook,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if value.pendingCount == 0 {
            defaults.removeObject(forKey: defaultsKey)
            return defaults.object(forKey: defaultsKey) == nil
        }
        guard let data = try? JSONEncoder().encode(value), data.count <= 16 * 1_024 else {
            return false
        }
        defaults.set(data, forKey: defaultsKey)
        return defaults.data(forKey: defaultsKey) == data
    }
}

/// One user-visible row in the Mac-authoritative conversation catalog.
/// New-conversation rows intentionally have no thread identifier until the user
/// explicitly selects one and the Mac creates an independent task immediately.
struct WatchCodexConversationEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    let threadID: String?
    let title: String
    let workspaceLabel: String
    let state: WatchCodexConversationState
    let updatedAtEpochMilliseconds: Int64
    let canAcceptInput: Bool
    let entryRevision: Int64
    let target: WatchCodexConversationTarget

    init?(
        threadID: String?,
        title: String,
        workspaceLabel: String,
        state: WatchCodexConversationState,
        updatedAtEpochMilliseconds: Int64,
        canAcceptInput: Bool,
        entryRevision: Int64,
        target: WatchCodexConversationTarget
    ) {
        guard updatedAtEpochMilliseconds >= 0,
              entryRevision >= 0,
              entryRevision == target.entryRevision,
              title == target.displayTitle,
              workspaceLabel == target.workspaceLabel,
              WatchCodexConversationWireValidation.isValidTitle(title),
              WatchCodexConversationWireValidation.isValidWorkspaceLabel(workspaceLabel)
        else { return nil }

        switch target.kind {
        case .existing:
            guard CodexThreadIdentifier.isValid(threadID),
                  threadID == target.threadID
            else { return nil }
        case .newConversation:
            guard threadID == nil, target.threadID == nil else { return nil }
        }

        self.threadID = threadID
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.state = state
        self.updatedAtEpochMilliseconds = updatedAtEpochMilliseconds
        self.canAcceptInput = canAcceptInput
        self.entryRevision = entryRevision
        self.target = target
    }

    var id: String {
        if let threadID { return "existing:\(threadID)" }
        return "new:\(target.workspaceID)"
    }

    private enum CodingKeys: String, CodingKey {
        case threadID
        case title
        case workspaceLabel
        case state
        case updatedAtEpochMilliseconds
        case canAcceptInput
        case entryRevision
        case target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            threadID: try container.decodeIfPresent(String.self, forKey: .threadID),
            title: try container.decode(String.self, forKey: .title),
            workspaceLabel: try container.decode(String.self, forKey: .workspaceLabel),
            state: try container.decode(WatchCodexConversationState.self, forKey: .state),
            updatedAtEpochMilliseconds: try container.decode(
                Int64.self,
                forKey: .updatedAtEpochMilliseconds
            ),
            canAcceptInput: try container.decode(Bool.self, forKey: .canAcceptInput),
            entryRevision: try container.decode(Int64.self, forKey: .entryRevision),
            target: try container.decode(WatchCodexConversationTarget.self, forKey: .target)
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex conversation catalog entry"
                )
            )
        }
        self = value
    }
}

struct WatchCodexConversationCatalog: Codable, Equatable, Sendable {
    static let maximumEntryCount = 32

    let serverEpoch: UUID
    let revision: Int
    let entries: [WatchCodexConversationEntry]
    let hasMore: Bool
    let refreshedAtEpochMilliseconds: Int64

    init?(
        serverEpoch: UUID,
        revision: Int,
        entries: [WatchCodexConversationEntry],
        hasMore: Bool,
        refreshedAtEpochMilliseconds: Int64
    ) {
        guard revision >= 0,
              refreshedAtEpochMilliseconds >= 0,
              entries.count <= Self.maximumEntryCount,
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.target.leaseID)).count == entries.count,
              entries.allSatisfy({ entry in
                  entry.target.serverEpoch == serverEpoch
                      && entry.target.catalogRevision == revision
                      && entry.target.expiresAtEpochMilliseconds > refreshedAtEpochMilliseconds
              })
        else { return nil }

        let existingThreadIDs = entries.compactMap(\.threadID)
        guard Set(existingThreadIDs).count == existingThreadIDs.count else { return nil }

        self.serverEpoch = serverEpoch
        self.revision = revision
        self.entries = entries
        self.hasMore = hasMore
        self.refreshedAtEpochMilliseconds = refreshedAtEpochMilliseconds
    }

    /// Installs the Mac-issued existing-thread capability returned after an
    /// explicit "new task" selection. Keeping the original catalog revision
    /// lets Mac, iPhone and Watch authorize the same target before the next
    /// full refresh without exposing a working directory to either device.
    func installingImmediatelyCreatedConversation(
        _ target: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64
    ) -> WatchCodexConversationCatalog? {
        guard target.kind == .existing,
              serverEpoch == target.serverEpoch,
              revision == target.catalogRevision,
              nowEpochMilliseconds >= refreshedAtEpochMilliseconds,
              target.entryRevision >= refreshedAtEpochMilliseconds,
              !target.isExpired(atEpochMilliseconds: nowEpochMilliseconds),
              let entry = WatchCodexConversationEntry(
                  threadID: target.threadID,
                  title: target.displayTitle,
                  workspaceLabel: target.workspaceLabel,
                  state: .idle,
                  updatedAtEpochMilliseconds: target.entryRevision,
                  canAcceptInput: true,
                  entryRevision: target.entryRevision,
                  target: target
              )
        else { return nil }

        let retained = entries.filter {
            $0.target != target && $0.threadID != target.threadID
        }
        let nextEntries = Array(([entry] + retained).prefix(Self.maximumEntryCount))
        return WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: revision,
            entries: nextEntries,
            hasMore: hasMore || nextEntries.count < retained.count + 1,
            refreshedAtEpochMilliseconds: refreshedAtEpochMilliseconds
        )
    }

    /// Only for a recording already bound to an authenticated capability.
    /// A harmless catalog/lease renewal may not cancel or redirect its audio.
    /// Starting a new recording still requires the exact current capability.
    func permitsContinuingVoice(
        for target: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        guard !target.isExpired(atEpochMilliseconds: nowEpochMilliseconds) else { return false }
        return entries.contains {
            $0.canAcceptInput && WatchCodexConversationSelectionResolution.permitsLeaseRenewal(
                current: target, replacement: $0.target,
                nowEpochMilliseconds: nowEpochMilliseconds
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case serverEpoch
        case revision
        case entries
        case hasMore
        case refreshedAtEpochMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            serverEpoch: try container.decode(UUID.self, forKey: .serverEpoch),
            revision: try container.decode(Int.self, forKey: .revision),
            entries: try container.decode([WatchCodexConversationEntry].self, forKey: .entries),
            hasMore: try container.decode(Bool.self, forKey: .hasMore),
            refreshedAtEpochMilliseconds: try container.decode(
                Int64.self,
                forKey: .refreshedAtEpochMilliseconds
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex conversation catalog"
                )
            )
        }
        self = value
    }
}

enum WatchCodexConversationCatalogAcceptanceDisposition: Equatable, Sendable {
    case install
    case unchanged
    case rejectRevisionRollback
    case rejectRevisionConflict
}

/// One ordering rule shared by every device that caches the Mac-issued catalog.
///
/// A Bridge restart intentionally changes `serverEpoch`, so its first catalog
/// starts a new ordering domain. Within one epoch revisions are monotonic, and
/// an equal revision is accepted only when the complete signed-by-channel value
/// is identical. This prevents a delayed snapshot or a conflicting replay from
/// replacing a newer local catalog.
enum WatchCodexConversationCatalogAcceptancePolicy {
    static func disposition(
        current: WatchCodexConversationCatalog?,
        candidate: WatchCodexConversationCatalog
    ) -> WatchCodexConversationCatalogAcceptanceDisposition {
        guard let current else { return .install }
        guard current.serverEpoch == candidate.serverEpoch else { return .install }
        if candidate.revision < current.revision { return .rejectRevisionRollback }
        if candidate.revision > current.revision { return .install }
        return candidate == current ? .unchanged : .rejectRevisionConflict
    }
}

/// Validates the Mac's answer to a Watch destination-selection request.
///
/// An existing thread must round-trip exactly. A new-task capability may be
/// replaced only by a freshly issued existing-thread capability for the same
/// Mac epoch, catalog revision and opaque workspace. This lets a tap create the
/// task immediately without allowing the Mac reply to redirect the Watch to an
/// unrelated thread.
enum WatchCodexConversationSelectionResolution {
    /// Renew a selected lease from an authenticated accepted catalog, without
    /// selecting a different task or creating a new one.
    static func permitsLeaseRenewal(
        current: WatchCodexConversationTarget,
        replacement: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        current.kind == .existing && replacement.kind == .existing
            && replacement.serverEpoch == current.serverEpoch
            && replacement.threadID == current.threadID
            && replacement.workspaceID == current.workspaceID
            && replacement.catalogRevision >= current.catalogRevision
            && !replacement.isExpired(atEpochMilliseconds: nowEpochMilliseconds)
    }

    static func isSafeReplacement(
        requested: WatchCodexConversationTarget,
        selected: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        guard !requested.isExpired(atEpochMilliseconds: nowEpochMilliseconds),
              !selected.isExpired(atEpochMilliseconds: nowEpochMilliseconds)
        else { return false }
        switch requested.kind {
        case .existing:
            return selected == requested
        case .newConversation:
            return selected.kind == .existing
                && selected.serverEpoch == requested.serverEpoch
                && selected.catalogRevision == requested.catalogRevision
                && selected.workspaceID == requested.workspaceID
                && selected.workspaceLabel == requested.workspaceLabel
                && CodexThreadIdentifier.isValid(selected.threadID)
        }
    }

    static func isAccepted(
        requested: WatchCodexConversationTarget,
        selected: WatchCodexConversationTarget,
        catalog: WatchCodexConversationCatalog?,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        guard let catalog,
              catalog.serverEpoch == requested.serverEpoch,
              catalog.revision == requested.catalogRevision,
              catalog.entries.contains(where: {
                  $0.target == requested && $0.canAcceptInput
              }),
              isSafeReplacement(
                  requested: requested,
                  selected: selected,
                  nowEpochMilliseconds: nowEpochMilliseconds
              )
        else { return false }
        return true
    }
}

enum WatchCodexConversationSelectionRequestDisposition: Equatable, Sendable {
    case start
    case alreadyPending
    case busy
}

/// Keeps Watch destination selection single-flight. A duplicate new-thread
/// request can otherwise race its first reply and make the UI report failure
/// even though the Mac already created the independent thread.
enum WatchCodexConversationSelectionRequestGate {
    static func disposition(
        requested: WatchCodexConversationTarget,
        activeRequestID: UUID?,
        pendingTarget: WatchCodexConversationTarget?
    ) -> WatchCodexConversationSelectionRequestDisposition {
        guard activeRequestID == nil, pendingTarget == nil else {
            return activeRequestID != nil && pendingTarget == requested
                ? .alreadyPending
                : .busy
        }
        return .start
    }
}

/// A transcript is submit-able only when the Watch echoes this exact draft
/// identifier, exact target lease and expiry issued after transcription.
struct WatchCodexDraftLease: Codable, Equatable, Sendable {
    let draftID: UUID
    let target: WatchCodexConversationTarget
    let expiresAtEpochMilliseconds: Int64

    init?(
        draftID: UUID,
        target: WatchCodexConversationTarget,
        expiresAtEpochMilliseconds: Int64
    ) {
        guard target.kind == .existing,
              expiresAtEpochMilliseconds > 0,
              expiresAtEpochMilliseconds <= target.expiresAtEpochMilliseconds
        else { return nil }
        self.draftID = draftID
        self.target = target
        self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
    }

    func isExpired(atEpochMilliseconds now: Int64) -> Bool {
        now >= expiresAtEpochMilliseconds || target.isExpired(atEpochMilliseconds: now)
    }

    private enum CodingKeys: String, CodingKey {
        case draftID
        case target
        case expiresAtEpochMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            draftID: try container.decode(UUID.self, forKey: .draftID),
            target: try container.decode(WatchCodexConversationTarget.self, forKey: .target),
            expiresAtEpochMilliseconds: try container.decode(
                Int64.self,
                forKey: .expiresAtEpochMilliseconds
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Codex conversation draft lease"
                )
            )
        }
        self = value
    }
}

enum WatchCodexConversationWireValidation {
    static let maximumTranscriptCharacterCount = 2_000
    static let maximumTranscriptByteCount = 8_000
    static let maximumDetailByteCount = 512
    static let maximumTargetPayloadByteCount = 4_096
    static let maximumCatalogPayloadByteCount = 131_072
    static let maximumVoiceOutcomePayloadByteCount = 24_000

    static func isValidTitle(_ value: String) -> Bool {
        isValidSingleLine(value, maximumByteCount: 320)
    }

    static func isValidWorkspaceLabel(_ value: String) -> Bool {
        isValidSingleLine(value, maximumByteCount: 240)
    }

    static func isValidWorkspaceID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy { scalar in
                (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 45
            }
    }

    static func isValidDetail(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumDetailByteCount
            && !containsDisallowedControlCharacter(value, allowingLineBreaks: true)
    }

    static func isValidLocaleIdentifier(_ value: String) -> Bool {
        isValidSingleLine(value, maximumByteCount: 64)
    }

    static func isCanonicalUUIDString(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString == value
    }

    static func isValidTranscript(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximumTranscriptCharacterCount
            && value.utf8.count <= maximumTranscriptByteCount
            && !containsDisallowedControlCharacter(value, allowingLineBreaks: true)
    }

    private static func isValidSingleLine(_ value: String, maximumByteCount: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumByteCount
            && !containsDisallowedControlCharacter(value, allowingLineBreaks: false)
    }

    private static func containsDisallowedControlCharacter(
        _ value: String,
        allowingLineBreaks: Bool
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            if allowingLineBreaks,
               (scalar == "\n".unicodeScalars.first || scalar == "\t".unicodeScalars.first) {
                return false
            }
            return true
        }
    }
}

import CryptoKit
import Darwin
import Foundation
import Security

enum CodexConversationFingerprintKeyStore {
    private static let account = "codex-conversation-fingerprint-v1"

    static func loadOrCreate() -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { return nil }

        var data = Data(count: 32)
        guard data.withUnsafeMutableBytes({ buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }) == errSecSuccess else { return nil }
        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { return nil }
        return SymmetricKey(data: data)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String:
                "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge").codex-conversation",
            kSecAttrAccount as String: account,
        ]
    }
}

struct CodexWorkspaceOption: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct CodexExistingConversationSubmission: Equatable, Sendable {
    let submissionID: UUID
    let threadID: String
    let message: String
}

struct CodexExistingConversationAudioSubmission: Equatable, Sendable {
    let submissionID: UUID
    let threadID: String
    let fileURL: URL
    let sha256Hex: String
}

struct CodexNewConversationSubmission: Equatable, Sendable {
    let requestID: UUID
    let submissionID: UUID
    let workspaceID: String
    let message: String
}

enum CodexConversationServiceError: Error, Equatable, LocalizedError {
    case invalidWorkspaceConfiguration
    case unknownWorkspace
    case invalidThreadID
    case invalidMessage
    case invalidAudio
    case idempotencyConflict
    case idempotencyLedgerUnavailable
    case requestInProgress
    case outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .invalidWorkspaceConfiguration:
            return "Codex 工作区配置无效。"
        case .unknownWorkspace:
            return "所选 Codex 工作区已不可用。"
        case .invalidThreadID:
            return "Codex 会话标识无效。"
        case .invalidMessage:
            return "Codex 消息为空或过长。"
        case .invalidAudio:
            return "Codex 原始录音无效。"
        case .idempotencyConflict:
            return "Codex 请求标识已用于另一条消息。"
        case .idempotencyLedgerUnavailable:
            return "无法安全验证 Codex 发送记录，操作已停止。"
        case .requestInProgress:
            return "这条 Codex 消息正在处理。"
        case .outcomeUnknown:
            return "这条消息可能已经进入 Codex；为避免重复发送，请先查看对应会话。"
        }
    }
}

struct CodexConversationCompletedSubmissionCache<Value: Sendable>: Sendable {
    struct Entry: Sendable {
        let fingerprint: String
        let value: Value
    }

    private let maximumCount: Int
    private var entries: [UUID: Entry] = [:]
    private var insertionOrder: [UUID] = []

    init(maximumCount: Int) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
    }

    var count: Int { entries.count }

    func entry(for submissionID: UUID) -> Entry? {
        entries[submissionID]
    }

    mutating func insert(
        submissionID: UUID,
        fingerprint: String,
        value: Value
    ) {
        if entries[submissionID] == nil {
            insertionOrder.append(submissionID)
        }
        entries[submissionID] = Entry(fingerprint: fingerprint, value: value)
        while entries.count > maximumCount {
            let evicted = insertionOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}

/// Durable, privacy-minimizing idempotency for existing and new conversations.
/// The file contains identifiers, SHA-256 fingerprints, stage, and queue
/// receipts only. It never contains voice text or working-directory paths.
actor CodexConversationIdempotencyLedger {
    struct Limits: Equatable, Sendable {
        let maximumRecordCount: Int
        let maximumFileBytes: Int

        static let production = Limits(
            maximumRecordCount: 512,
            maximumFileBytes: 512 * 1_024
        )

        init(maximumRecordCount: Int, maximumFileBytes: Int) {
            precondition(maximumRecordCount > 0)
            precondition(maximumFileBytes > 0)
            self.maximumRecordCount = maximumRecordCount
            self.maximumFileBytes = maximumFileBytes
        }
    }

    /// Deterministic persistence test seam. It carries no request content or path data.
    enum PersistenceFault: Equatable, Sendable {
        case none
        case failCompletion
        case failAbort
    }

    enum BeginResult: Equatable, Sendable {
        case new
        case inProgress
        case unknownAfterSideEffect
        case completed(CodexConversationQueueReceipt)
    }

    private enum OperationKind: String, Codable {
        case existingConversation
        case newConversation
    }

    private enum Stage: String, Codable {
        case prepared
        case completed
    }

    private struct Record: Codable {
        let operation: OperationKind
        let requestID: UUID?
        let fingerprint: String
        var stage: Stage
        var threadID: String?
        var queuedSubmissionID: String?
    }

    private struct PersistedRecord: Codable {
        let submissionID: UUID
        let record: Record
    }

    private struct FileState: Codable {
        let version: Int
        let records: [PersistedRecord]
        let completedSubmissionIDs: [UUID]
    }

    private struct LedgerState {
        var records: [UUID: Record]
        var completedSubmissionIDs: [UUID]
    }

    private struct LoadedState {
        let state: LedgerState
        let requiresMigration: Bool
    }

    private static let currentVersion = 1

    private let fileURL: URL?
    private let persistenceFault: PersistenceFault
    private let limits: Limits
    private var records: [UUID: Record] = [:]
    private var completedSubmissionIDs: [UUID] = []
    private var submissionIDByRequestID: [UUID: UUID] = [:]
    private var activeSubmissionIDs = Set<UUID>()
    private var loadFailed = false

    /// In-memory by default, so unit tests never touch production state.
    init(
        fileURL: URL? = nil,
        persistenceFault: PersistenceFault = .none,
        limits: Limits = .production
    ) {
        self.fileURL = fileURL
        self.persistenceFault = persistenceFault
        self.limits = limits
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let loaded = try Self.load(fileURL: fileURL, limits: limits)
            records = loaded.state.records
            completedSubmissionIDs = loaded.state.completedSubmissionIDs
            submissionIDByRequestID = try Self.validatedRequestMapping(for: records)
            if loaded.requiresMigration {
                try Self.persist(
                    loaded.state,
                    fileURL: fileURL,
                    limits: limits
                )
            }
        } catch {
            records = [:]
            completedSubmissionIDs = []
            submissionIDByRequestID = [:]
            loadFailed = true
        }
    }

    static func persistentDefault() -> CodexConversationIdempotencyLedger {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let applicationIdentifier = Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge"
        let fileURL = applicationSupport
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("CodexConversationLedger.json", isDirectory: false)
        return CodexConversationIdempotencyLedger(fileURL: fileURL)
    }

    func beginExisting(submissionID: UUID, fingerprint: String) throws -> BeginResult {
        try begin(
            operation: .existingConversation,
            requestID: nil,
            submissionID: submissionID,
            fingerprint: fingerprint
        )
    }

    func beginNew(
        requestID: UUID,
        submissionID: UUID,
        fingerprint: String
    ) throws -> BeginResult {
        try begin(
            operation: .newConversation,
            requestID: requestID,
            submissionID: submissionID,
            fingerprint: fingerprint
        )
    }

    func complete(
        submissionID: UUID,
        fingerprint: String,
        receipt: CodexConversationQueueReceipt
    ) throws {
        guard !loadFailed,
              var record = records[submissionID],
              record.fingerprint == fingerprint,
              receipt.submissionID == submissionID,
              Self.isValidThreadID(receipt.threadID),
              Self.isValidQueuedSubmissionID(receipt.queuedSubmissionID)
        else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }

        if record.stage == .completed {
            guard record.threadID == receipt.threadID.lowercased(),
                  record.queuedSubmissionID == receipt.queuedSubmissionID
            else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
            activeSubmissionIDs.remove(submissionID)
            return
        }

        record.stage = .completed
        record.threadID = receipt.threadID.lowercased()
        record.queuedSubmissionID = receipt.queuedSubmissionID
        var candidate = LedgerState(
            records: records,
            completedSubmissionIDs: completedSubmissionIDs
        )
        candidate.records[submissionID] = record
        candidate.completedSubmissionIDs.append(submissionID)
        do {
            if persistenceFault == .failCompletion {
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            candidate = try Self.compacted(
                candidate,
                preservingCompleted: [submissionID],
                limits: limits
            )
            if let fileURL {
                try Self.persist(candidate, fileURL: fileURL, limits: limits)
            }
        } catch {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
        records = candidate.records
        completedSubmissionIDs = candidate.completedSubmissionIDs
        submissionIDByRequestID = try Self.validatedRequestMapping(for: records)
        activeSubmissionIDs.remove(submissionID)
    }

    func finishWithoutReceipt(submissionID: UUID, fingerprint: String) {
        guard records[submissionID]?.fingerprint == fingerprint else { return }
        activeSubmissionIDs.remove(submissionID)
    }

    /// Only the active caller with proof that queue/add was never attempted may
    /// release its reservation. Historical/uncertain records are never cleared.
    func abortBeforeQueue(submissionID: UUID, fingerprint: String) throws {
        guard !loadFailed,
              let record = records[submissionID],
              record.stage == .prepared,
              record.fingerprint == fingerprint,
              activeSubmissionIDs.contains(submissionID)
        else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }

        defer { activeSubmissionIDs.remove(submissionID) }
        var candidate = LedgerState(
            records: records,
            completedSubmissionIDs: completedSubmissionIDs
        )
        candidate.records.removeValue(forKey: submissionID)
        do {
            try Self.validate(candidate, limits: limits)
            if persistenceFault == .failAbort {
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            if let fileURL {
                try Self.persist(candidate, fileURL: fileURL, limits: limits)
            }
            let requestMapping = try Self.validatedRequestMapping(for: candidate.records)
            records = candidate.records
            completedSubmissionIDs = candidate.completedSubmissionIDs
            submissionIDByRequestID = requestMapping
        } catch {
            // Keep both the in-memory and durable reservation if deletion
            // cannot be committed. A retry must not silently bypass the ledger.
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
    }

    private func begin(
        operation: OperationKind,
        requestID: UUID?,
        submissionID: UUID,
        fingerprint: String
    ) throws -> BeginResult {
        guard !loadFailed, Self.isValidFingerprint(fingerprint) else {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
        if let requestID,
           let existingSubmissionID = submissionIDByRequestID[requestID],
           existingSubmissionID != submissionID
        {
            throw CodexConversationServiceError.idempotencyConflict
        }
        if let existing = records[submissionID] {
            guard existing.operation == operation,
                  existing.requestID == requestID,
                  existing.fingerprint == fingerprint
            else { throw CodexConversationServiceError.idempotencyConflict }
            switch existing.stage {
            case .prepared:
                return activeSubmissionIDs.contains(submissionID)
                    ? .inProgress
                    : .unknownAfterSideEffect
            case .completed:
                guard let threadID = existing.threadID,
                      let queuedSubmissionID = existing.queuedSubmissionID,
                      Self.isValidThreadID(threadID),
                      Self.isValidQueuedSubmissionID(queuedSubmissionID)
                else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
                return .completed(CodexConversationQueueReceipt(
                    submissionID: submissionID,
                    threadID: threadID,
                    queuedSubmissionID: queuedSubmissionID
                ))
            }
        }

        var candidate = LedgerState(
            records: records,
            completedSubmissionIDs: completedSubmissionIDs
        )
        candidate.records[submissionID] = Record(
            operation: operation,
            requestID: requestID,
            fingerprint: fingerprint,
            stage: .prepared,
            threadID: nil,
            queuedSubmissionID: nil
        )
        do {
            candidate = try Self.compacted(
                candidate,
                preservingCompleted: [],
                limits: limits
            )
            if let fileURL {
                try Self.persist(candidate, fileURL: fileURL, limits: limits)
            }
            records = candidate.records
            completedSubmissionIDs = candidate.completedSubmissionIDs
            submissionIDByRequestID = try Self.validatedRequestMapping(for: records)
            activeSubmissionIDs.insert(submissionID)
            return .new
        } catch {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
    }

    private static func load(fileURL: URL, limits: Limits) throws -> LoadedState {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let ownerID = attributes[.ownerAccountID] as? NSNumber,
              ownerID.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue >= 0,
              fileSize.intValue <= limits.maximumFileBytes
        else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
        if permissions.intValue & 0o077 != 0 {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= limits.maximumFileBytes else {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }

        if let decoded = try? JSONDecoder().decode(FileState.self, from: data) {
            guard decoded.version == currentVersion else {
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            var records: [UUID: Record] = [:]
            for persisted in decoded.records {
                guard records[persisted.submissionID] == nil else {
                    throw CodexConversationServiceError.idempotencyLedgerUnavailable
                }
                records[persisted.submissionID] = persisted.record
            }
            let state = LedgerState(
                records: records,
                completedSubmissionIDs: decoded.completedSubmissionIDs
            )
            try validate(state, limits: limits)
            return LoadedState(state: state, requiresMigration: false)
        }

        // Version 0 used a raw UUID-keyed dictionary. Migrate it once after
        // validating every record; completed IDs use UUID order so all hosts
        // make the same deterministic retention decision.
        let legacy = try JSONDecoder().decode([UUID: Record].self, from: data)
        _ = try validatedRequestMapping(for: legacy)
        let completed = legacy
            .filter { $0.value.stage == .completed }
            .map(\.key)
            .sorted(by: canonicalUUIDLessThan)
        let migrated = try compacted(
            LedgerState(records: legacy, completedSubmissionIDs: completed),
            preservingCompleted: [],
            limits: limits
        )
        return LoadedState(state: migrated, requiresMigration: true)
    }

    private static func validatedRequestMapping(
        for records: [UUID: Record]
    ) throws -> [UUID: UUID] {
        var requestMapping: [UUID: UUID] = [:]
        for (submissionID, record) in records {
            guard isValidFingerprint(record.fingerprint) else {
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            switch record.operation {
            case .existingConversation:
                guard record.requestID == nil else {
                    throw CodexConversationServiceError.idempotencyLedgerUnavailable
                }
            case .newConversation:
                guard let requestID = record.requestID,
                      requestMapping[requestID] == nil
                else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
                requestMapping[requestID] = submissionID
            }
            switch record.stage {
            case .prepared:
                guard record.threadID == nil, record.queuedSubmissionID == nil else {
                    throw CodexConversationServiceError.idempotencyLedgerUnavailable
                }
            case .completed:
                guard let threadID = record.threadID,
                      let queuedSubmissionID = record.queuedSubmissionID,
                      isValidThreadID(threadID),
                      isValidQueuedSubmissionID(queuedSubmissionID)
                else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
            }
        }
        return requestMapping
    }

    private static func validate(_ state: LedgerState, limits: Limits) throws {
        guard state.records.count <= limits.maximumRecordCount,
              Set(state.completedSubmissionIDs).count
                == state.completedSubmissionIDs.count
        else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
        _ = try validatedRequestMapping(for: state.records)
        let completedRecordIDs = Set(state.records.compactMap { submissionID, record in
            record.stage == .completed ? submissionID : nil
        })
        guard completedRecordIDs == Set(state.completedSubmissionIDs) else {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
    }

    private static func compacted(
        _ proposed: LedgerState,
        preservingCompleted: Set<UUID>,
        limits: Limits
    ) throws -> LedgerState {
        var candidate = proposed
        _ = try validatedRequestMapping(for: candidate.records)
        while true {
            let exceedsRecordLimit = candidate.records.count > limits.maximumRecordCount
            let exceedsFileLimit = try encoded(candidate).count > limits.maximumFileBytes
            guard exceedsRecordLimit || exceedsFileLimit else { break }
            guard let victimIndex = candidate.completedSubmissionIDs.firstIndex(where: {
                !preservingCompleted.contains($0)
            }) else {
                // Prepared entries are intentionally absent from the eviction
                // list: they may already have crossed a side-effect boundary.
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            let victim = candidate.completedSubmissionIDs.remove(at: victimIndex)
            guard candidate.records[victim]?.stage == .completed else {
                throw CodexConversationServiceError.idempotencyLedgerUnavailable
            }
            candidate.records.removeValue(forKey: victim)
        }
        try validate(candidate, limits: limits)
        return candidate
    }

    private static func encoded(_ state: LedgerState) throws -> Data {
        let persistedRecords = state.records
            .map { PersistedRecord(submissionID: $0.key, record: $0.value) }
            .sorted { canonicalUUIDLessThan($0.submissionID, $1.submissionID) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FileState(
            version: currentVersion,
            records: persistedRecords,
            completedSubmissionIDs: state.completedSubmissionIDs
        ))
    }

    private static func persist(
        _ state: LedgerState,
        fileURL: URL,
        limits: Limits
    ) throws {
        try validate(state, limits: limits)
        let data = try encoded(state)
        guard data.count <= limits.maximumFileBytes else {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let ownerID = attributes[.ownerAccountID] as? NSNumber,
              ownerID.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= limits.maximumFileBytes
        else { throw CodexConversationServiceError.idempotencyLedgerUnavailable }
    }

    private static func canonicalUUIDLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isValidThreadID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private static func isValidQueuedSubmissionID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= 128
            && trimmed.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

actor CodexConversationService {
    private static let maximumMessageBytes = 32 * 1_024

    private let client: CodexAppServerClient
    private let ledger: CodexConversationIdempotencyLedger
    private let fingerprintKey: SymmetricKey
    private let workspacesByID: [String: CodexWorkspaceDescriptor]
    private let workspaceOptions: [CodexWorkspaceOption]
    private var completedExistingSubmissions:
        CodexConversationCompletedSubmissionCache<CodexConversationQueueReceipt>
    private var completedNewSubmissions:
        CodexConversationCompletedSubmissionCache<CodexConversationStartAndQueueResult>

    init(
        client: CodexAppServerClient,
        workspaces: [CodexWorkspaceDescriptor],
        fingerprintKey: SymmetricKey,
        ledger: CodexConversationIdempotencyLedger = CodexConversationIdempotencyLedger(),
        maximumCompletedCacheCount: Int = 256
    ) throws {
        guard maximumCompletedCacheCount > 0 else {
            throw CodexConversationServiceError.invalidWorkspaceConfiguration
        }
        var descriptors: [String: CodexWorkspaceDescriptor] = [:]
        var options: [CodexWorkspaceOption] = []
        for workspace in workspaces {
            let id = workspace.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = workspace.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  !name.isEmpty,
                  descriptors[id] == nil,
                  workspace.directoryURL.isFileURL,
                  (workspace.directoryURL.path as NSString).isAbsolutePath
            else { throw CodexConversationServiceError.invalidWorkspaceConfiguration }
            let descriptor = CodexWorkspaceDescriptor(
                id: id,
                displayName: name,
                directoryURL: workspace.directoryURL.standardizedFileURL.resolvingSymlinksInPath(),
                projectID: workspace.projectID
            )
            descriptors[id] = descriptor
            options.append(CodexWorkspaceOption(id: id, displayName: name))
        }
        self.client = client
        self.ledger = ledger
        self.fingerprintKey = fingerprintKey
        completedExistingSubmissions = CodexConversationCompletedSubmissionCache(
            maximumCount: maximumCompletedCacheCount
        )
        completedNewSubmissions = CodexConversationCompletedSubmissionCache(
            maximumCount: maximumCompletedCacheCount
        )
        workspacesByID = descriptors
        workspaceOptions = options.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func availableWorkspaces() -> [CodexWorkspaceOption] {
        workspaceOptions
    }

    func catalog(limit: Int = 12) async throws -> CodexConversationCatalog {
        try await client.listThreads(limit: limit)
    }

    /// Mac-only catalog used by the destination authority. The safe `catalog`
    /// can cross devices; `localTargets` must remain inside the Bridge process.
    func catalogSnapshot(limit: Int = 12) async throws -> CodexConversationCatalogSnapshot {
        try await client.listThreadSnapshot(limit: limit)
    }

    func workspaceDescriptor(id: String) -> CodexWorkspaceDescriptor? {
        workspacesByID[id]
    }

    func submit(
        _ request: CodexExistingConversationSubmission
    ) async throws -> CodexConversationQueueReceipt {
        let threadID = try Self.validatedThreadID(request.threadID)
        let message = try Self.validatedMessage(request.message)
        let fingerprint = digest(["existing", threadID, message])
        if let cached = completedExistingSubmissions.entry(for: request.submissionID) {
            guard cached.fingerprint == fingerprint else {
                throw CodexConversationServiceError.idempotencyConflict
            }
            return cached.value
        }

        switch try await ledger.beginExisting(
            submissionID: request.submissionID,
            fingerprint: fingerprint
        ) {
        case .inProgress:
            throw CodexConversationServiceError.requestInProgress
        case .unknownAfterSideEffect:
            throw CodexConversationServiceError.outcomeUnknown
        case let .completed(receipt):
            completedExistingSubmissions.insert(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                value: receipt
            )
            return receipt
        case .new:
            break
        }

        let result: CodexConversationQueueReceipt
        do {
            result = try await client.queueMessage(
                threadID: threadID,
                message: message,
                submissionID: request.submissionID
            )
        } catch {
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
            throw CodexConversationServiceError.outcomeUnknown
        }

        completedExistingSubmissions.insert(
            submissionID: request.submissionID,
            fingerprint: fingerprint,
            value: result
        )
        do {
            try await ledger.complete(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                receipt: result
            )
        } catch {
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
        }
        return result
    }

    /// Transcribes Watch audio with Codex and queues text to one explicit thread.
    /// The durable fingerprint contains only an HMAC of the thread identifier
    /// and the recording digest; neither the file path nor audio bytes enter the
    /// idempotency ledger.
    func submitAudio(
        _ request: CodexExistingConversationAudioSubmission,
        validateBeforeQueue: @Sendable () async throws -> Void = {}
    ) async throws -> CodexConversationQueueReceipt {
        let threadID = try Self.validatedThreadID(request.threadID)
        let audioDigest = try Self.validatedAudioDigest(request.sha256Hex)
        let fingerprint = digest(["existingAudio", threadID, audioDigest])
        if let cached = completedExistingSubmissions.entry(for: request.submissionID) {
            guard cached.fingerprint == fingerprint else {
                throw CodexConversationServiceError.idempotencyConflict
            }
            return cached.value
        }

        switch try await ledger.beginExisting(
            submissionID: request.submissionID,
            fingerprint: fingerprint
        ) {
        case .inProgress:
            throw CodexConversationServiceError.requestInProgress
        case .unknownAfterSideEffect:
            throw CodexConversationServiceError.outcomeUnknown
        case let .completed(receipt):
            completedExistingSubmissions.insert(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                value: receipt
            )
            return receipt
        case .new:
            break
        }

        let result: CodexConversationQueueReceipt
        do {
            result = try await client.queueLocalAudio(
                threadID: threadID,
                fileURL: request.fileURL,
                submissionID: request.submissionID,
                validateBeforeQueue: validateBeforeQueue
            )
        } catch {
            if let knownNotQueued = error as? CodexNativeVoiceError {
                // queueLocalAudio emits this type only before queue/add. Do
                // not infer non-delivery from arbitrary transport failures.
                try await ledger.abortBeforeQueue(
                    submissionID: request.submissionID,
                    fingerprint: fingerprint
                )
                throw knownNotQueued
            }
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
            throw CodexConversationServiceError.outcomeUnknown
        }

        completedExistingSubmissions.insert(
            submissionID: request.submissionID,
            fingerprint: fingerprint,
            value: result
        )
        do {
            try await ledger.complete(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                receipt: result
            )
        } catch {
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
        }
        return result
    }

    func createConversationAndSubmit(
        _ request: CodexNewConversationSubmission
    ) async throws -> CodexConversationStartAndQueueResult {
        guard let workspace = workspacesByID[request.workspaceID] else {
            throw CodexConversationServiceError.unknownWorkspace
        }
        let message = try Self.validatedMessage(request.message)
        let fingerprint = digest([
            "new",
            request.requestID.uuidString.lowercased(),
            request.submissionID.uuidString.lowercased(),
            workspace.id,
            message,
        ])
        if let cached = completedNewSubmissions.entry(for: request.submissionID) {
            guard cached.fingerprint == fingerprint else {
                throw CodexConversationServiceError.idempotencyConflict
            }
            return cached.value
        }

        switch try await ledger.beginNew(
            requestID: request.requestID,
            submissionID: request.submissionID,
            fingerprint: fingerprint
        ) {
        case .inProgress:
            throw CodexConversationServiceError.requestInProgress
        case .unknownAfterSideEffect:
            throw CodexConversationServiceError.outcomeUnknown
        case let .completed(receipt):
            let restored = Self.restoredNewResult(receipt: receipt, workspace: workspace)
            completedNewSubmissions.insert(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                value: restored
            )
            return restored
        case .new:
            break
        }

        let result: CodexConversationStartAndQueueResult
        do {
            result = try await client.startThreadAndQueueMessage(
                in: workspace,
                message: message,
                submissionID: request.submissionID
            )
        } catch {
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
            throw CodexConversationServiceError.outcomeUnknown
        }

        completedNewSubmissions.insert(
            submissionID: request.submissionID,
            fingerprint: fingerprint,
            value: result
        )
        do {
            try await ledger.complete(
                submissionID: request.submissionID,
                fingerprint: fingerprint,
                receipt: result.receipt
            )
        } catch {
            await ledger.finishWithoutReceipt(
                submissionID: request.submissionID,
                fingerprint: fingerprint
            )
        }
        return result
    }

    private static func restoredNewResult(
        receipt: CodexConversationQueueReceipt,
        workspace: CodexWorkspaceDescriptor
    ) -> CodexConversationStartAndQueueResult {
        CodexConversationStartAndQueueResult(
            conversation: CodexConversationCatalogEntry(
                threadID: receipt.threadID,
                title: "Codex 会话",
                workspaceLabel: workspace.displayName,
                status: .idle,
                canAcceptDirectInput: nil,
                updatedAtEpochSeconds: 0
            ),
            receipt: receipt
        )
    }

    private static func validatedThreadID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: normalized),
              uuid.uuidString.lowercased() == normalized.lowercased()
        else { throw CodexConversationServiceError.invalidThreadID }
        return normalized.lowercased()
    }

    private static func validatedMessage(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumMessageBytes else {
            throw CodexConversationServiceError.invalidMessage
        }
        return trimmed
    }

    private static func validatedAudioDigest(_ value: String) throws -> String {
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw CodexConversationServiceError.invalidAudio }
        return value
    }

    private func digest(_ fields: [String]) -> String {
        let canonical = fields.joined(separator: "\u{1F}")
        return HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: fingerprintKey
        )
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

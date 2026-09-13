import Foundation

/// Mac-only request identity. The Watch supplies only an opaque target issued
/// by `CodexConversationAuthority`; it never supplies a local path.
struct WatchCodexConversationTargetSelectionRequest: Equatable, Sendable {
    let requestID: UUID
    let target: WatchCodexConversationTarget
}

@MainActor
enum CodexConversationTargetSelectionRouter {
    static func select(
        requestID: UUID,
        target: WatchCodexConversationTarget,
        coordinate: (WatchCodexConversationTargetSelectionRequest) async throws
            -> WatchCodexConversationTarget,
        isCreatedTargetInstalled: (WatchCodexConversationTarget) -> Bool,
        installCreatedTarget: (WatchCodexConversationTarget) -> Void
    ) async throws -> WatchCodexConversationTarget {
        let selected = try await coordinate(
            WatchCodexConversationTargetSelectionRequest(
                requestID: requestID,
                target: target
            )
        )
        if target.kind == .newConversation,
           !isCreatedTargetInstalled(selected) {
            installCreatedTarget(selected)
        }
        return selected
    }
}

enum CodexConversationTargetCoordinatorError: Error, Equatable, LocalizedError {
    case requestIdentityConflict
    case selectionLedgerUnavailable
    case outcomeUnknown
    case invalidResolvedTarget
    case invalidProvisionedWorkspace
    case invalidStartedConversation
    case invalidRegisteredConversation

    var errorDescription: String? {
        switch self {
        case .requestIdentityConflict:
            return "这次 Codex 选择请求已绑定到另一个目标。"
        case .selectionLedgerUnavailable:
            return "无法安全保存新会话创建状态；操作已停止。"
        case .outcomeUnknown:
            return "新会话创建结果暂时无法确认；为避免重复创建，已停止自动重试。"
        case .invalidResolvedTarget:
            return "Codex 会话目标无法安全解析。"
        case .invalidProvisionedWorkspace:
            return "Codex 独立工作区无法安全验证。"
        case .invalidStartedConversation:
            return "Codex 返回的新会话与所选工作区不一致。"
        case .invalidRegisteredConversation:
            return "Codex 新会话无法注册为可用目标。"
        }
    }
}

/// Minimal durable state for a new-conversation selection.
///
/// Only opaque identifiers are persisted. In particular, this file never
/// contains a workspace path, conversation title, transcript, or audio data.
@MainActor
final class CodexConversationTargetSelectionLedger {
    enum Stage: String, Codable, Equatable, Sendable {
        case starting
        case started
        case completed
    }

    struct Record: Codable, Equatable, Sendable {
        let operationID: UUID
        let workspaceID: String
        let stage: Stage
        let threadID: String?

        fileprivate var isValid: Bool {
            guard WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID) else {
                return false
            }
            switch stage {
            case .starting:
                return threadID == nil
            case .started, .completed:
                return CodexThreadIdentifier.isValid(threadID)
            }
        }
    }

    private struct FileState: Codable, Equatable {
        let version: Int
        var records: [Record]
    }

    private enum LedgerError: Error {
        case invalidState
        case capacityExceeded
        case unavailable
    }

    private static let currentVersion = 1
    private static let maximumRecordCount = 128
    private static let maximumFileBytes = 128 * 1_024

    private let fileURL: URL?
    private var cachedState: FileState?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    static func persistentDefault() -> CodexConversationTargetSelectionLedger {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return CodexConversationTargetSelectionLedger(
            fileURL: base
                .appendingPathComponent("WristRemoteBridge", isDirectory: true)
                .appendingPathComponent(
                    "CodexConversationTargetSelectionLedger.json",
                    isDirectory: false
                )
        )
    }

    func record(for operationID: UUID) throws -> Record? {
        try state().records.first { $0.operationID == operationID }
    }

    func markStarting(operationID: UUID, workspaceID: String) throws {
        var next = try state()
        guard WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID),
              !next.records.contains(where: { $0.operationID == operationID })
        else {
            throw LedgerError.invalidState
        }
        if next.records.count >= Self.maximumRecordCount {
            guard let completedIndex = next.records.firstIndex(where: {
                $0.stage == .completed
            }) else {
                // A starting/started record may describe an operation whose
                // side effect happened but whose result is still uncertain.
                // Never evict it merely to make room for another creation.
                throw LedgerError.capacityExceeded
            }
            // Records are append-only until completion, so removing the first
            // completed entry is a deterministic FIFO compaction policy.
            next.records.remove(at: completedIndex)
        }
        next.records.append(Record(
            operationID: operationID,
            workspaceID: workspaceID,
            stage: .starting,
            threadID: nil
        ))
        try install(next)
    }

    func markStarted(operationID: UUID, threadID: String) throws {
        try update(operationID: operationID, stage: .started, threadID: threadID)
    }

    func markCompleted(operationID: UUID, threadID: String) throws {
        try update(operationID: operationID, stage: .completed, threadID: threadID)
    }

    private func update(operationID: UUID, stage: Stage, threadID: String) throws {
        guard CodexThreadIdentifier.isValid(threadID) else {
            throw LedgerError.invalidState
        }
        var next = try state()
        guard let index = next.records.firstIndex(where: { $0.operationID == operationID })
        else { throw LedgerError.invalidState }
        let current = next.records[index]
        guard current.stage == .starting || current.threadID == threadID else {
            throw LedgerError.invalidState
        }
        next.records[index] = Record(
            operationID: operationID,
            workspaceID: current.workspaceID,
            stage: stage,
            threadID: threadID
        )
        try install(next)
    }

    private func state() throws -> FileState {
        if let cachedState { return cachedState }
        guard let fileURL else {
            let empty = FileState(version: Self.currentVersion, records: [])
            cachedState = empty
            return empty
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = FileState(version: Self.currentVersion, records: [])
            cachedState = empty
            return empty
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count <= Self.maximumFileBytes,
              let decoded = try? JSONDecoder().decode(FileState.self, from: data),
              decoded.version == Self.currentVersion,
              decoded.records.count <= Self.maximumRecordCount,
              Set(decoded.records.map(\.operationID)).count == decoded.records.count,
              decoded.records.allSatisfy(\.isValid)
        else { throw LedgerError.unavailable }
        cachedState = decoded
        return decoded
    }

    private func install(_ next: FileState) throws {
        guard next.version == Self.currentVersion,
              next.records.count <= Self.maximumRecordCount,
              Set(next.records.map(\.operationID)).count == next.records.count,
              next.records.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(next),
              data.count <= Self.maximumFileBytes
        else { throw LedgerError.invalidState }

        if let fileURL {
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
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                throw LedgerError.unavailable
            }
        }
        cachedState = next
    }
}

/// Coordinates one target-selection side effect while keeping all local paths
/// on the Mac. A request ID owns one retained Task for the lifetime of this
/// coordinator, so concurrent calls observe the exact same result. Durable
/// state handles retries after an ambiguous reply or a Bridge restart.
///
/// New conversations are created only through `thread/start`. No fork or
/// parent identifier is accepted or forwarded by this layer.
@MainActor
final class CodexConversationTargetCoordinator {
    struct CreatedConversationRegistration: Equatable, Sendable {
        let threadID: String
        let title: String
        let workspaceID: String
        let workspaceLabel: String
        let cwd: String
    }

    struct Dependencies {
        let resolveSelection:
            (WatchCodexConversationTarget) async throws -> ResolvedCodexConversationTarget
        let provisionWorkspace:
            (UUID, URL) async throws -> CodexProvisionedWorkspace
        let startThread:
            (CodexWorkspaceDescriptor) async throws -> CodexConversationStartResult
        let registerCreatedConversation:
            (CreatedConversationRegistration) async throws -> WatchCodexConversationTarget

        init(
            resolveSelection: @escaping
                (WatchCodexConversationTarget) async throws -> ResolvedCodexConversationTarget,
            provisionWorkspace: @escaping
                (UUID, URL) async throws -> CodexProvisionedWorkspace,
            startThread: @escaping
                (CodexWorkspaceDescriptor) async throws -> CodexConversationStartResult,
            registerCreatedConversation: @escaping
                (CreatedConversationRegistration) async throws -> WatchCodexConversationTarget
        ) {
            self.resolveSelection = resolveSelection
            self.provisionWorkspace = provisionWorkspace
            self.startThread = startThread
            self.registerCreatedConversation = registerCreatedConversation
        }
    }

    private struct CachedRequest {
        let target: WatchCodexConversationTarget
        let task: Task<WatchCodexConversationTarget, Error>
        let generation: UUID
        var isCompleted: Bool
    }

    private static let maximumPathBytes = 4_096

    private let dependencies: Dependencies
    private let selectionLedger: CodexConversationTargetSelectionLedger
    private var cachedRequests: [UUID: CachedRequest] = [:]

    init(
        dependencies: Dependencies,
        selectionLedger: CodexConversationTargetSelectionLedger? = nil
    ) {
        self.dependencies = dependencies
        self.selectionLedger = selectionLedger ?? CodexConversationTargetSelectionLedger()
    }

    convenience init(
        authority: CodexConversationAuthority,
        appServerClient: CodexAppServerClient,
        provisioner: CodexWorkspaceProvisioner = CodexWorkspaceProvisioner(),
        selectionLedger: CodexConversationTargetSelectionLedger? = nil
    ) {
        let provisioningWorker = CodexWorkspaceProvisioningWorker(provisioner: provisioner)
        self.init(dependencies: Dependencies(
            resolveSelection: { target in
                try await authority.resolveSelection(target)
            },
            provisionWorkspace: { requestID, recentDirectoryURL in
                try await provisioningWorker.provisionWorkspace(
                    for: requestID,
                    fromRecentThreadDirectory: recentDirectoryURL
                )
            },
            startThread: { workspace in
                try await appServerClient.startThread(in: workspace)
            },
            registerCreatedConversation: { registration in
                try await authority.registerCreatedConversation(
                    threadID: registration.threadID,
                    title: registration.title,
                    workspaceID: registration.workspaceID,
                    workspaceLabel: registration.workspaceLabel,
                    cwd: registration.cwd
                )
            }
        ), selectionLedger: selectionLedger
            ?? CodexConversationTargetSelectionLedger.persistentDefault())
    }

    func select(
        _ request: WatchCodexConversationTargetSelectionRequest
    ) async throws -> WatchCodexConversationTarget {
        if let cached = cachedRequests[request.requestID] {
            if cached.target != request.target {
                guard cached.isCompleted,
                      cached.target.kind == .newConversation,
                      request.target.kind == .newConversation,
                      cached.target.workspaceID == request.target.workspaceID
                else {
                    throw CodexConversationTargetCoordinatorError.requestIdentityConflict
                }
                cachedRequests.removeValue(forKey: request.requestID)
            } else {
                return try await cached.task.value
            }
        }

        let dependencies = dependencies
        let selectionLedger = selectionLedger
        let generation = UUID()
        let task = Task { @MainActor in
            try await Self.perform(
                request,
                dependencies: dependencies,
                selectionLedger: selectionLedger
            )
        }
        cachedRequests[request.requestID] = CachedRequest(
            target: request.target,
            task: task,
            generation: generation,
            isCompleted: false
        )
        do {
            let result = try await task.value
            if cachedRequests[request.requestID]?.generation == generation {
                cachedRequests[request.requestID]?.isCompleted = true
            }
            return result
        } catch {
            if request.target.kind == .newConversation,
               cachedRequests[request.requestID]?.generation == generation {
                cachedRequests.removeValue(forKey: request.requestID)
            }
            throw error
        }
    }

    private static func perform(
        _ request: WatchCodexConversationTargetSelectionRequest,
        dependencies: Dependencies,
        selectionLedger: CodexConversationTargetSelectionLedger
    ) async throws -> WatchCodexConversationTarget {
        switch request.target.kind {
        case .existing:
            let resolved = try await dependencies.resolveSelection(request.target)
            guard resolved.target == request.target else {
                throw CodexConversationTargetCoordinatorError.invalidResolvedTarget
            }
            guard resolved.threadID == request.target.threadID,
                  CodexThreadIdentifier.isValid(resolved.threadID)
            else {
                throw CodexConversationTargetCoordinatorError.invalidResolvedTarget
            }
            return resolved.target

        case .newConversation:
            let persisted: CodexConversationTargetSelectionLedger.Record?
            do {
                persisted = try selectionLedger.record(for: request.requestID)
            } catch {
                throw CodexConversationTargetCoordinatorError.selectionLedgerUnavailable
            }
            if let persisted {
                guard persisted.workspaceID == request.target.workspaceID else {
                    throw CodexConversationTargetCoordinatorError.requestIdentityConflict
                }
                if persisted.stage == .starting {
                    throw CodexConversationTargetCoordinatorError.outcomeUnknown
                }
            }

            let resolved = try await dependencies.resolveSelection(request.target)
            guard resolved.target == request.target else {
                throw CodexConversationTargetCoordinatorError.invalidResolvedTarget
            }
            guard resolved.threadID == nil,
                  let recentDirectoryURL = verifiedAbsolutePath(resolved.cwd)
            else {
                throw CodexConversationTargetCoordinatorError.invalidResolvedTarget
            }

            let provisioned = try await dependencies.provisionWorkspace(
                request.requestID,
                recentDirectoryURL
            )
            let executionDirectoryURL = try verifiedExecutionDirectory(provisioned)

            if let persisted,
               let threadID = persisted.threadID {
                return try await registerPersistedConversation(
                    request: request,
                    threadID: threadID,
                    cwd: executionDirectoryURL.path,
                    dependencies: dependencies,
                    selectionLedger: selectionLedger
                )
            }

            let workspace = CodexWorkspaceDescriptor(
                id: request.target.workspaceID,
                displayName: request.target.workspaceLabel,
                directoryURL: executionDirectoryURL,
                projectID: nil
            )
            do {
                try selectionLedger.markStarting(
                    operationID: request.requestID,
                    workspaceID: request.target.workspaceID
                )
            } catch {
                throw CodexConversationTargetCoordinatorError.selectionLedgerUnavailable
            }

            let started: CodexConversationStartResult
            do {
                started = try await dependencies.startThread(workspace)
            } catch {
                throw CodexConversationTargetCoordinatorError.outcomeUnknown
            }
            guard CodexThreadIdentifier.isValid(started.conversation.threadID),
                  started.conversation.workspaceLabel == request.target.workspaceLabel,
                  WatchCodexConversationWireValidation.isValidTitle(
                      started.conversation.title
                  ),
                  started.conversation.updatedAtEpochSeconds >= 0
            else {
                throw CodexConversationTargetCoordinatorError.outcomeUnknown
            }
            do {
                try selectionLedger.markStarted(
                    operationID: request.requestID,
                    threadID: started.conversation.threadID
                )
            } catch {
                throw CodexConversationTargetCoordinatorError.outcomeUnknown
            }

            return try await registerPersistedConversation(
                request: request,
                threadID: started.conversation.threadID,
                title: started.conversation.title,
                cwd: executionDirectoryURL.path,
                dependencies: dependencies,
                selectionLedger: selectionLedger
            )
        }
    }

    private static func registerPersistedConversation(
        request: WatchCodexConversationTargetSelectionRequest,
        threadID: String,
        title: String = "Codex 会话",
        cwd: String,
        dependencies: Dependencies,
        selectionLedger: CodexConversationTargetSelectionLedger
    ) async throws -> WatchCodexConversationTarget {
        let registration = CreatedConversationRegistration(
            threadID: threadID,
            title: title,
            workspaceID: request.target.workspaceID,
            workspaceLabel: request.target.workspaceLabel,
            cwd: cwd
        )
        let createdTarget: WatchCodexConversationTarget
        do {
            createdTarget = try await dependencies.registerCreatedConversation(registration)
        } catch {
            throw CodexConversationTargetCoordinatorError.outcomeUnknown
        }
        guard createdTarget.kind == .existing,
              createdTarget.threadID == threadID,
              createdTarget.workspaceID == request.target.workspaceID,
              createdTarget.workspaceLabel == request.target.workspaceLabel,
              createdTarget.serverEpoch == request.target.serverEpoch,
              createdTarget.catalogRevision == request.target.catalogRevision
        else {
            throw CodexConversationTargetCoordinatorError.outcomeUnknown
        }
        // A persisted `.started` record is already sufficient to prevent a
        // duplicate `thread/start`. Completion persistence is best-effort: a
        // successful registration must not be reported as failed solely due
        // to this bookkeeping write.
        try? selectionLedger.markCompleted(operationID: request.requestID, threadID: threadID)
        return createdTarget
    }

    private static func verifiedAbsolutePath(_ path: String) -> URL? {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              !path.contains("\0"),
              (path as NSString).isAbsolutePath
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func verifiedExecutionDirectory(
        _ provisioned: CodexProvisionedWorkspace
    ) throws -> URL {
        guard let canonicalRoot = verifiedDirectory(provisioned.canonicalRootURL),
              let executionDirectory = verifiedDirectory(provisioned.executionDirectoryURL)
        else {
            throw CodexConversationTargetCoordinatorError.invalidProvisionedWorkspace
        }
        if provisioned.usesDetachedWorktree {
            guard canonicalRoot != executionDirectory else {
                throw CodexConversationTargetCoordinatorError.invalidProvisionedWorkspace
            }
        } else {
            guard canonicalRoot == executionDirectory else {
                throw CodexConversationTargetCoordinatorError.invalidProvisionedWorkspace
            }
        }
        return executionDirectory
    }

    private static func verifiedDirectory(_ directoryURL: URL) -> URL? {
        guard directoryURL.isFileURL,
              (directoryURL.path as NSString).isAbsolutePath,
              directoryURL.path.utf8.count <= maximumPathBytes,
              !directoryURL.path.contains("\0")
        else { return nil }
        let resolved = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return resolved
    }
}

/// Runs synchronous Git/process work away from the main actor without exposing
/// the provisioner or local paths to the Watch-facing layer.
private actor CodexWorkspaceProvisioningWorker {
    private let provisioner: CodexWorkspaceProvisioner

    init(provisioner: CodexWorkspaceProvisioner) {
        self.provisioner = provisioner
    }

    func provisionWorkspace(
        for requestID: UUID,
        fromRecentThreadDirectory recentDirectoryURL: URL
    ) throws -> CodexProvisionedWorkspace {
        try provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: recentDirectoryURL
        )
    }
}

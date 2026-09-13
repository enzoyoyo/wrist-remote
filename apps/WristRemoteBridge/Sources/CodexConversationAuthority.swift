import CryptoKit
import Foundation

struct CodexConversationCatalogSeed: Equatable, Sendable {
    let threadID: String
    let cwd: String
    let title: String
    let workspaceLabel: String
    let state: WatchCodexConversationState
    let updatedAtEpochMilliseconds: Int64
    let canAcceptInput: Bool
    let workspaceID: String?

    init(
        threadID: String,
        cwd: String,
        title: String,
        workspaceLabel: String,
        state: WatchCodexConversationState,
        updatedAtEpochMilliseconds: Int64,
        canAcceptInput: Bool,
        workspaceID: String? = nil
    ) {
        self.threadID = threadID
        self.cwd = cwd
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.state = state
        self.updatedAtEpochMilliseconds = updatedAtEpochMilliseconds
        self.canAcceptInput = canAcceptInput
        self.workspaceID = workspaceID
    }
}

struct CodexConversationWorkspaceSeed: Equatable, Sendable {
    let cwd: String
    let workspaceLabel: String
    let workspaceID: String?

    init(cwd: String, workspaceLabel: String, workspaceID: String? = nil) {
        self.cwd = cwd
        self.workspaceLabel = workspaceLabel
        self.workspaceID = workspaceID
    }
}

struct ResolvedCodexConversationTarget: Equatable, Sendable {
    let target: WatchCodexConversationTarget
    let threadID: String?
    let cwd: String
}

enum CodexConversationAuthorityError: Error, Equatable, LocalizedError {
    case unavailable
    case workspaceCapacityReached
    case staleCatalog
    case invalidTarget
    case expiredTarget
    case invalidTranscript
    case invalidDraft
    case expiredDraft
    case draftContentMismatch
    case draftSubmissionMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Codex 会话目录暂不可用，请刷新后重试。"
        case .workspaceCapacityReached:
            return "工作区登记已满，无法新增目录；已有登记与文件保持不变。"
        case .staleCatalog:
            return "Codex 会话列表已更新，请重新选择发送目标。"
        case .invalidTarget:
            return "发送目标无效，请重新选择会话。"
        case .expiredTarget:
            return "发送目标已过期，请刷新会话列表。"
        case .invalidTranscript:
            return "语音草稿为空或过长，未发送。"
        case .invalidDraft:
            return "语音草稿身份无效，请重新录音。"
        case .expiredDraft:
            return "语音草稿已过期，请重新录音。"
        case .draftContentMismatch:
            return "草稿内容或发送目标已改变，请重新确认。"
        case .draftSubmissionMismatch:
            return "同一草稿不能改用另一个提交身份发送。"
        }
    }
}

/// Mac-authoritative destination and draft capability registry.
///
/// Working directories remain only in this actor. The Watch receives opaque,
/// short-lived capabilities containing display labels but no local paths.
actor CodexConversationAuthority {
    private struct Destination: Equatable, Sendable {
        let target: WatchCodexConversationTarget
        let threadID: String?
        let cwd: String
    }

    private struct DraftRecord: Sendable {
        let lease: WatchCodexDraftLease
        let transcriptDigest: String
        var submissionID: UUID?
    }

    static let targetLifetimeMilliseconds: Int64 = 15 * 60 * 1_000
    static let draftLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
    static let maximumExistingEntries = 12
    static let maximumNewConversationEntries = 4

    let serverEpoch: UUID
    private var catalogRevision = 0
    private var destinationsByLeaseID: [UUID: Destination] = [:]
    private var currentCatalog: WatchCodexConversationCatalog?
    private var draftsByID: [UUID: DraftRecord] = [:]
    private let workspaceIdentityStore: CodexWorkspaceIdentityStore
    private var workspaceIdentityState: CodexWorkspaceIdentityStore.State?

    init(
        serverEpoch: UUID = UUID(),
        workspaceIdentityStore: CodexWorkspaceIdentityStore = CodexWorkspaceIdentityStore()
    ) {
        self.serverEpoch = serverEpoch
        self.workspaceIdentityStore = workspaceIdentityStore
        self.workspaceIdentityState = try? workspaceIdentityStore.load()
    }

    func makeCatalog(
        existing seeds: [CodexConversationCatalogSeed],
        newConversationWorkspaces: [CodexConversationWorkspaceSeed],
        hasMore: Bool,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> WatchCodexConversationCatalog {
        guard nowEpochMilliseconds >= 0 else { throw CodexConversationAuthorityError.unavailable }
        guard workspaceIdentityState != nil else {
            throw CodexConversationAuthorityError.unavailable
        }
        pruneExpired(at: nowEpochMilliseconds)
        guard catalogRevision < Int.max else { throw CodexConversationAuthorityError.unavailable }
        let revision = catalogRevision + 1
        var pendingDestinations: [UUID: Destination] = [:]
        let expiry = nowEpochMilliseconds + Self.targetLifetimeMilliseconds

        // Register explicit roots before thread aliases. A detached worktree
        // must reuse the opaque identity of the root from which it was
        // provisioned, including after a Bridge restart.
        for seed in newConversationWorkspaces where !seed.cwd.isEmpty {
            _ = try workspaceID(
                for: seed.cwd,
                supplied: seed.workspaceID,
                preferCanonicalRoot: true
            )
        }

        let existing = seeds
            .filter { CodexThreadIdentifier.isValid($0.threadID) && !$0.cwd.isEmpty }
            .sorted { lhs, rhs in
                if lhs.updatedAtEpochMilliseconds == rhs.updatedAtEpochMilliseconds {
                    return lhs.threadID < rhs.threadID
                }
                return lhs.updatedAtEpochMilliseconds > rhs.updatedAtEpochMilliseconds
            }
            .prefix(Self.maximumExistingEntries)

        var entries: [WatchCodexConversationEntry] = []
        var workspaceLabelByID: [String: String] = [:]
        for seed in existing {
            let title = Self.displayTitle(seed.title, fallback: "Codex 会话")
            let workspace = Self.workspaceLabel(seed.workspaceLabel)
            let entryRevision = max(seed.updatedAtEpochMilliseconds, 0)
            let workspaceID = try workspaceID(
                for: seed.cwd,
                supplied: seed.workspaceID,
                preferCanonicalRoot: false
            )
            guard let target = WatchCodexConversationTarget(
                leaseID: UUID(),
                kind: .existing,
                serverEpoch: serverEpoch,
                catalogRevision: revision,
                entryRevision: entryRevision,
                threadID: seed.threadID,
                displayTitle: title,
                workspaceID: workspaceID,
                workspaceLabel: workspace,
                expiresAtEpochMilliseconds: expiry
            ), let entry = WatchCodexConversationEntry(
                threadID: seed.threadID,
                title: title,
                workspaceLabel: workspace,
                state: seed.state,
                updatedAtEpochMilliseconds: max(seed.updatedAtEpochMilliseconds, 0),
                canAcceptInput: seed.canAcceptInput,
                entryRevision: entryRevision,
                target: target
            ) else { continue }
            let destination = Destination(target: target, threadID: seed.threadID, cwd: seed.cwd)
            pendingDestinations[target.leaseID] = destination
            entries.append(entry)
            workspaceLabelByID[workspaceID] = workspace
        }

        // Only explicitly provisioned roots may be offered for a new task.
        // Reusing the cwd of a recent thread can silently put a supposedly new
        // task inside that thread's linked worktree, which makes it look and
        // behave like a branch of the previous task.
        var workspaceSeeds = newConversationWorkspaces
        let suppliedWorkspacePaths = Set(workspaceSeeds.map(\.cwd))
        if let state = workspaceIdentityState {
            for record in state.records where record.isCanonicalRoot {
                guard !suppliedWorkspacePaths.contains(record.cwd),
                      let workspaceLabel = workspaceLabelByID[record.workspaceID]
                else { continue }
                workspaceSeeds.append(CodexConversationWorkspaceSeed(
                    cwd: record.cwd,
                    workspaceLabel: workspaceLabel,
                    workspaceID: record.workspaceID
                ))
            }
        }
        var seenNewWorkspaces = Set<String>()
        var newEntryCount = 0
        for seed in workspaceSeeds where newEntryCount < Self.maximumNewConversationEntries {
            guard !seed.cwd.isEmpty else { continue }
            let workspace = Self.workspaceLabel(seed.workspaceLabel)
            let entryRevision = Int64(revision)
            let workspaceID = try workspaceID(
                for: seed.cwd,
                supplied: seed.workspaceID,
                preferCanonicalRoot: true
            )
            guard workspaceIdentityState?.canonicalCWD(for: workspaceID) == seed.cwd,
                  seenNewWorkspaces.insert(workspaceID).inserted,
                  let target = WatchCodexConversationTarget(
                leaseID: UUID(),
                kind: .newConversation,
                serverEpoch: serverEpoch,
                catalogRevision: revision,
                entryRevision: entryRevision,
                threadID: nil,
                displayTitle: workspaceID == WatchCodexConversationTarget.standaloneWorkspaceID
                    ? "全新空白任务" : "在项目中新建",
                workspaceID: workspaceID,
                workspaceLabel: workspace,
                expiresAtEpochMilliseconds: expiry
            ), let entry = WatchCodexConversationEntry(
                threadID: nil,
                title: target.displayTitle,
                workspaceLabel: workspace,
                state: .idle,
                updatedAtEpochMilliseconds: nowEpochMilliseconds,
                canAcceptInput: true,
                entryRevision: entryRevision,
                target: target
            ) else { continue }
            pendingDestinations[target.leaseID] = Destination(
                target: target,
                threadID: nil,
                cwd: seed.cwd
            )
            entries.append(entry)
            newEntryCount += 1
        }

        guard let catalog = WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: revision,
            entries: entries,
            hasMore: hasMore || seeds.count > Self.maximumExistingEntries,
            refreshedAtEpochMilliseconds: nowEpochMilliseconds
        ) else { throw CodexConversationAuthorityError.unavailable }
        // Commit only a completely built catalog. A failed refresh must not
        // invalidate the last published, still-unexpired capabilities.
        catalogRevision = revision
        destinationsByLeaseID.merge(pendingDestinations) { _, new in new }
        currentCatalog = catalog
        return catalog
    }

    func resolveSelection(
        _ target: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> ResolvedCodexConversationTarget {
        guard target.serverEpoch == serverEpoch else {
            throw CodexConversationAuthorityError.invalidTarget
        }
        guard target.catalogRevision == catalogRevision else {
            throw CodexConversationAuthorityError.staleCatalog
        }
        return try resolve(target, nowEpochMilliseconds: nowEpochMilliseconds)
    }

    func issueDraft(
        target: WatchCodexConversationTarget,
        transcript: String,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> WatchCodexDraftLease {
        guard target.kind == .existing else {
            throw CodexConversationAuthorityError.invalidTarget
        }
        _ = try resolveSelection(target, nowEpochMilliseconds: nowEpochMilliseconds)
        guard WatchCodexConversationWireValidation.isValidTranscript(transcript) else {
            throw CodexConversationAuthorityError.invalidTranscript
        }
        let expiresAt = min(
            target.expiresAtEpochMilliseconds,
            nowEpochMilliseconds + Self.draftLifetimeMilliseconds
        )
        guard let lease = WatchCodexDraftLease(
            draftID: UUID(),
            target: target,
            expiresAtEpochMilliseconds: expiresAt
        ) else { throw CodexConversationAuthorityError.invalidDraft }
        draftsByID[lease.draftID] = DraftRecord(
            lease: lease,
            transcriptDigest: Self.digest(transcript),
            submissionID: nil
        )
        return lease
    }

    /// Called only to finish a recording already accepted by resolveSelection.
    /// Resolve its original Mac-issued lease, never substitute a new thread.
    /// Removal, disabled input, epoch changes and expiry still fail closed.
    func resolveActiveRecording(
        _ target: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> ResolvedCodexConversationTarget {
        let resolved = try resolve(target, nowEpochMilliseconds: nowEpochMilliseconds)
        guard currentCatalog?.permitsContinuingVoice(
            for: target, nowEpochMilliseconds: nowEpochMilliseconds
        ) == true else { throw CodexConversationAuthorityError.invalidTarget }
        return resolved
    }

    func resolveDraftSubmission(
        draftID: UUID,
        target: WatchCodexConversationTarget,
        transcript: String,
        submissionID: UUID,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> ResolvedCodexConversationTarget {
        guard target.kind == .existing else {
            throw CodexConversationAuthorityError.invalidTarget
        }
        pruneExpired(at: nowEpochMilliseconds)
        guard var record = draftsByID[draftID], record.lease.target == target else {
            throw CodexConversationAuthorityError.invalidDraft
        }
        guard !record.lease.isExpired(atEpochMilliseconds: nowEpochMilliseconds) else {
            throw CodexConversationAuthorityError.expiredDraft
        }
        guard WatchCodexConversationWireValidation.isValidTranscript(transcript),
              record.transcriptDigest == Self.digest(transcript)
        else { throw CodexConversationAuthorityError.draftContentMismatch }
        if let existingSubmissionID = record.submissionID,
           existingSubmissionID != submissionID {
            throw CodexConversationAuthorityError.draftSubmissionMismatch
        }
        record.submissionID = submissionID
        draftsByID[draftID] = record
        return try resolve(target, nowEpochMilliseconds: nowEpochMilliseconds)
    }

    /// Issues an immediate existing-thread capability after `thread/start` and
    /// `thread/queue/add` have succeeded. Catalog refresh is deliberately not
    /// part of the send acknowledgement: a slow list request must never turn
    /// an already queued user message into an apparent failure.
    func registerCreatedConversation(
        threadID: String,
        title: String,
        workspaceID: String,
        workspaceLabel: String,
        cwd: String,
        nowEpochMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> WatchCodexConversationTarget {
        guard CodexThreadIdentifier.isValid(threadID),
              !cwd.isEmpty,
              WatchCodexConversationWireValidation.isValidWorkspaceID(workspaceID),
              nowEpochMilliseconds >= 0,
              catalogRevision > 0
        else { throw CodexConversationAuthorityError.invalidTarget }
        let authoritativeWorkspaceID = try self.workspaceID(
            for: cwd,
            supplied: workspaceID,
            preferCanonicalRoot: false
        )
        guard authoritativeWorkspaceID == workspaceID else {
            throw CodexConversationAuthorityError.invalidTarget
        }
        pruneExpired(at: nowEpochMilliseconds)
        let entryRevision = nowEpochMilliseconds
        guard let target = WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: catalogRevision,
            entryRevision: entryRevision,
            threadID: threadID,
            displayTitle: Self.displayTitle(title, fallback: "Codex 会话"),
            workspaceID: workspaceID,
            workspaceLabel: Self.workspaceLabel(workspaceLabel),
            expiresAtEpochMilliseconds: nowEpochMilliseconds
                + Self.targetLifetimeMilliseconds
        ) else { throw CodexConversationAuthorityError.invalidTarget }
        destinationsByLeaseID[target.leaseID] = Destination(
            target: target,
            threadID: threadID,
            cwd: cwd
        )
        currentCatalog = currentCatalog?.installingImmediatelyCreatedConversation(
            target, nowEpochMilliseconds: nowEpochMilliseconds
        )
        return target
    }

    private func resolve(
        _ target: WatchCodexConversationTarget,
        nowEpochMilliseconds: Int64
    ) throws -> ResolvedCodexConversationTarget {
        guard target.serverEpoch == serverEpoch,
              let destination = destinationsByLeaseID[target.leaseID],
              destination.target == target
        else { throw CodexConversationAuthorityError.invalidTarget }
        guard !target.isExpired(atEpochMilliseconds: nowEpochMilliseconds) else {
            destinationsByLeaseID.removeValue(forKey: target.leaseID)
            throw CodexConversationAuthorityError.expiredTarget
        }
        return ResolvedCodexConversationTarget(
            target: target,
            threadID: destination.threadID,
            cwd: destination.cwd
        )
    }

    private func pruneExpired(at nowEpochMilliseconds: Int64) {
        destinationsByLeaseID = destinationsByLeaseID.filter {
            !$0.value.target.isExpired(atEpochMilliseconds: nowEpochMilliseconds)
        }
        draftsByID = draftsByID.filter {
            !$0.value.lease.isExpired(atEpochMilliseconds: nowEpochMilliseconds)
        }
    }

    private static func digest(_ transcript: String) -> String {
        SHA256.hash(data: Data(transcript.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func workspaceID(
        for cwd: String,
        supplied: String?,
        preferCanonicalRoot: Bool
    ) throws -> String {
        guard var state = workspaceIdentityState else {
            throw CodexConversationAuthorityError.unavailable
        }
        if let existing = state.workspaceID(for: cwd) {
            // The owner-only persistent registry is authoritative. A newly
            // derived path hash for a managed worktree must never replace it.
            if preferCanonicalRoot {
                do {
                    let changed = try state.register(
                        cwd: cwd,
                        workspaceID: existing,
                        preferCanonicalRoot: true
                    )
                    if changed { try workspaceIdentityStore.save(state) }
                    workspaceIdentityState = state
                } catch {
                    workspaceIdentityState = nil
                    throw CodexConversationAuthorityError.unavailable
                }
            }
            return existing
        }
        let identifier: String
        if let supplied {
            guard WatchCodexConversationWireValidation.isValidWorkspaceID(supplied) else {
                throw CodexConversationAuthorityError.invalidTarget
            }
            identifier = supplied
        } else {
            identifier = "workspace-\(UUID().uuidString.lowercased())"
        }
        do {
            let changed = try state.register(
                cwd: cwd,
                workspaceID: identifier,
                preferCanonicalRoot: preferCanonicalRoot
            )
            if changed { try workspaceIdentityStore.save(state) }
        } catch CodexWorkspaceIdentityStore.StoreError.capacityExceeded {
            // Capacity is not corruption. Preserve known identities so later
            // catalogs and selections for existing roots can still succeed.
            throw CodexConversationAuthorityError.workspaceCapacityReached
        } catch {
            workspaceIdentityState = nil
            throw CodexConversationAuthorityError.unavailable
        }
        workspaceIdentityState = state
        return identifier
    }

    private static func displayTitle(_ raw: String, fallback: String) -> String {
        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let candidate = normalized.isEmpty ? fallback : normalized
        return candidate.utf8.count <= 320 ? candidate : String(candidate.prefix(80)) + "…"
    }

    private static func workspaceLabel(_ raw: String) -> String {
        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let fallback = normalized.isEmpty ? "Mac 工作区" : normalized
        return fallback.utf8.count <= 240 ? fallback : String(fallback.prefix(60)) + "…"
    }
}

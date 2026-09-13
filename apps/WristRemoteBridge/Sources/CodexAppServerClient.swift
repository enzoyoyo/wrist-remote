import Darwin
import Foundation

enum CodexExecutableLocator {
    static var defaultExecutableURL: URL {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "WristRemoteCodexExecutablePath"
        ) as? String
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [String?] = [
            configured,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (trimmed as NSString).isAbsolutePath,
                  FileManager.default.isExecutableFile(atPath: trimmed)
            else { continue }
            return URL(fileURLWithPath: trimmed)
        }
        return URL(fileURLWithPath: "/nonexistent/wrist-remote-codex")
    }
}

enum CodexConversationRuntimeStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case unavailable
}

struct CodexConversationCatalogEntry: Codable, Equatable, Sendable {
    let threadID: String
    let title: String
    let workspaceLabel: String
    let status: CodexConversationRuntimeStatus
    let canAcceptDirectInput: Bool?
    let updatedAtEpochSeconds: Int64
}

struct CodexConversationCatalog: Codable, Equatable, Sendable {
    let conversations: [CodexConversationCatalogEntry]
    let hasMore: Bool
}

/// Mac-only routing material. This type is deliberately not Codable and is
/// never part of the Watch wire protocol.
struct CodexConversationLocalTarget: Equatable, Sendable {
    let conversation: CodexConversationCatalogEntry
    let directoryURL: URL
}

struct CodexConversationCatalogSnapshot: Equatable, Sendable {
    let catalog: CodexConversationCatalog
    let localTargets: [CodexConversationLocalTarget]
}

struct CodexWorkspaceDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let directoryURL: URL
    let projectID: String?

    init(id: String, displayName: String, directoryURL: URL, projectID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.directoryURL = directoryURL
        self.projectID = projectID
    }
}

struct CodexConversationStartResult: Equatable, Sendable {
    let conversation: CodexConversationCatalogEntry
}

struct CodexConversationQueueReceipt: Equatable, Sendable {
    let submissionID: UUID
    let threadID: String
    let queuedSubmissionID: String
}

struct CodexConversationStartAndQueueResult: Equatable, Sendable {
    let conversation: CodexConversationCatalogEntry
    let receipt: CodexConversationQueueReceipt
}

/// A privacy-preserving summary of the input capabilities advertised by the
/// local Codex model catalog. Model identifiers and other catalog metadata are
/// deliberately not retained or returned by this probe.
struct CodexModelAudioInputCapability: Equatable, Sendable {
    let supportsAudioInput: Bool
    let checkedModelCount: Int
}

enum CodexAppServerClientError: Error, Equatable, LocalizedError {
    case invalidExecutable
    case invalidLimit
    case invalidWorkspace
    case invalidThreadID
    case invalidMessage
    case invalidAudio
    case processUnavailable
    case processTimedOut
    case outputTooLarge
    case invalidProtocolResponse
    case serverRejected

    var errorDescription: String? {
        switch self {
        case .invalidExecutable:
            return "Codex 本地服务程序不可用。"
        case .invalidLimit:
            return "Codex 会话列表请求无效。"
        case .invalidWorkspace:
            return "Codex 工作区不可用。"
        case .invalidThreadID:
            return "Codex 会话标识无效。"
        case .invalidMessage:
            return "Codex 消息为空或过长。"
        case .invalidAudio:
            return "Codex 原始录音无效或超出安全限制。"
        case .processUnavailable:
            return "Codex 本地服务未能启动。"
        case .processTimedOut:
            return "Codex 本地服务响应超时。"
        case .outputTooLarge:
            return "Codex 本地服务返回了异常大小的数据。"
        case .invalidProtocolResponse:
            return "Codex 本地服务返回了无法验证的结果。"
        case .serverRejected:
            return "Codex 本地服务拒绝了这次操作。"
        }
    }
}

actor CodexAppServerClient {
    struct Limits: Equatable, Sendable {
        var responseTimeoutSeconds: Double = 5
        // Legacy audio notifications inline base64. Keep finite limits that
        // accommodate the accepted 8 MiB recording and a few related events.
        var maximumLineBytes: Int = 16 * 1_024 * 1_024
        var maximumStandardOutputBytes: Int = 64 * 1_024 * 1_024
        var maximumStandardErrorBytes: Int = 64 * 1_024
        var maximumMessageBytes: Int = 32 * 1_024
        var maximumLocalAudioBytes: Int = 8 * 1_024 * 1_024

        fileprivate var isValid: Bool {
            responseTimeoutSeconds > 0
                && maximumLineBytes >= 128
                && maximumStandardOutputBytes >= maximumLineBytes
                && maximumStandardErrorBytes >= 128
                && maximumMessageBytes >= 1
                && maximumLocalAudioBytes >= 44
        }
    }

    private let executableURL: URL
    private let limits: Limits
    private let voiceTranscriber: CodexNativeVoiceTranscriber
    private var session: CodexAppServerSession?
    // An empty thread is loaded before it is persisted in thread/list. Keep
    // only threads this client actually created, and revalidate their loaded
    // identities on every refresh. This is not a fallback for deleted history.
    private var unlistedCreatedTargets: [String: CodexConversationLocalTarget] = [:]

    init(
        executableURL: URL,
        limits: Limits = Limits(),
        voiceTranscriber: CodexNativeVoiceTranscriber = CodexNativeVoiceTranscriber()
    ) {
        self.executableURL = executableURL
        self.limits = limits
        self.voiceTranscriber = voiceTranscriber
    }

    func listThreads(limit: Int = 12) async throws -> CodexConversationCatalog {
        try await listThreadSnapshot(limit: limit).catalog
    }

    func listThreadSnapshot(limit: Int = 12) async throws -> CodexConversationCatalogSnapshot {
        guard (1...12).contains(limit) else { throw CodexAppServerClientError.invalidLimit }
        return try withSession { session in
            let result = try session.request(method: "thread/list", params: [
                "limit": limit,
                "archived": false,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
            ])
            let snapshot = try Self.parseCatalogSnapshot(result, requestedLimit: limit)
            let listedIDs = Set(snapshot.localTargets.map { $0.conversation.threadID })
            unlistedCreatedTargets = unlistedCreatedTargets.filter {
                !listedIDs.contains($0.key)
            }
            guard !unlistedCreatedTargets.isEmpty else { return snapshot }
            let loadedResult = try session.request(method: "thread/loaded/list", params: [:])
            guard let loadedIDs = loadedResult["data"] as? [String],
                  loadedIDs.count <= 256,
                  loadedIDs.allSatisfy({ CodexThreadIdentifier.isValid($0) }),
                  Set(loadedIDs).count == loadedIDs.count
            else { throw CodexAppServerClientError.invalidProtocolResponse }
            let loaded = Set(loadedIDs.map { $0.lowercased() })
            unlistedCreatedTargets = unlistedCreatedTargets.filter { loaded.contains($0.key) }
            let combined = (Array(unlistedCreatedTargets.values) + snapshot.localTargets).sorted {
                if $0.conversation.updatedAtEpochSeconds == $1.conversation.updatedAtEpochSeconds {
                    return $0.conversation.threadID < $1.conversation.threadID
                }
                return $0.conversation.updatedAtEpochSeconds > $1.conversation.updatedAtEpochSeconds
            }
            let targets = Array(combined.prefix(limit))
            return CodexConversationCatalogSnapshot(
                catalog: CodexConversationCatalog(
                    conversations: targets.map(\.conversation),
                    hasMore: snapshot.catalog.hasMore || combined.count > limit
                ),
                localTargets: targets
            )
        }
    }

    func startThread(in workspace: CodexWorkspaceDescriptor) async throws -> CodexConversationStartResult {
        let descriptor = try Self.verifiedWorkspace(workspace)
        return try withSession { session in
            let result = try session.request(
                method: "thread/start",
                params: Self.threadStartParameters(for: descriptor)
            )
            let conversation = try Self.parseStartedConversation(result, workspace: descriptor)
            rememberUnlistedCreation(conversation, in: descriptor)
            return CodexConversationStartResult(conversation: conversation)
        }
    }

    func queueMessage(
        threadID: String,
        message: String,
        submissionID: UUID
    ) async throws -> CodexConversationQueueReceipt {
        let validatedThreadID = try Self.verifiedThreadID(threadID)
        let validatedMessage = try verifiedMessage(message)
        return try withSession { session in
            return try Self.queueMessage(
                validatedMessage,
                threadID: validatedThreadID,
                submissionID: submissionID,
                using: session
            )
        }
    }

    /// Uses Codex's native transcription service, then queues its text to the
    /// exact selected thread. No localAudio model input or blind queue/start.
    func queueLocalAudio(
        threadID: String,
        fileURL: URL,
        submissionID: UUID,
        validateBeforeQueue: @Sendable () async throws -> Void = {}
    ) async throws -> CodexConversationQueueReceipt {
        let validatedThreadID: String
        let validatedMessage: String
        do {
            try Task.checkCancellation()
            validatedThreadID = try Self.verifiedThreadID(threadID)
            let validatedFileURL = try verifiedLocalAudioURL(fileURL)
            let startingSession = try initializedSession()
            let authentication = try withSession { session in
                try CodexNativeVoiceAuthentication(response: session.request(
                    method: "getAuthStatus", params: ["includeToken": true, "refreshToken": false]
                ))
            }
            let audio = try Data(contentsOf: validatedFileURL)
            let transcript = try await voiceTranscriber.transcribe(audio: audio, authentication: authentication)
            validatedMessage = try verifiedMessage(transcript)
            try Task.checkCancellation()
            try await validateBeforeQueue()
            try Task.checkCancellation()
            guard session === startingSession else { throw CodexNativeVoiceError.targetChanged }
        } catch is CancellationError {
            throw CodexNativeVoiceError.cancelled
        } catch let error as CodexNativeVoiceError {
            throw error
        } catch let error as CodexAppServerClientError {
            switch error {
            case .invalidAudio: throw CodexNativeVoiceError.invalidRecording
            case .invalidThreadID: throw CodexNativeVoiceError.targetChanged
            case .invalidMessage: throw CodexNativeVoiceError.responseTooLarge
            default: throw CodexNativeVoiceError.unavailable
            }
        } catch {
            throw CodexNativeVoiceError.unavailable
        }
        return try withSession { session in
            // This check is still before queue/add; later transport failures
            // must remain untyped/uncertain so the service cannot release them.
            if Task.isCancelled { throw CodexNativeVoiceError.cancelled }
            return try Self.queueMessage(
                validatedMessage,
                threadID: validatedThreadID,
                submissionID: submissionID,
                using: session
            )
        }
    }

    func startThreadAndQueueMessage(
        in workspace: CodexWorkspaceDescriptor,
        message: String,
        submissionID: UUID
    ) async throws -> CodexConversationStartAndQueueResult {
        let descriptor = try Self.verifiedWorkspace(workspace)
        let validatedMessage = try verifiedMessage(message)
        return try withSession { session in
            let startResult = try session.request(
                method: "thread/start",
                params: Self.threadStartParameters(for: descriptor)
            )
            let conversation = try Self.parseStartedConversation(startResult, workspace: descriptor)
            rememberUnlistedCreation(conversation, in: descriptor)
            let receipt = try Self.queueMessage(
                validatedMessage,
                threadID: conversation.threadID,
                submissionID: submissionID,
                using: session
            )
            return CodexConversationStartAndQueueResult(
                conversation: conversation,
                receipt: receipt
            )
        }
    }

    func probeAudioInputCapability() async throws -> CodexModelAudioInputCapability {
        try withSession { session in
            var cursor: String?
            var seenCursors = Set<String>()
            var supportsAudioInput = false
            var checkedModelCount = 0
            var pageCount = 0

            repeat {
                pageCount += 1
                guard pageCount <= 8 else {
                    throw CodexAppServerClientError.invalidProtocolResponse
                }
                var params: [String: Any] = [
                    "limit": 100,
                    "includeHidden": false,
                ]
                if let cursor {
                    params["cursor"] = cursor
                }
                let result = try session.request(method: "model/list", params: params)
                let page = try Self.parseAudioCapabilityPage(result, requestedLimit: 100)
                supportsAudioInput = supportsAudioInput || page.supportsAudioInput
                checkedModelCount += page.modelCount
                guard checkedModelCount <= 800 else {
                    throw CodexAppServerClientError.invalidProtocolResponse
                }
                if let nextCursor = page.nextCursor {
                    guard seenCursors.insert(nextCursor).inserted else {
                        throw CodexAppServerClientError.invalidProtocolResponse
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil

            return CodexModelAudioInputCapability(
                supportsAudioInput: supportsAudioInput,
                checkedModelCount: checkedModelCount
            )
        }
    }

    /// Executes exactly once on the current initialized process. Any transport
    /// or validation failure invalidates that process so a later, separate API
    /// call may rebuild it; this method never replays the failed operation.
    private func withSession<Result>(
        _ operation: (CodexAppServerSession) throws -> Result
    ) throws -> Result {
        let activeSession = try initializedSession()
        do {
            return try operation(activeSession)
        } catch {
            // A well-formed business rejection is not a broken transport.
            // Preserve loaded blank tasks; never replay the failed operation.
            if (error as? CodexAppServerClientError) == .serverRejected
                || error is CodexNativeVoiceError || error is CancellationError {
                throw error
            }
            if session === activeSession {
                session = nil
                unlistedCreatedTargets.removeAll()
            }
            activeSession.stop()
            throw error
        }
    }

    private func rememberUnlistedCreation(
        _ conversation: CodexConversationCatalogEntry,
        in workspace: CodexWorkspaceDescriptor
    ) {
        unlistedCreatedTargets[conversation.threadID] = CodexConversationLocalTarget(
            conversation: conversation, directoryURL: workspace.directoryURL
        )
        let newest = unlistedCreatedTargets.values.sorted {
            if $0.conversation.updatedAtEpochSeconds == $1.conversation.updatedAtEpochSeconds {
                return $0.conversation.threadID > $1.conversation.threadID
            }
            return $0.conversation.updatedAtEpochSeconds > $1.conversation.updatedAtEpochSeconds
        }.prefix(12)
        unlistedCreatedTargets = Dictionary(uniqueKeysWithValues: newest.map {
            ($0.conversation.threadID, $0)
        })
    }

    private func initializedSession() throws -> CodexAppServerSession {
        if let session {
            return session
        }
        let newSession = try CodexAppServerSession(
            executableURL: Self.verifiedExecutableURL(executableURL),
            limits: verifiedLimits()
        )
        do {
            try newSession.initialize()
        } catch {
            newSession.stop()
            throw error
        }
        session = newSession
        return newSession
    }

    private func verifiedLimits() throws -> Limits {
        guard limits.isValid else { throw CodexAppServerClientError.invalidProtocolResponse }
        return limits
    }

    private func verifiedMessage(_ message: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limits.maximumMessageBytes else {
            throw CodexAppServerClientError.invalidMessage
        }
        return trimmed
    }

    private func verifiedLocalAudioURL(_ fileURL: URL) throws -> URL {
        guard fileURL.isFileURL else { throw CodexAppServerClientError.invalidAudio }
        let standardized = fileURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard (standardized.path as NSString).isAbsolutePath,
              standardized.path == resolved.path,
              standardized.pathExtension.lowercased() == "wav"
        else { throw CodexAppServerClientError.invalidAudio }
        do {
            let values = try standardized.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  (44 ... limits.maximumLocalAudioBytes).contains(fileSize)
            else { throw CodexAppServerClientError.invalidAudio }
        } catch let error as CodexAppServerClientError {
            throw error
        } catch {
            throw CodexAppServerClientError.invalidAudio
        }
        return standardized
    }

    private static func verifiedExecutableURL(_ candidate: URL) throws -> URL {
        guard candidate.isFileURL,
              (candidate.path as NSString).isAbsolutePath
        else { throw CodexAppServerClientError.invalidExecutable }

        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved.path)
        else { throw CodexAppServerClientError.invalidExecutable }
        return resolved
    }

    private static func verifiedWorkspace(_ workspace: CodexWorkspaceDescriptor) throws
        -> CodexWorkspaceDescriptor
    {
        let id = sanitizedLabel(workspace.id, fallback: "")
        let displayName = sanitizedLabel(workspace.displayName, fallback: "")
        guard !id.isEmpty,
              !displayName.isEmpty,
              workspace.directoryURL.isFileURL,
              (workspace.directoryURL.path as NSString).isAbsolutePath
        else { throw CodexAppServerClientError.invalidWorkspace }

        let resolved = workspace.directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw CodexAppServerClientError.invalidWorkspace }

        let projectID = workspace.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexWorkspaceDescriptor(
            id: id,
            displayName: displayName,
            directoryURL: resolved,
            projectID: projectID?.isEmpty == false ? projectID : nil
        )
    }

    private static func verifiedThreadID(_ threadID: String) throws -> String {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: normalized),
              uuid.uuidString.lowercased() == normalized.lowercased()
        else { throw CodexAppServerClientError.invalidThreadID }
        return normalized.lowercased()
    }

    private static func threadStartParameters(for workspace: CodexWorkspaceDescriptor) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": workspace.directoryURL.path,
            "ephemeral": false,
            "sessionStartSource": "startup",
            "threadSource": "wristRemote",
            "projectId": workspace.projectID as Any? ?? NSNull(),
        ]
        if let projectID = workspace.projectID {
            params["projectId"] = projectID
        }
        return params
    }

    private static func queueMessage(
        _ message: String,
        threadID: String,
        submissionID: UUID,
        using session: CodexAppServerSession
    ) throws -> CodexConversationQueueReceipt {
        try queueInput(
            [[
                "type": "text",
                "text": message,
            ]],
            threadID: threadID,
            submissionID: submissionID,
            using: session
        )
    }

    private static func queueInput(
        _ input: [[String: Any]],
        threadID: String,
        submissionID: UUID,
        using session: CodexAppServerSession
    ) throws -> CodexConversationQueueReceipt {
        let result = try session.request(method: "thread/queue/add", params: [
            "threadId": threadID,
            "clientUserMessageId": submissionID.uuidString.lowercased(),
            "input": input,
        ])
        guard let queued = result["queuedSubmission"] as? [String: Any],
              let queuedID = boundedIdentifier(queued["id"]),
              let echoedClientID = boundedIdentifier(queued["clientUserMessageId"]),
              echoedClientID.lowercased() == submissionID.uuidString.lowercased()
        else { throw CodexAppServerClientError.invalidProtocolResponse }
        return CodexConversationQueueReceipt(
            submissionID: submissionID,
            threadID: threadID,
            queuedSubmissionID: queuedID
        )
    }

    private static func parseCatalogSnapshot(
        _ result: [String: Any],
        requestedLimit: Int
    ) throws -> CodexConversationCatalogSnapshot {
        guard let rawThreads = result["data"] as? [[String: Any]],
              rawThreads.count <= requestedLimit
        else { throw CodexAppServerClientError.invalidProtocolResponse }
        let localTargets = try rawThreads.map { raw -> CodexConversationLocalTarget in
            guard let cwd = raw["cwd"] as? String, (cwd as NSString).isAbsolutePath else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            return CodexConversationLocalTarget(
                conversation: try parseConversation(raw),
                directoryURL: URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
            )
        }
        let nextCursor = result["nextCursor"] as? String
        return CodexConversationCatalogSnapshot(
            catalog: CodexConversationCatalog(
                conversations: localTargets.map(\.conversation),
                hasMore: nextCursor?.isEmpty == false
            ),
            localTargets: localTargets
        )
    }

    private static func parseAudioCapabilityPage(
        _ result: [String: Any],
        requestedLimit: Int
    ) throws -> (supportsAudioInput: Bool, modelCount: Int, nextCursor: String?) {
        guard let rawModels = result["data"] as? [[String: Any]],
              rawModels.count <= requestedLimit
        else { throw CodexAppServerClientError.invalidProtocolResponse }

        var supportsAudioInput = false
        for rawModel in rawModels {
            guard let rawModalities = rawModel["inputModalities"] else {
                // Older app-server versions omit the schema's default
                // text/image modalities. Omission therefore never implies
                // audio support.
                continue
            }
            guard let modalities = rawModalities as? [String],
                  modalities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 })
            else { throw CodexAppServerClientError.invalidProtocolResponse }
            supportsAudioInput = supportsAudioInput || modalities.contains("audio")
        }

        let nextCursor: String?
        if result["nextCursor"] == nil || result["nextCursor"] is NSNull {
            nextCursor = nil
        } else {
            nextCursor = try verifiedCursor(result["nextCursor"])
        }
        return (supportsAudioInput, rawModels.count, nextCursor)
    }

    private static func parseStartedConversation(
        _ result: [String: Any],
        workspace: CodexWorkspaceDescriptor
    ) throws -> CodexConversationCatalogEntry {
        guard let rawThread = result["thread"] as? [String: Any] else {
            throw CodexAppServerClientError.invalidProtocolResponse
        }
        try validateIndependentStartedThread(rawThread, workspace: workspace)
        return try parseConversation(rawThread, workspaceLabelOverride: workspace.displayName)
    }

    private static func validateIndependentStartedThread(
        _ rawThread: [String: Any],
        workspace: CodexWorkspaceDescriptor
    ) throws {
        if let sessionID = rawThread["sessionId"] {
            guard let sessionID = sessionID as? String,
                  let threadID = rawThread["id"] as? String,
                  sessionID == threadID
            else { throw CodexAppServerClientError.invalidProtocolResponse }
        }
        if let turns = rawThread["turns"] {
            guard let turns = turns as? [Any], turns.isEmpty else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
        }
        if let preview = rawThread["preview"] {
            guard let preview = preview as? String,
                  preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw CodexAppServerClientError.invalidProtocolResponse }
        }
        guard isAbsentOrNull(rawThread["forkedFromId"]),
              isAbsentOrNull(rawThread["parentThreadId"]),
              let responseCWD = rawThread["cwd"] as? String,
              responseCWD == workspace.directoryURL.path,
              (responseCWD as NSString).isAbsolutePath,
              URL(fileURLWithPath: responseCWD, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path == responseCWD,
              rawThread.keys.contains("projectId")
        else { throw CodexAppServerClientError.invalidProtocolResponse }

        if let requestedProjectID = workspace.projectID {
            guard rawThread["projectId"] as? String == requestedProjectID else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
        } else {
            guard rawThread["projectId"] is NSNull else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
        }
    }

    private static func parseConversation(_ raw: [String: Any]) throws
        -> CodexConversationCatalogEntry
    {
        try parseConversation(raw, workspaceLabelOverride: nil)
    }

    private static func parseConversation(
        _ raw: [String: Any],
        workspaceLabelOverride: String?
    ) throws -> CodexConversationCatalogEntry {
        guard let rawID = raw["id"] as? String else {
            throw CodexAppServerClientError.invalidProtocolResponse
        }
        let threadID = try verifiedThreadID(rawID)
        let title = sanitizedLabel(raw["name"] as? String, fallback: "Codex 会话")
        let workspaceLabel: String
        if let workspaceLabelOverride {
            workspaceLabel = sanitizedLabel(workspaceLabelOverride, fallback: "工作区")
        } else if let cwd = raw["cwd"] as? String, (cwd as NSString).isAbsolutePath {
            workspaceLabel = sanitizedLabel(
                URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent,
                fallback: "工作区"
            )
        } else {
            workspaceLabel = "工作区"
        }

        guard let statusObject = raw["status"] as? [String: Any],
              let statusType = statusObject["type"] as? String,
              let updatedAt = integerValue(raw["updatedAt"])
        else { throw CodexAppServerClientError.invalidProtocolResponse }

        let status: CodexConversationRuntimeStatus
        switch statusType {
        case "idle":
            status = .idle
        case "active":
            status = .running
        case "notLoaded", "systemError":
            status = .unavailable
        default:
            throw CodexAppServerClientError.invalidProtocolResponse
        }

        let canAcceptDirectInput: Bool?
        if raw["canAcceptDirectInput"] is NSNull || raw["canAcceptDirectInput"] == nil {
            canAcceptDirectInput = nil
        } else if let value = raw["canAcceptDirectInput"] as? Bool {
            canAcceptDirectInput = value
        } else {
            throw CodexAppServerClientError.invalidProtocolResponse
        }

        return CodexConversationCatalogEntry(
            threadID: threadID,
            title: title,
            workspaceLabel: workspaceLabel,
            status: status,
            canAcceptDirectInput: canAcceptDirectInput,
            updatedAtEpochSeconds: updatedAt
        )
    }

    private static func boundedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func verifiedCursor(_ value: Any?) throws -> String {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw CodexAppServerClientError.invalidProtocolResponse }
        return value
    }

    private static func isAbsentOrNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func integerValue(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int64.min),
              doubleValue <= Double(Int64.max)
        else { return nil }
        return number.int64Value
    }

    private static func sanitizedLabel(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let collapsed = value
            .unicodeScalars
            .map {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0) ? " " : String($0)
            }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(80))
    }
}

private final class CodexAppServerSession {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let limits: CodexAppServerClient.Limits
    private let errorDrain: CodexDiscardingErrorDrain
    private var outputBuffer = Data()
    private var requestOutputBytes = 0
    private var nextRequestID = 1
    private var stopped = false

    init(executableURL: URL, limits: CodexAppServerClient.Limits) throws {
        self.limits = limits
        errorDrain = CodexDiscardingErrorDrain(limit: limits.maximumStandardErrorBytes)
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = CodexAppServerLaunchContext.environment(
            from: ProcessInfo.processInfo.environment
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [errorDrain, weak process] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if !errorDrain.consume(chunk) {
                process?.terminate()
            }
        }
        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerClientError.processUnavailable
        }
    }

    deinit {
        stop()
    }

    func initialize() throws {
        let response = try request(method: "initialize", params: [
            "clientInfo": [
                "name": "wrist-remote-bridge",
                "title": "Wrist Remote Bridge",
                "version": "1",
            ],
            "capabilities": [
                "experimentalApi": true,
            ],
        ])
        _ = response
        try sendJSON([
            "method": "initialized",
        ])
    }

    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        guard !stopped, process.isRunning else {
            throw CodexAppServerClientError.processUnavailable
        }
        requestOutputBytes = outputBuffer.count
        guard requestOutputBytes <= limits.maximumStandardOutputBytes else {
            throw CodexAppServerClientError.outputTooLarge
        }
        let requestID = nextRequestID
        nextRequestID += 1
        try sendJSON([
            "id": requestID,
            "method": method,
            "params": params,
        ])

        let deadline = Date().addingTimeInterval(limits.responseTimeoutSeconds)
        while true {
            let line = try readLine(deadline: deadline)
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: line)
            } catch {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            guard let dictionary = object as? [String: Any] else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            guard let responseID = (dictionary["id"] as? NSNumber)?.intValue else {
                if dictionary["method"] is String { continue }
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            guard responseID == requestID else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            if dictionary["error"] != nil {
                throw CodexAppServerClientError.serverRejected
            }
            guard let result = dictionary["result"] as? [String: Any] else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            return result
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    private func sendJSON(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerClientError.invalidProtocolResponse
        }
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw CodexAppServerClientError.invalidProtocolResponse
        }
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexAppServerClientError.processUnavailable
        }
    }

    private func readLine(deadline: Date) throws -> Data {
        while true {
            if let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer[..<newlineIndex]
                outputBuffer.removeSubrange(...newlineIndex)
                guard !line.isEmpty, line.count <= limits.maximumLineBytes else {
                    throw line.count > limits.maximumLineBytes
                        ? CodexAppServerClientError.outputTooLarge
                        : CodexAppServerClientError.invalidProtocolResponse
                }
                return Data(line)
            }
            guard outputBuffer.count <= limits.maximumLineBytes else {
                throw CodexAppServerClientError.outputTooLarge
            }
            guard !errorDrain.didOverflow else {
                throw CodexAppServerClientError.outputTooLarge
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexAppServerClientError.processTimedOut }
            var descriptor = pollfd(
                fd: outputPipe.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let timeoutMilliseconds = Int32(max(1, min(250, Int(remaining * 1_000))))
            let pollResult = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if pollResult == 0 { continue }
            guard pollResult > 0 else {
                if errno == EINTR { continue }
                throw CodexAppServerClientError.processUnavailable
            }

            var bytes = [UInt8](repeating: 0, count: 8 * 1_024)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 {
                throw CodexAppServerClientError.processUnavailable
            }
            guard count > 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexAppServerClientError.processUnavailable
            }
            requestOutputBytes += count
            guard requestOutputBytes <= limits.maximumStandardOutputBytes else {
                throw CodexAppServerClientError.outputTooLarge
            }
            outputBuffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

enum CodexAppServerLaunchContext {
    static func environment(from inherited: [String: String]) -> [String: String] {
        var result = inherited
        // Preserve the user's login/configuration, not the launching task's identity.
        for key in ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_TURN_ID",
                    "CODEX_PARENT_THREAD_ID", "CODEX_PARENT_SESSION_ID"] {
            result.removeValue(forKey: key)
        }
        return result
    }
}

private final class CodexDiscardingErrorDrain: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var byteCount = 0
    private var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return false }
        guard byteCount + data.count <= limit else {
            overflowed = true
            return false
        }
        byteCount += data.count
        return true
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }
}

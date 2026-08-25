import AppKit
import Foundation

struct CodexReplyRequest: Equatable, Sendable {
    let submissionID: UUID
    let threadID: String
    let turnID: String
    let cwd: String
    let transcript: String
    let userConfirmed: Bool
}

struct CodexReplyResult: Equatable, Sendable {
    enum DeliveryState: Equatable, Sendable {
        case delivered
        case queued
    }

    let submissionID: UUID
    let threadID: String
    let queuedMessageID: UUID
    let observedTurnID: String?
    let state: DeliveryState
}

struct CodexProcessInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let standardInput: Data
}

struct CodexProcessOutput: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

enum CodexReplyRunnerError: Error, Equatable, LocalizedError {
    case confirmationRequired
    case invalidTranscript
    case invalidExecutable
    case taskIsNotExactCurrentCompletion
    case alreadyRunning
    case processFailed(Int32, String)
    case processTimedOut
    case outputTooLarge
    case invalidProcessOutput
    case queuedWrongThread
    case submissionIDReuseMismatch
    case submissionOutcomeUnknown
    case idempotencyLedgerUnavailable
    case invalidThreadID

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "The Watch transcript must be confirmed before it is sent."
        case .invalidTranscript:
            return "The confirmed transcript is empty or too long."
        case .invalidExecutable:
            return "The Codex executable must be an absolute executable path."
        case .taskIsNotExactCurrentCompletion:
            return "The selected thread, turn, and working directory are not the current completed task."
        case .alreadyRunning:
            return "Another confirmed Codex reply is already running."
        case let .processFailed(status, detail):
            return "Codex exited with status \(status): \(detail)"
        case .processTimedOut:
            return "Codex did not accept the queued message before the safe timeout."
        case .outputTooLarge:
            return "Codex produced more output than the bridge accepts."
        case .invalidProcessOutput:
            return "Codex did not confirm that the message entered the thread queue."
        case .queuedWrongThread:
            return "Codex queued the message for a different thread."
        case .submissionIDReuseMismatch:
            return "The Codex submission identifier was reused for different content."
        case .submissionOutcomeUnknown:
            return "这条语音可能已经进入 Codex；为避免重复发送，请先查看当前聊天。"
        case .idempotencyLedgerUnavailable:
            return "无法安全记录本次发送；为避免重复消息，Codex 投递已停止。"
        case .invalidThreadID:
            return "Codex 当前聊天标识不是可安全投递的 UUID。"
        }
    }
}

actor CodexReplyRunner {
    typealias ExecutionHandler = @Sendable (CodexProcessInvocation) async throws -> CodexProcessOutput
    typealias OpenThreadHandler = @Sendable (String) async -> Bool

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
    static let maximumTranscriptBytes = 32 * 1_024
    static let maximumCachedSubmissions = 64

    private struct CachedSubmission: Sendable {
        let request: CodexReplyRequest
        let result: CodexReplyResult
    }

    private let coordinator: CodexTaskCoordinator
    private let executableURL: URL
    private let execute: ExecutionHandler
    private let openThread: OpenThreadHandler
    private let submissionLedger: CodexSubmissionLedger
    private var isRunning = false
    private var cachedSubmissions: [UUID: CachedSubmission] = [:]
    private var cachedSubmissionOrder: [UUID] = []

    init(
        coordinator: CodexTaskCoordinator,
        executableURL: URL = CodexReplyRunner.defaultExecutableURL,
        submissionLedger: CodexSubmissionLedger = CodexSubmissionLedger(),
        execute: @escaping ExecutionHandler = { invocation in
            try await CodexSubprocessExecutor.run(invocation)
        },
        openThread: @escaping OpenThreadHandler = { threadID in
            await MainActor.run {
                guard let url = URL(string: "codex://threads/\(threadID)") else { return false }
                return NSWorkspace.shared.open(url)
            }
        }
    ) {
        self.coordinator = coordinator
        self.executableURL = executableURL
        self.submissionLedger = submissionLedger
        self.execute = execute
        self.openThread = openThread
    }

    func submit(_ request: CodexReplyRequest) async throws -> CodexReplyResult {
        guard request.userConfirmed else { throw CodexReplyRunnerError.confirmationRequired }
        guard !request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.transcript.utf8.count <= Self.maximumTranscriptBytes
        else { throw CodexReplyRunnerError.invalidTranscript }
        guard executableURL.isFileURL,
              (executableURL.path as NSString).isAbsolutePath
        else { throw CodexReplyRunnerError.invalidExecutable }
        guard let threadUUID = UUID(uuidString: request.threadID),
              threadUUID.uuidString.lowercased() == request.threadID.lowercased()
        else { throw CodexReplyRunnerError.invalidThreadID }
        if let cached = cachedSubmissions[request.submissionID] {
            guard cached.request == request else {
                throw CodexReplyRunnerError.submissionIDReuseMismatch
            }
            return cached.result
        }
        guard await coordinator.exactCurrentCompletedSnapshot(
            threadID: request.threadID,
            turnID: request.turnID,
            cwd: request.cwd
        ) != nil else {
            throw CodexReplyRunnerError.taskIsNotExactCurrentCompletion
        }
        guard !isRunning else { throw CodexReplyRunnerError.alreadyRunning }

        let canonicalCWD = try CodexHookPayload.canonicalDirectoryPath(request.cwd)
        switch try await submissionLedger.begin(request) {
        case .new:
            break
        case .unknownAfterSideEffect:
            throw CodexReplyRunnerError.submissionOutcomeUnknown
        case let .completed(result):
            cache(result, for: request)
            return result
        }

        isRunning = true
        defer { isRunning = false }

        let invocation = CodexProcessInvocation(
            executableURL: executableURL,
            arguments: [
                "queue",
                "--thread", request.threadID,
                "--message", request.transcript,
            ],
            currentDirectoryURL: URL(fileURLWithPath: canonicalCWD, isDirectory: true),
            standardInput: Data()
        )
        let output = try await execute(invocation)
        guard output.terminationStatus == 0 else {
            let detail = String(decoding: output.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexReplyRunnerError.processFailed(output.terminationStatus, detail)
        }
        let parsed = try CodexQueueConfirmation.parse(output.standardOutput)
        guard parsed.threadID == request.threadID else {
            throw CodexReplyRunnerError.queuedWrongThread
        }
        let result = CodexReplyResult(
            submissionID: request.submissionID,
            threadID: request.threadID,
            queuedMessageID: parsed.messageID,
            observedTurnID: nil,
            state: .queued
        )
        try await submissionLedger.complete(result, request: request)
        cache(result, for: request)
        _ = await openThread(request.threadID)
        return result
    }

    private func cache(_ result: CodexReplyResult, for request: CodexReplyRequest) {
        cachedSubmissions[request.submissionID] = CachedSubmission(
            request: request,
            result: result
        )
        cachedSubmissionOrder.removeAll { $0 == request.submissionID }
        cachedSubmissionOrder.append(request.submissionID)
        if cachedSubmissionOrder.count > Self.maximumCachedSubmissions {
            let overflow = cachedSubmissionOrder.count - Self.maximumCachedSubmissions
            let removed = Array(cachedSubmissionOrder.prefix(overflow))
            cachedSubmissionOrder.removeFirst(overflow)
            removed.forEach { cachedSubmissions.removeValue(forKey: $0) }
        }
    }
}

private struct CodexQueueConfirmation {
    let messageID: UUID
    let threadID: String

    static func parse(_ data: Data) throws -> CodexQueueConfirmation {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 6,
                  parts[0] == "Queued",
                  parts[1] == "message",
                  let messageID = UUID(uuidString: String(parts[2])),
                  parts[3] == "for",
                  parts[4] == "thread"
            else { continue }
            let rawThreadID = String(parts[5])
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard UUID(uuidString: rawThreadID)?.uuidString.lowercased()
                    == rawThreadID.lowercased()
            else { continue }
            return CodexQueueConfirmation(messageID: messageID, threadID: rawThreadID)
        }
        throw CodexReplyRunnerError.invalidProcessOutput
    }
}

private enum CodexSubprocessExecutor {
    static let maximumStandardOutputBytes = 2 * 1_024 * 1_024
    static let maximumStandardErrorBytes = 128 * 1_024
    static let processTimeoutSeconds: Double = 5

    static func run(_ invocation: CodexProcessInvocation) async throws -> CodexProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw CodexReplyRunnerError.invalidExecutable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errorPipe = Pipe()
            let outputBuffer = CodexBoundedDataBuffer(limit: maximumStandardOutputBytes)
            let errorBuffer = CodexBoundedDataBuffer(limit: maximumStandardErrorBytes)
            let lifetime = CodexProcessLifetime()

            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.currentDirectoryURL = invocation.currentDirectoryURL
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorPipe

            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if !outputBuffer.append(chunk) { process.terminate() }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if !errorBuffer.append(chunk) { process.terminate() }
            }
            process.terminationHandler = { process in
                let didTimeOut = lifetime.finish()
                output.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                _ = outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
                _ = errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

                if didTimeOut {
                    continuation.resume(throwing: CodexReplyRunnerError.processTimedOut)
                } else if outputBuffer.didOverflow || errorBuffer.didOverflow {
                    continuation.resume(throwing: CodexReplyRunnerError.outputTooLarge)
                } else {
                    continuation.resume(returning: CodexProcessOutput(
                        terminationStatus: process.terminationStatus,
                        standardOutput: outputBuffer.data,
                        standardError: errorBuffer.data
                    ))
                }
            }

            let timeoutItem = DispatchWorkItem {
                guard process.isRunning else { return }
                lifetime.markTimedOut()
                process.terminate()
            }
            lifetime.install(timeoutItem)

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + processTimeoutSeconds,
                    execute: timeoutItem
                )
                input.fileHandleForWriting.write(invocation.standardInput)
                try? input.fileHandleForWriting.close()
            } catch {
                _ = lifetime.finish()
                process.terminationHandler = nil
                output.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class CodexProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var timeoutItem: DispatchWorkItem?
    private var timedOut = false

    func install(_ item: DispatchWorkItem) {
        lock.lock()
        timeoutItem = item
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        timeoutItem = nil
        lock.unlock()
    }

    func finish() -> Bool {
        lock.lock()
        let item = timeoutItem
        timeoutItem = nil
        let result = timedOut
        lock.unlock()
        item?.cancel()
        return result
    }
}

private final class CodexBoundedDataBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()
    private var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    @discardableResult
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return false }
        guard storage.count + chunk.count <= limit else {
            overflowed = true
            return false
        }
        storage.append(chunk)
        return true
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }
}

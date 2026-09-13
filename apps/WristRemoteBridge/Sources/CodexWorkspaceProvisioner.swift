import Darwin
import Foundation

struct CodexProvisionedWorkspace: Equatable, Sendable {
    let canonicalRootURL: URL
    let executionDirectoryURL: URL
    let usesDetachedWorktree: Bool
}

enum CodexWorkspaceProvisionerError: Error, Equatable, LocalizedError {
    case invalidLimits
    case invalidRecentThreadDirectory
    case invalidApplicationSupportDirectory
    case invalidGitExecutable
    case processUnavailable
    case processTimedOut
    case outputTooLarge
    case gitCommandFailed
    case invalidGitOutput
    case unsafeManagedStorage
    case worktreeCollision
    case worktreeCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "Codex 工作区隔离参数无效。"
        case .invalidRecentThreadDirectory:
            return "最近会话的工作区不可用。"
        case .invalidApplicationSupportDirectory:
            return "App 支持目录不可用。"
        case .invalidGitExecutable:
            return "系统 Git 不可用。"
        case .processUnavailable:
            return "无法启动本地 Git 检查。"
        case .processTimedOut:
            return "本地 Git 检查超时。"
        case .outputTooLarge:
            return "本地 Git 返回了异常大小的数据。"
        case .gitCommandFailed:
            return "无法验证 Git 工作区。"
        case .invalidGitOutput:
            return "Git 工作区信息无法验证。"
        case .unsafeManagedStorage:
            return "隔离工作区目录不安全。"
        case .worktreeCollision:
            return "隔离工作区目标已被其他内容占用。"
        case .worktreeCreationFailed:
            return "无法创建独立的 Git 工作区。"
        }
    }
}

/// Resolves a recent Codex thread directory back to its canonical workspace and,
/// for Git projects, provisions an idempotent detached worktree for a new request.
///
/// The provisioner only writes below its own Application Support directory. It
/// never reads or mutates remote-control, audio-routing, or microphone settings.
struct CodexWorkspaceProvisioner {
    struct Limits: Equatable, Sendable {
        var processTimeoutSeconds: Double = 8
        var maximumStandardOutputBytes: Int = 128 * 1_024
        var maximumStandardErrorBytes: Int = 16 * 1_024
        var maximumPathBytes: Int = 4_096
        var maximumArgumentBytes: Int = 16 * 1_024

        fileprivate var isValid: Bool {
            processTimeoutSeconds >= 0.05
                && processTimeoutSeconds <= 30
                && maximumStandardOutputBytes >= 1
                && maximumStandardOutputBytes <= 1 * 1_024 * 1_024
                && maximumStandardErrorBytes >= 1
                && maximumStandardErrorBytes <= 256 * 1_024
                && maximumPathBytes >= 128
                && maximumPathBytes <= 16 * 1_024
                && maximumArgumentBytes >= 256
                && maximumArgumentBytes <= 64 * 1_024
        }
    }

    private static let productDirectoryName = "WristRemoteBridge"
    private static let worktreeDirectoryName = "CodexWorktrees"
    private static let standaloneDirectoryName = "CodexStandaloneTasks"
    private static let standaloneReceiptDirectoryName = "CodexStandaloneReceipts"

    private let applicationSupportDirectoryURL: URL
    private let gitExecutableURL: URL
    private let limits: Limits

    init(
        applicationSupportDirectoryURL: URL = Self.defaultApplicationSupportDirectoryURL,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        limits: Limits = Limits()
    ) {
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
        self.gitExecutableURL = gitExecutableURL
        self.limits = limits
    }

    func provisionWorkspace(
        for requestID: UUID,
        fromRecentThreadDirectory recentThreadDirectoryURL: URL
    ) throws -> CodexProvisionedWorkspace {
        guard limits.isValid else { throw CodexWorkspaceProvisionerError.invalidLimits }
        let recentDirectory = try verifiedExistingDirectory(
            recentThreadDirectoryURL,
            error: .invalidRecentThreadDirectory
        )
        if recentDirectory == standaloneRootURL {
            return try provisionStandaloneWorkspace(for: requestID)
        }
        let gitContext = try resolveGitContext(from: recentDirectory)
        guard let gitContext else {
            return CodexProvisionedWorkspace(
                canonicalRootURL: recentDirectory,
                executionDirectoryURL: recentDirectory,
                usesDetachedWorktree: false
            )
        }

        let managedRoot = try prepareManagedRoot()
        let target = managedRoot.appendingPathComponent(
            requestID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        guard target.deletingLastPathComponent() == managedRoot,
              isValidPath(target.path)
        else { throw CodexWorkspaceProvisionerError.unsafeManagedStorage }

        if let existing = gitContext.worktrees.first(where: { $0.directoryURL == target }) {
            return try reuseVerifiedWorktree(
                existing,
                target: target,
                canonicalRoot: gitContext.canonicalRootURL
            )
        }
        guard !pathEntryExists(target) else {
            throw CodexWorkspaceProvisionerError.worktreeCollision
        }

        let creation = try runGit([
            "-C", gitContext.canonicalRootURL.path,
            "worktree", "add", "--detach", target.path, "HEAD",
        ])
        if creation.terminationStatus != 0 {
            // A concurrent retry may have completed the same deterministic add.
            if let refreshed = try? listedWorktrees(from: gitContext.canonicalRootURL),
               let existing = refreshed.first(where: { $0.directoryURL == target })
            {
                return try reuseVerifiedWorktree(
                    existing,
                    target: target,
                    canonicalRoot: gitContext.canonicalRootURL
                )
            }
            throw CodexWorkspaceProvisionerError.worktreeCreationFailed
        }

        try makePrivateDirectory(target, mayCreate: false)
        let refreshed = try listedWorktrees(from: gitContext.canonicalRootURL)
        guard let created = refreshed.first(where: { $0.directoryURL == target }) else {
            throw CodexWorkspaceProvisionerError.worktreeCreationFailed
        }
        return try reuseVerifiedWorktree(
            created,
            target: target,
            canonicalRoot: gitContext.canonicalRootURL
        )
    }

    private static var defaultApplicationSupportDirectoryURL: URL {
        if let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return directory
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private func resolveGitContext(from recentDirectory: URL) throws -> GitContext? {
        let topLevelResult = try runGit([
            "-C", recentDirectory.path,
            "rev-parse", "--path-format=absolute", "--show-toplevel",
        ])
        guard topLevelResult.terminationStatus == 0 else {
            if containsGitMarker(atOrAbove: recentDirectory) {
                throw CodexWorkspaceProvisionerError.gitCommandFailed
            }
            return nil
        }
        let currentTopLevel = try parseSinglePath(topLevelResult.standardOutput)
        let worktrees = try listedWorktrees(from: recentDirectory)
        guard let main = worktrees.first,
              !main.isBare,
              pathEntryExists(main.directoryURL),
              worktrees.contains(where: { $0.directoryURL == currentTopLevel })
        else { throw CodexWorkspaceProvisionerError.invalidGitOutput }
        let canonicalRoot = try verifiedExistingDirectory(
            main.directoryURL,
            error: .invalidGitOutput
        )
        return GitContext(canonicalRootURL: canonicalRoot, worktrees: worktrees)
    }

    private func listedWorktrees(from directoryURL: URL) throws -> [GitWorktreeRecord] {
        let result = try runGit([
            "-C", directoryURL.path,
            "worktree", "list", "--porcelain", "-z",
        ])
        guard result.terminationStatus == 0 else {
            throw CodexWorkspaceProvisionerError.gitCommandFailed
        }
        return try parseWorktreeListing(result.standardOutput)
    }

    private func parseWorktreeListing(_ data: Data) throws -> [GitWorktreeRecord] {
        guard !data.isEmpty, data.last == 0 else {
            throw CodexWorkspaceProvisionerError.invalidGitOutput
        }
        var records: [GitWorktreeRecord] = []
        var builder: GitWorktreeBuilder?
        for fieldBytes in data.split(separator: 0, omittingEmptySubsequences: false) {
            if fieldBytes.isEmpty {
                if let completed = try builder?.build() {
                    records.append(completed)
                    builder = nil
                }
                continue
            }
            guard let field = String(data: Data(fieldBytes), encoding: .utf8),
                  field.utf8.count <= limits.maximumPathBytes + 128
            else { throw CodexWorkspaceProvisionerError.invalidGitOutput }

            if field.hasPrefix("worktree ") {
                guard builder == nil else {
                    throw CodexWorkspaceProvisionerError.invalidGitOutput
                }
                let path = String(field.dropFirst("worktree ".count))
                let directoryURL = try canonicalPathURL(path)
                builder = GitWorktreeBuilder(directoryURL: directoryURL)
            } else {
                guard var current = builder else {
                    throw CodexWorkspaceProvisionerError.invalidGitOutput
                }
                switch field {
                case "bare":
                    current.isBare = true
                case "detached":
                    current.isDetached = true
                case "prunable":
                    current.isPrunable = true
                default:
                    if field.hasPrefix("HEAD ") {
                        guard current.head == nil else {
                            throw CodexWorkspaceProvisionerError.invalidGitOutput
                        }
                        current.head = String(field.dropFirst("HEAD ".count))
                    } else if field.hasPrefix("branch ") {
                        guard current.branch == nil else {
                            throw CodexWorkspaceProvisionerError.invalidGitOutput
                        }
                        current.branch = String(field.dropFirst("branch ".count))
                    } else if field == "locked" || field.hasPrefix("locked ") {
                        current.isLocked = true
                    } else if field.hasPrefix("prunable ") {
                        current.isPrunable = true
                    }
                }
                builder = current
            }
        }
        if let completed = try builder?.build() {
            records.append(completed)
        }
        guard !records.isEmpty,
              Set(records.map(\.directoryURL)).count == records.count
        else { throw CodexWorkspaceProvisionerError.invalidGitOutput }
        return records
    }

    private func reuseVerifiedWorktree(
        _ record: GitWorktreeRecord,
        target: URL,
        canonicalRoot: URL
    ) throws -> CodexProvisionedWorkspace {
        guard record.directoryURL == target,
              record.isDetached,
              !record.isBare,
              !record.isPrunable,
              record.head != nil,
              pathEntryExists(target)
        else { throw CodexWorkspaceProvisionerError.worktreeCollision }
        let verifiedTarget = try verifiedExistingDirectory(target, error: .worktreeCollision)
        guard verifiedTarget == target else {
            throw CodexWorkspaceProvisionerError.worktreeCollision
        }
        try makePrivateDirectory(target, mayCreate: false)
        return CodexProvisionedWorkspace(
            canonicalRootURL: canonicalRoot,
            executionDirectoryURL: target,
            usesDetachedWorktree: true
        )
    }

    /// This root is a catalog capability, never itself a task's working directory.
    func prepareStandaloneRoot() throws -> URL {
        guard limits.isValid else { throw CodexWorkspaceProvisionerError.invalidLimits }
        let root = try prepareManagedRoot(named: Self.standaloneDirectoryName)
        guard !containsGitMarker(atOrAbove: root) else {
            throw CodexWorkspaceProvisionerError.unsafeManagedStorage
        }
        return root
    }

    func isStandaloneTaskDirectory(_ directory: URL) -> Bool {
        let candidate = directory.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.deletingLastPathComponent() == standaloneRootURL
            && UUID(uuidString: candidate.lastPathComponent) != nil
    }

    private var standaloneRootURL: URL {
        applicationSupportDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(Self.productDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.standaloneDirectoryName, isDirectory: true)
    }

    private func provisionStandaloneWorkspace(for requestID: UUID) throws -> CodexProvisionedWorkspace {
        let root = try prepareStandaloneRoot()
        let receipts = try prepareManagedRoot(named: Self.standaloneReceiptDirectoryName)
        let name = requestID.uuidString.lowercased()
        let target = root.appendingPathComponent(name, isDirectory: true)
        let receipt = receipts.appendingPathComponent(name, isDirectory: true)
        if pathEntryExists(target) {
            // Only a directory created by this request may survive a retry.
            // Never adopt an unregistered folder or copy from a recent task.
            guard pathEntryExists(receipt) else {
                throw CodexWorkspaceProvisionerError.worktreeCollision
            }
            try makePrivateDirectory(receipt, mayCreate: false)
            try makePrivateDirectory(target, mayCreate: false)
        } else {
            guard !pathEntryExists(receipt) else {
                throw CodexWorkspaceProvisionerError.worktreeCollision
            }
            try makePrivateDirectory(target, mayCreate: true)
            guard try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else {
                throw CodexWorkspaceProvisionerError.worktreeCollision
            }
            // Keep bookkeeping outside the empty task directory.
            try makePrivateDirectory(receipt, mayCreate: true)
        }
        return CodexProvisionedWorkspace(
            canonicalRootURL: target,
            executionDirectoryURL: target,
            usesDetachedWorktree: false
        )
    }

    private func prepareManagedRoot(named name: String = Self.worktreeDirectoryName) throws -> URL {
        let applicationSupport = try verifiedExistingDirectory(
            applicationSupportDirectoryURL,
            error: .invalidApplicationSupportDirectory
        )
        let productDirectory = applicationSupport.appendingPathComponent(
            Self.productDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        let managedRoot = productDirectory.appendingPathComponent(
            name,
            isDirectory: true
        ).standardizedFileURL
        guard productDirectory.deletingLastPathComponent() == applicationSupport,
              managedRoot.deletingLastPathComponent() == productDirectory,
              isValidPath(managedRoot.path)
        else { throw CodexWorkspaceProvisionerError.unsafeManagedStorage }
        try makePrivateDirectory(productDirectory, mayCreate: true)
        try makePrivateDirectory(managedRoot, mayCreate: true)
        return managedRoot
    }

    private func makePrivateDirectory(_ directoryURL: URL, mayCreate: Bool) throws {
        guard directoryURL.isFileURL,
              directoryURL.baseURL == nil,
              (directoryURL.path as NSString).isAbsolutePath,
              isValidPath(directoryURL.path)
        else { throw CodexWorkspaceProvisionerError.unsafeManagedStorage }

        let existing = pathEntryStatus(directoryURL)
        if existing == nil {
            guard mayCreate else { throw CodexWorkspaceProvisionerError.worktreeCreationFailed }
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
            } catch {
                guard pathEntryStatus(directoryURL) != nil else {
                    throw CodexWorkspaceProvisionerError.unsafeManagedStorage
                }
            }
        }
        guard let status = pathEntryStatus(directoryURL),
              status.isDirectory,
              !status.isSymbolicLink,
              status.ownerUserID == getuid(),
              directoryURL.resolvingSymlinksInPath().standardizedFileURL == directoryURL
        else { throw CodexWorkspaceProvisionerError.unsafeManagedStorage }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw CodexWorkspaceProvisionerError.unsafeManagedStorage
        }
        guard let finalStatus = pathEntryStatus(directoryURL),
              finalStatus.isDirectory,
              !finalStatus.isSymbolicLink,
              finalStatus.ownerUserID == getuid(),
              finalStatus.permissions & 0o777 == 0o700
        else { throw CodexWorkspaceProvisionerError.unsafeManagedStorage }
    }

    private func verifiedExistingDirectory(
        _ candidate: URL,
        error: CodexWorkspaceProvisionerError
    ) throws -> URL {
        guard candidate.isFileURL,
              candidate.baseURL == nil,
              (candidate.path as NSString).isAbsolutePath,
              isValidPath(candidate.path)
        else { throw error }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.baseURL == nil,
              isValidPath(resolved.path),
              let status = pathEntryStatus(resolved),
              status.isDirectory,
              !status.isSymbolicLink
        else { throw error }
        return resolved
    }

    private func canonicalPathURL(_ path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath, isValidPath(path) else {
            throw CodexWorkspaceProvisionerError.invalidGitOutput
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func parseSinglePath(_ data: Data) throws -> URL {
        guard !data.isEmpty, !data.contains(0) else {
            throw CodexWorkspaceProvisionerError.invalidGitOutput
        }
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty,
              let path = String(data: bytes, encoding: .utf8)
        else { throw CodexWorkspaceProvisionerError.invalidGitOutput }
        return try canonicalPathURL(path)
    }

    private func containsGitMarker(atOrAbove directoryURL: URL) -> Bool {
        var current = directoryURL
        for _ in 0..<256 {
            if pathEntryExists(current.appendingPathComponent(".git")) { return true }
            let currentPath = current.path
            if currentPath == "/" { return false }
            let parentPath = (currentPath as NSString).deletingLastPathComponent
            guard !parentPath.isEmpty, parentPath != currentPath else { return false }
            current = URL(fileURLWithPath: parentPath, isDirectory: true)
        }
        return true
    }

    private func isValidPath(_ path: String) -> Bool {
        !path.isEmpty
            && path.utf8.count <= limits.maximumPathBytes
            && !path.utf8.contains(0)
    }

    private func runGit(_ arguments: [String]) throws -> GitCommandResult {
        let executable = gitExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
        guard gitExecutableURL.isFileURL,
              gitExecutableURL.baseURL == nil,
              (gitExecutableURL.path as NSString).isAbsolutePath,
              let executableStatus = pathEntryStatus(executable),
              !executableStatus.isDirectory,
              !executableStatus.isSymbolicLink,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw CodexWorkspaceProvisionerError.invalidGitExecutable }

        let protectedArguments = [
            "--no-pager",
            "-c", "core.hooksPath=/dev/null",
            "-c", "submodule.recurse=false",
            "-c", "credential.interactive=never",
        ] + arguments
        guard protectedArguments.count <= 32,
              protectedArguments.allSatisfy({ !$0.utf8.contains(0) }),
              protectedArguments.reduce(0, { $0 + $1.utf8.count + 1 })
                <= limits.maximumArgumentBytes
        else { throw CodexWorkspaceProvisionerError.gitCommandFailed }

        return try BoundedProcessRunner.run(
            executableURL: executable,
            arguments: protectedArguments,
            limits: limits
        )
    }
}

private extension CodexWorkspaceProvisioner {
    struct GitContext {
        let canonicalRootURL: URL
        let worktrees: [GitWorktreeRecord]
    }

    struct GitWorktreeRecord {
        let directoryURL: URL
        let head: String?
        let isBare: Bool
        let isDetached: Bool
        let isLocked: Bool
        let isPrunable: Bool
    }

    struct GitWorktreeBuilder {
        let directoryURL: URL
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        func build() throws -> GitWorktreeRecord {
            guard isBare || head != nil,
                  !(isBare && (isDetached || branch != nil)),
                  !(isDetached && branch != nil)
            else { throw CodexWorkspaceProvisionerError.invalidGitOutput }
            return GitWorktreeRecord(
                directoryURL: directoryURL,
                head: head,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                isPrunable: isPrunable
            )
        }
    }
}

private struct GitCommandResult {
    let terminationStatus: Int32
    let standardOutput: Data
}

private enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        limits: CodexWorkspaceProvisioner.Limits
    ) throws -> GitCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = BoundedDataCollector(limit: limits.maximumStandardOutputBytes)
        let errorCollector = BoundedDataCollector(limit: limits.maximumStandardErrorBytes)
        let termination = DispatchSemaphore(value: 0)
        let drains = DispatchGroup()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            throw CodexWorkspaceProvisionerError.processUnavailable
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        drain(
            outputPipe.fileHandleForReading,
            into: outputCollector,
            terminating: process,
            group: drains
        )
        drain(
            errorPipe.fileHandleForReading,
            into: errorCollector,
            terminating: process,
            group: drains
        )

        let timeoutNanoseconds = Int(limits.processTimeoutSeconds * 1_000_000_000)
        if termination.wait(timeout: .now() + .nanoseconds(timeoutNanoseconds)) == .timedOut {
            terminate(process, termination: termination)
            throw CodexWorkspaceProvisionerError.processTimedOut
        }
        if drains.wait(timeout: .now() + .seconds(1)) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            throw CodexWorkspaceProvisionerError.processUnavailable
        }
        if outputCollector.exceededLimit || errorCollector.exceededLimit {
            throw CodexWorkspaceProvisionerError.outputTooLarge
        }
        return GitCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputCollector.data
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into collector: BoundedDataCollector,
        terminating process: Process,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = handle.readData(ofLength: 8 * 1_024)
                guard !chunk.isEmpty else { return }
                guard collector.append(chunk) else {
                    if process.isRunning { process.terminate() }
                    return
                }
            }
        }
    }

    private static func terminate(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning { process.terminate() }
        if termination.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
           process.isRunning
        {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + .seconds(1))
        }
    }
}

private final class BoundedDataCollector {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()
    private var didExceedLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didExceedLimit, chunk.count <= limit - storage.count else {
            didExceedLimit = true
            return false
        }
        storage.append(chunk)
        return true
    }
}

private struct PathEntryStatus {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let ownerUserID: uid_t
    let permissions: Int
}

private func pathEntryStatus(_ url: URL) -> PathEntryStatus? {
    var value = stat()
    guard url.isFileURL, lstat(url.path, &value) == 0 else { return nil }
    let fileType = value.st_mode & S_IFMT
    return PathEntryStatus(
        isDirectory: fileType == S_IFDIR,
        isSymbolicLink: fileType == S_IFLNK,
        ownerUserID: value.st_uid,
        permissions: Int(value.st_mode)
    )
}

private func pathEntryExists(_ url: URL) -> Bool {
    pathEntryStatus(url) != nil
}

import Foundation
import XCTest
@testable import WristRemoteBridge

final class CodexWorkspaceProvisionerTests: XCTestCase {
    private let requestID = UUID(uuidString: "7D54B7C6-B35C-42FB-9E4C-90A22CAFD94D")!

    func testBlankTasksHaveDistinctEmptyPrivateDirectoriesAndNoGitHistory() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let root = try fixture.provisioner.prepareStandaloneRoot()
        let first = try fixture.provisioner.provisionWorkspace(for: requestID, fromRecentThreadDirectory: root)
        let second = try fixture.provisioner.provisionWorkspace(for: UUID(), fromRecentThreadDirectory: root)
        XCTAssertNotEqual(first.executionDirectoryURL, second.executionDirectoryURL)
        for task in [first, second] {
            XCTAssertEqual(task.canonicalRootURL, task.executionDirectoryURL)
            XCTAssertNotEqual(task.executionDirectoryURL, root)
            XCTAssertFalse(task.usesDetachedWorktree)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: task.executionDirectoryURL.path).isEmpty)
            XCTAssertTrue(fixture.provisioner.isStandaloneTaskDirectory(task.executionDirectoryURL))
            XCTAssertEqual(try permissions(of: task.executionDirectoryURL) & 0o777, 0o700)
        }
        let retry = try fixture.provisioner.provisionWorkspace(for: requestID, fromRecentThreadDirectory: root)
        XCTAssertEqual(retry, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedRootURL.path))
    }

    func testBlankTaskNeverAdoptsPreexistingContentOrSymlink() throws {
        for symlink in [false, true] {
            let fixture = try WorkspaceFixture()
            defer { fixture.remove() }
            let root = try fixture.provisioner.prepareStandaloneRoot()
            let destination = root.appendingPathComponent(requestID.uuidString.lowercased())
            if symlink {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: fixture.rootURL)
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("preserve".utf8).write(to: destination.appendingPathComponent("old.txt"))
            }
            XCTAssertThrowsError(try fixture.provisioner.provisionWorkspace(for: requestID, fromRecentThreadDirectory: root))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testBlankTaskRetryPreservesItsOwnNewFilesWithoutCopyingThemToAnotherTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let root = try fixture.provisioner.prepareStandaloneRoot()
        let first = try fixture.provisioner.provisionWorkspace(for: requestID, fromRecentThreadDirectory: root)
        try Data("only this task".utf8).write(to: first.executionDirectoryURL.appendingPathComponent("new.txt"))
        let retry = try fixture.provisioner.provisionWorkspace(for: requestID, fromRecentThreadDirectory: root)
        XCTAssertEqual(first, retry)
        let next = try fixture.provisioner.provisionWorkspace(for: UUID(), fromRecentThreadDirectory: root)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: next.executionDirectoryURL.path).isEmpty)
    }

    func testNonGitDirectoryReturnsCanonicalDirectoryWithoutCreatingManagedStorage() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let workspace = fixture.rootURL.appendingPathComponent("plain-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let alias = fixture.rootURL.appendingPathComponent("plain-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)

        let result = try fixture.provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: alias
        )

        let canonicalWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(result.canonicalRootURL, canonicalWorkspace)
        XCTAssertEqual(result.executionDirectoryURL, canonicalWorkspace)
        XCTAssertFalse(result.usesDetachedWorktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedRootURL.path))
    }

    func testLinkedWorktreeResolvesMainWorkspaceAndCreatesDetachedWorktree() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let linkedWorktree = fixture.rootURL.appendingPathComponent("linked", isDirectory: true)
        try runGit(["-C", repository.path, "worktree", "add", "-b", "linked-test", linkedWorktree.path])
        let nestedDirectory = linkedWorktree.appendingPathComponent("Sources/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let result = try fixture.provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: nestedDirectory
        )

        let expectedExecutionURL = fixture.managedRootURL.appendingPathComponent(
            requestID.uuidString.lowercased(),
            isDirectory: true
        )
        XCTAssertEqual(
            result.canonicalRootURL,
            repository.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertEqual(
            result.executionDirectoryURL,
            expectedExecutionURL.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertTrue(result.usesDetachedWorktree)
        XCTAssertEqual(
            try runGitAndCapture(["-C", result.executionDirectoryURL.path, "rev-parse", "--abbrev-ref", "HEAD"]),
            "HEAD"
        )
        XCTAssertEqual(try permissions(of: fixture.managedRootURL) & 0o777, 0o700)
        XCTAssertEqual(try permissions(of: result.executionDirectoryURL) & 0o777, 0o700)
    }

    func testRetryReusesTheSameDetachedWorktreeAndCommit() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()

        let first = try fixture.provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: repository
        )
        let firstCommit = try runGitAndCapture([
            "-C", first.executionDirectoryURL.path, "rev-parse", "HEAD",
        ])
        try Data("second\n".utf8).write(
            to: repository.appendingPathComponent("second.txt"),
            options: .atomic
        )
        try runGit(["-C", repository.path, "add", "second.txt"])
        try runGit([
            "-C", repository.path,
            "-c", "user.name=Wrist Remote Tests",
            "-c", "user.email=wrist-remote-tests@example.invalid",
            "commit", "-m", "second",
        ])

        let second = try fixture.provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: repository
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(
            try runGitAndCapture(["-C", second.executionDirectoryURL.path, "rev-parse", "HEAD"]),
            firstCommit
        )
        let worktreeListing = try runGitAndCapture([
            "-C", repository.path, "worktree", "list", "--porcelain",
        ])
        XCTAssertEqual(
            worktreeListing.components(separatedBy: second.executionDirectoryURL.path).count - 1,
            1
        )
    }

    func testExistingUnregisteredTargetFailsClosedWithoutDeletingContents() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let target = fixture.managedRootURL.appendingPathComponent(
            requestID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: sentinel, options: .atomic)

        XCTAssertThrowsError(
            try fixture.provisioner.provisionWorkspace(
                for: requestID,
                fromRecentThreadDirectory: repository
            )
        ) { error in
            XCTAssertEqual(error as? CodexWorkspaceProvisionerError, .worktreeCollision)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testSymlinkedManagedStorageFailsClosed() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let productDirectory = fixture.applicationSupportURL.appendingPathComponent(
            "WristRemoteBridge",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: true)
        let externalDirectory = fixture.rootURL.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.managedRootURL,
            withDestinationURL: externalDirectory
        )

        XCTAssertThrowsError(
            try fixture.provisioner.provisionWorkspace(
                for: requestID,
                fromRecentThreadDirectory: repository
            )
        ) { error in
            XCTAssertEqual(error as? CodexWorkspaceProvisionerError, .unsafeManagedStorage)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path), [])
    }

    func testOversizedGitOutputIsRejected() throws {
        let fixture = try WorkspaceFixture(
            limits: CodexWorkspaceProvisioner.Limits(
                processTimeoutSeconds: 5,
                maximumStandardOutputBytes: 8,
                maximumStandardErrorBytes: 1_024,
                maximumPathBytes: 4_096,
                maximumArgumentBytes: 8_192
            )
        )
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()

        XCTAssertThrowsError(
            try fixture.provisioner.provisionWorkspace(
                for: requestID,
                fromRecentThreadDirectory: repository
            )
        ) { error in
            XCTAssertEqual(error as? CodexWorkspaceProvisionerError, .outputTooLarge)
        }
    }

    func testGitHooksAreDisabledWhileCreatingWorktree() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let hook = repository.appendingPathComponent(".git/hooks/post-checkout")
        let sentinel = fixture.rootURL.appendingPathComponent("hook-was-run")
        let script = """
        #!/bin/sh
        /usr/bin/touch \(shellQuote(sentinel.path))
        """
        try Data(script.utf8).write(to: hook, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: hook.path
        )

        _ = try fixture.provisioner.provisionWorkspace(
            for: requestID,
            fromRecentThreadDirectory: repository
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testTimedOutGitProcessIsTerminated() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let workspace = fixture.rootURL.appendingPathComponent("plain-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let fakeGit = fixture.rootURL.appendingPathComponent("fake-git")
        try Data("#!/bin/sh\nexec /bin/sleep 2\n".utf8).write(to: fakeGit, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: fakeGit.path
        )
        let provisioner = CodexWorkspaceProvisioner(
            applicationSupportDirectoryURL: fixture.applicationSupportURL,
            gitExecutableURL: fakeGit,
            limits: .init(
                processTimeoutSeconds: 0.05,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024,
                maximumPathBytes: 4_096,
                maximumArgumentBytes: 8_192
            )
        )

        XCTAssertThrowsError(
            try provisioner.provisionWorkspace(
                for: requestID,
                fromRecentThreadDirectory: workspace
            )
        ) { error in
            XCTAssertEqual(error as? CodexWorkspaceProvisionerError, .processTimedOut)
        }
    }

    func testRelativeAndMissingRecentDirectoriesAreRejected() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        for invalidURL in [
            URL(fileURLWithPath: "relative/path", relativeTo: URL(fileURLWithPath: "/tmp")),
            fixture.rootURL.appendingPathComponent("missing", isDirectory: true),
        ] {
            XCTAssertThrowsError(
                try fixture.provisioner.provisionWorkspace(
                    for: requestID,
                    fromRecentThreadDirectory: invalidURL
                )
            ) { error in
                XCTAssertEqual(error as? CodexWorkspaceProvisionerError, .invalidRecentThreadDirectory)
            }
        }
    }
}

private struct WorkspaceFixture {
    let rootURL: URL
    let applicationSupportURL: URL
    let provisioner: CodexWorkspaceProvisioner

    var managedRootURL: URL {
        applicationSupportURL
            .appendingPathComponent("WristRemoteBridge", isDirectory: true)
            .appendingPathComponent("CodexWorktrees", isDirectory: true)
    }

    init(limits: CodexWorkspaceProvisioner.Limits = .init()) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWorkspaceProvisionerTests-" + UUID().uuidString,
                isDirectory: true
            )
        applicationSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        provisioner = CodexWorkspaceProvisioner(
            applicationSupportDirectoryURL: applicationSupportURL,
            limits: limits
        )
    }

    func makeRepository() throws -> URL {
        let repository = rootURL.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["-C", repository.path, "init", "--initial-branch=main"])
        try Data("initial\n".utf8).write(
            to: repository.appendingPathComponent("README.md"),
            options: .atomic
        )
        try runGit(["-C", repository.path, "add", "README.md"])
        try runGit([
            "-C", repository.path,
            "-c", "user.name=Wrist Remote Tests",
            "-c", "user.email=wrist-remote-tests@example.invalid",
            "commit", "-m", "initial",
        ])
        return repository
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@discardableResult
private func runGit(_ arguments: [String]) throws -> String {
    try runGitAndCapture(arguments)
}

private func runGitAndCapture(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    // Match BoundedProcessRunner: XCTest's DYLD/SDK environment must not leak
    // into the system Git shim or any developer-tool subprocess it launches.
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
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "CodexWorkspaceProvisionerTests.Git",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
        )
    }
    return String(decoding: stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func permissions(of directoryURL: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

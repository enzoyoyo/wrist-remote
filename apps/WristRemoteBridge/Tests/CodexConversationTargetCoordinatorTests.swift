import Foundation
import XCTest
@testable import WristRemoteBridge

@MainActor
final class CodexConversationTargetCoordinatorTests: XCTestCase {
    func testSelectionRouterForwardsNewConversationAndInstallsCreatedTarget() async throws {
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let target = makeTarget(kind: .newConversation, workspaceID: "workspace-main")
        let createdTarget = makeTarget(
            kind: .existing,
            threadID: createdThreadID,
            workspaceID: target.workspaceID,
            workspaceLabel: target.workspaceLabel
        )
        var coordinatedRequests: [WatchCodexConversationTargetSelectionRequest] = []
        var installedTargets: [WatchCodexConversationTarget] = []

        let selected = try await CodexConversationTargetSelectionRouter.select(
            requestID: requestID,
            target: target,
            coordinate: { request in
                coordinatedRequests.append(request)
                return createdTarget
            },
            isCreatedTargetInstalled: { _ in false },
            installCreatedTarget: { installedTargets.append($0) }
        )

        XCTAssertEqual(selected, createdTarget)
        XCTAssertEqual(
            coordinatedRequests,
            [WatchCodexConversationTargetSelectionRequest(
                requestID: requestID,
                target: target
            )]
        )
        XCTAssertEqual(installedTargets, [createdTarget])
    }

    func testSelectionRouterForwardsExistingConversationWithoutCreatedInstall() async throws {
        let requestID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let target = makeTarget(kind: .existing, threadID: existingThreadID)
        var installedTargets: [WatchCodexConversationTarget] = []

        let selected = try await CodexConversationTargetSelectionRouter.select(
            requestID: requestID,
            target: target,
            coordinate: { request in
                XCTAssertEqual(request.requestID, requestID)
                XCTAssertEqual(request.target, target)
                return target
            },
            isCreatedTargetInstalled: { _ in false },
            installCreatedTarget: { installedTargets.append($0) }
        )

        XCTAssertEqual(selected, target)
        XCTAssertTrue(installedTargets.isEmpty)
    }

    func testSelectionRouterDoesNotReinstallCachedCreatedTarget() async throws {
        let requestID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let target = makeTarget(kind: .newConversation, workspaceID: "workspace-main")
        let createdTarget = makeTarget(
            kind: .existing,
            threadID: createdThreadID,
            workspaceID: target.workspaceID,
            workspaceLabel: target.workspaceLabel
        )
        var installedTargets: [WatchCodexConversationTarget] = []

        for _ in 0..<2 {
            _ = try await CodexConversationTargetSelectionRouter.select(
                requestID: requestID,
                target: target,
                coordinate: { _ in createdTarget },
                isCreatedTargetInstalled: { installedTargets.contains($0) },
                installCreatedTarget: { installedTargets.append($0) }
            )
        }

        XCTAssertEqual(installedTargets, [createdTarget])
    }

    func testExistingSelectionOnlyResolvesAuthorityTarget() async throws {
        let target = makeTarget(kind: .existing, threadID: existingThreadID)
        var resolveCount = 0
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                resolveCount += 1
                return ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: self.existingThreadID,
                    cwd: "/private/example/workspace"
                )
            },
            provisionWorkspace: { _, _ in
                XCTFail("An existing conversation must not provision a workspace")
                throw CoordinatorTestError.unexpectedCall
            },
            startThread: { _ in
                XCTFail("An existing conversation must not start a thread")
                throw CoordinatorTestError.unexpectedCall
            },
            registerCreatedConversation: { _ in
                XCTFail("An existing conversation must not register a new thread")
                throw CoordinatorTestError.unexpectedCall
            }
        ))
        let request = WatchCodexConversationTargetSelectionRequest(
            requestID: UUID(),
            target: target
        )

        let selected = try await coordinator.select(request)
        let retried = try await coordinator.select(request)

        XCTAssertEqual(selected, target)
        XCTAssertEqual(retried, target)
        XCTAssertEqual(resolveCount, 1)
    }

    func testNewSelectionUsesProvisionedExecutionWorkspaceAndCachesSuccess() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let target = makeTarget(kind: .newConversation, workspaceID: "workspace-main")
        let createdTarget = makeTarget(
            kind: .existing,
            threadID: createdThreadID,
            workspaceID: target.workspaceID,
            workspaceLabel: target.workspaceLabel,
            leaseID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        )
        let started = startResult(
            threadID: createdThreadID,
            workspaceLabel: target.workspaceLabel
        )
        var resolvedTargets: [WatchCodexConversationTarget] = []
        var provisionedRequestIDs: [UUID] = []
        var startedWorkspaces: [CodexWorkspaceDescriptor] = []
        var registrations: [CodexConversationTargetCoordinator.CreatedConversationRegistration] = []
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                resolvedTargets.append(selectedTarget)
                return ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: nil,
                    cwd: fixture.recentDirectoryURL.path
                )
            },
            provisionWorkspace: { receivedRequestID, recentDirectoryURL in
                provisionedRequestIDs.append(receivedRequestID)
                XCTAssertEqual(recentDirectoryURL, fixture.recentDirectoryURL)
                return fixture.provisionedWorkspace
            },
            startThread: { workspace in
                startedWorkspaces.append(workspace)
                return started
            },
            registerCreatedConversation: { registration in
                registrations.append(registration)
                return createdTarget
            }
        ))
        let request = WatchCodexConversationTargetSelectionRequest(
            requestID: requestID,
            target: target
        )

        let first = try await coordinator.select(request)
        let retry = try await coordinator.select(request)

        XCTAssertEqual(first, createdTarget)
        XCTAssertEqual(retry, createdTarget)
        XCTAssertEqual(resolvedTargets, [target])
        XCTAssertEqual(provisionedRequestIDs, [requestID])
        XCTAssertEqual(startedWorkspaces.count, 1)
        XCTAssertEqual(startedWorkspaces.first?.id, target.workspaceID)
        XCTAssertEqual(startedWorkspaces.first?.displayName, target.workspaceLabel)
        XCTAssertEqual(startedWorkspaces.first?.directoryURL, fixture.executionDirectoryURL)
        XCTAssertNil(startedWorkspaces.first?.projectID)
        XCTAssertEqual(registrations, [
            .init(
                threadID: createdThreadID,
                title: started.conversation.title,
                workspaceID: target.workspaceID,
                workspaceLabel: target.workspaceLabel,
                cwd: fixture.executionDirectoryURL.path
            ),
        ])
    }

    func testDistinctNewRequestsForSameWorkspaceCreateDistinctThreadsAndCacheEachRequest() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let firstRequestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let secondRequestID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let firstThreadID = "44444444-4444-4444-8444-444444444444"
        let secondThreadID = "55555555-5555-4555-8555-555555555555"
        let target = makeTarget(kind: .newConversation, workspaceID: "workspace-main")
        var provisionedRequestIDs: [UUID] = []
        var startedThreadIDs: [String] = []
        var registeredThreadIDs: [String] = []
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: nil,
                    cwd: fixture.recentDirectoryURL.path
                )
            },
            provisionWorkspace: { requestID, recentDirectoryURL in
                provisionedRequestIDs.append(requestID)
                XCTAssertEqual(recentDirectoryURL, fixture.recentDirectoryURL)
                return fixture.provisionedWorkspace
            },
            startThread: { _ in
                let threadID = startedThreadIDs.isEmpty ? firstThreadID : secondThreadID
                startedThreadIDs.append(threadID)
                return self.startResult(
                    threadID: threadID,
                    workspaceLabel: target.workspaceLabel
                )
            },
            registerCreatedConversation: { registration in
                registeredThreadIDs.append(registration.threadID)
                return self.makeTarget(
                    kind: .existing,
                    threadID: registration.threadID,
                    workspaceID: registration.workspaceID,
                    workspaceLabel: registration.workspaceLabel,
                    serverEpoch: target.serverEpoch,
                    catalogRevision: target.catalogRevision
                )
            }
        ))
        let firstRequest = WatchCodexConversationTargetSelectionRequest(
            requestID: firstRequestID,
            target: target
        )
        let secondRequest = WatchCodexConversationTargetSelectionRequest(
            requestID: secondRequestID,
            target: target
        )

        let first = try await coordinator.select(firstRequest)
        let firstRetry = try await coordinator.select(firstRequest)
        let second = try await coordinator.select(secondRequest)
        let secondRetry = try await coordinator.select(secondRequest)

        XCTAssertEqual(first, firstRetry)
        XCTAssertEqual(second, secondRetry)
        XCTAssertEqual(first.threadID, firstThreadID)
        XCTAssertEqual(second.threadID, secondThreadID)
        XCTAssertNotEqual(first.threadID, second.threadID)
        XCTAssertEqual(provisionedRequestIDs, [firstRequestID, secondRequestID])
        XCTAssertEqual(startedThreadIDs, [firstThreadID, secondThreadID])
        XCTAssertEqual(registeredThreadIDs, [firstThreadID, secondThreadID])
    }

    func testConcurrentSameRequestSharesOneCreationTask() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let gate = CoordinatorStartGate()
        let target = makeTarget(kind: .newConversation)
        let createdTarget = makeTarget(
            kind: .existing,
            threadID: createdThreadID,
            workspaceID: target.workspaceID,
            workspaceLabel: target.workspaceLabel
        )
        var startCount = 0
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: nil,
                    cwd: fixture.recentDirectoryURL.path
                )
            },
            provisionWorkspace: { _, _ in fixture.provisionedWorkspace },
            startThread: { _ in
                startCount += 1
                await gate.suspendUntilReleased()
                return self.startResult(
                    threadID: self.createdThreadID,
                    workspaceLabel: target.workspaceLabel
                )
            },
            registerCreatedConversation: { _ in createdTarget }
        ))
        let request = WatchCodexConversationTargetSelectionRequest(
            requestID: UUID(),
            target: target
        )

        let first = Task { @MainActor in try await coordinator.select(request) }
        await gate.waitUntilEntered()
        let second = Task { @MainActor in try await coordinator.select(request) }
        await Task.yield()
        await gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, createdTarget)
        XCTAssertEqual(secondResult, createdTarget)
        XCTAssertEqual(startCount, 1)
    }

    func testFailureAfterThreadStartIsCachedAndNeverCreatesAgain() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let target = makeTarget(kind: .newConversation)
        var startCount = 0
        var registerCount = 0
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: nil,
                    cwd: fixture.recentDirectoryURL.path
                )
            },
            provisionWorkspace: { _, _ in fixture.provisionedWorkspace },
            startThread: { _ in
                startCount += 1
                return self.startResult(
                    threadID: self.createdThreadID,
                    workspaceLabel: target.workspaceLabel
                )
            },
            registerCreatedConversation: { _ in
                registerCount += 1
                throw CoordinatorTestError.registrationFailed
            }
        ))
        let request = WatchCodexConversationTargetSelectionRequest(
            requestID: UUID(),
            target: target
        )

        for _ in 0..<2 {
            do {
                _ = try await coordinator.select(request)
                XCTFail("A registration failure must fail closed")
            } catch {
                XCTAssertEqual(
                    error as? CodexConversationTargetCoordinatorError,
                    .outcomeUnknown
                )
            }
        }
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(registerCount, 2)
    }

    func testStartedConversationForAnotherWorkspaceFailsClosed() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let target = makeTarget(kind: .newConversation, workspaceLabel: "正确工作区")
        var startCount = 0
        var registerCount = 0
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: nil,
                    cwd: fixture.recentDirectoryURL.path
                )
            },
            provisionWorkspace: { _, _ in fixture.provisionedWorkspace },
            startThread: { _ in
                startCount += 1
                return self.startResult(
                    threadID: self.createdThreadID,
                    workspaceLabel: "另一个工作区"
                )
            },
            registerCreatedConversation: { _ in
                registerCount += 1
                throw CoordinatorTestError.unexpectedCall
            }
        ))
        let request = WatchCodexConversationTargetSelectionRequest(
            requestID: UUID(),
            target: target
        )

        do {
            _ = try await coordinator.select(request)
            XCTFail("A result attributed to another workspace must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CodexConversationTargetCoordinatorError,
                .outcomeUnknown
            )
        }
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(registerCount, 0)
    }

    func testRestartAfterThreadStartReconcilesPersistedThreadWithoutStartingAgain() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let initialTarget = makeTarget(kind: .newConversation)
        let refreshedTarget = makeTarget(
            kind: .newConversation,
            serverEpoch: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            catalogRevision: 2,
            leaseID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        )
        let recoveredTarget = makeTarget(
            kind: .existing,
            threadID: createdThreadID,
            workspaceID: refreshedTarget.workspaceID,
            workspaceLabel: refreshedTarget.workspaceLabel,
            serverEpoch: refreshedTarget.serverEpoch,
            catalogRevision: refreshedTarget.catalogRevision,
            leaseID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        )
        var startCount = 0
        let first = CodexConversationTargetCoordinator(
            dependencies: .init(
                resolveSelection: { target in
                    ResolvedCodexConversationTarget(
                        target: target,
                        threadID: nil,
                        cwd: fixture.recentDirectoryURL.path
                    )
                },
                provisionWorkspace: { _, _ in fixture.provisionedWorkspace },
                startThread: { _ in
                    startCount += 1
                    return self.startResult(
                        threadID: self.createdThreadID,
                        workspaceLabel: initialTarget.workspaceLabel
                    )
                },
                registerCreatedConversation: { _ in
                    throw CoordinatorTestError.registrationFailed
                }
            ),
            selectionLedger: CodexConversationTargetSelectionLedger(
                fileURL: fixture.selectionLedgerURL
            )
        )

        do {
            _ = try await first.select(.init(requestID: requestID, target: initialTarget))
            XCTFail("A post-start registration failure must be outcome-unknown")
        } catch {
            XCTAssertEqual(
                error as? CodexConversationTargetCoordinatorError,
                .outcomeUnknown
            )
        }
        XCTAssertEqual(startCount, 1)

        let restarted = CodexConversationTargetCoordinator(
            dependencies: .init(
                resolveSelection: { target in
                    ResolvedCodexConversationTarget(
                        target: target,
                        threadID: nil,
                        cwd: fixture.recentDirectoryURL.path
                    )
                },
                provisionWorkspace: { operationID, _ in
                    XCTAssertEqual(operationID, requestID)
                    return fixture.provisionedWorkspace
                },
                startThread: { _ in
                    startCount += 1
                    XCTFail("A restarted coordinator must reconcile, never start again")
                    throw CoordinatorTestError.unexpectedCall
                },
                registerCreatedConversation: { registration in
                    XCTAssertEqual(registration.threadID, self.createdThreadID)
                    XCTAssertEqual(registration.cwd, fixture.executionDirectoryURL.path)
                    return recoveredTarget
                }
            ),
            selectionLedger: CodexConversationTargetSelectionLedger(
                fileURL: fixture.selectionLedgerURL
            )
        )

        let recovered = try await restarted.select(.init(
            requestID: requestID,
            target: refreshedTarget
        ))
        XCTAssertEqual(recovered, recoveredTarget)
        XCTAssertEqual(startCount, 1)
        let ledgerText = try String(contentsOf: fixture.selectionLedgerURL, encoding: .utf8)
        XCTAssertFalse(ledgerText.contains(fixture.rootURL.path))
    }

    func testRestartAfterAmbiguousStartNeverStartsAgain() async throws {
        let fixture = try CoordinatorWorkspaceFixture()
        defer { fixture.remove() }
        let requestID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let target = makeTarget(kind: .newConversation)
        var startCount = 0
        var provisionCount = 0
        let first = CodexConversationTargetCoordinator(
            dependencies: .init(
                resolveSelection: { selectedTarget in
                    ResolvedCodexConversationTarget(
                        target: selectedTarget,
                        threadID: nil,
                        cwd: fixture.recentDirectoryURL.path
                    )
                },
                provisionWorkspace: { _, _ in
                    provisionCount += 1
                    return fixture.provisionedWorkspace
                },
                startThread: { _ in
                    startCount += 1
                    throw CoordinatorTestError.startFailed
                },
                registerCreatedConversation: { _ in
                    throw CoordinatorTestError.unexpectedCall
                }
            ),
            selectionLedger: CodexConversationTargetSelectionLedger(
                fileURL: fixture.selectionLedgerURL
            )
        )

        do {
            _ = try await first.select(.init(requestID: requestID, target: target))
            XCTFail("An ambiguous start must fail closed")
        } catch {
            XCTAssertEqual(
                error as? CodexConversationTargetCoordinatorError,
                .outcomeUnknown
            )
        }

        let restarted = CodexConversationTargetCoordinator(
            dependencies: .init(
                resolveSelection: { selectedTarget in
                    ResolvedCodexConversationTarget(
                        target: selectedTarget,
                        threadID: nil,
                        cwd: fixture.recentDirectoryURL.path
                    )
                },
                provisionWorkspace: { _, _ in
                    provisionCount += 1
                    XCTFail("An outcome-unknown retry must stop before provisioning")
                    throw CoordinatorTestError.unexpectedCall
                },
                startThread: { _ in
                    startCount += 1
                    XCTFail("An outcome-unknown retry must never start again")
                    throw CoordinatorTestError.unexpectedCall
                },
                registerCreatedConversation: { _ in
                    throw CoordinatorTestError.unexpectedCall
                }
            ),
            selectionLedger: CodexConversationTargetSelectionLedger(
                fileURL: fixture.selectionLedgerURL
            )
        )

        do {
            _ = try await restarted.select(.init(requestID: requestID, target: target))
            XCTFail("A persisted ambiguous result must remain outcome-unknown")
        } catch {
            XCTAssertEqual(
                error as? CodexConversationTargetCoordinatorError,
                .outcomeUnknown
            )
        }
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(provisionCount, 1)
    }

    func testSameRequestIDCannotBeReboundToAnotherWorkspace() async throws {
        let requestID = UUID()
        let firstTarget = makeTarget(
            kind: .existing,
            threadID: existingThreadID,
            workspaceID: "workspace-one"
        )
        let secondTarget = makeTarget(
            kind: .existing,
            threadID: "22222222-2222-4222-8222-222222222222",
            workspaceID: "workspace-two",
            leaseID: UUID()
        )
        var resolveCount = 0
        let coordinator = CodexConversationTargetCoordinator(dependencies: .init(
            resolveSelection: { selectedTarget in
                resolveCount += 1
                return ResolvedCodexConversationTarget(
                    target: selectedTarget,
                    threadID: selectedTarget.threadID,
                    cwd: "/private/example/workspace"
                )
            },
            provisionWorkspace: { _, _ in throw CoordinatorTestError.unexpectedCall },
            startThread: { _ in throw CoordinatorTestError.unexpectedCall },
            registerCreatedConversation: { _ in throw CoordinatorTestError.unexpectedCall }
        ))

        _ = try await coordinator.select(.init(requestID: requestID, target: firstTarget))
        do {
            _ = try await coordinator.select(.init(requestID: requestID, target: secondTarget))
            XCTFail("One request identity must not be rebound to another workspace")
        } catch {
            XCTAssertEqual(
                error as? CodexConversationTargetCoordinatorError,
                .requestIdentityConflict
            )
        }
        XCTAssertEqual(resolveCount, 1)
    }

    func testSelectionLedgerEvictsOldestCompletedRecordAtCapacity() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexSelectionLedgerEviction-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("ledger.json")
        let ledger = CodexConversationTargetSelectionLedger(fileURL: fileURL)

        for index in 0..<128 {
            let operationID = ledgerUUID(index)
            let threadID = ledgerUUID(index + 1_000).uuidString.lowercased()
            try ledger.markStarting(operationID: operationID, workspaceID: "workspace-main")
            try ledger.markStarted(operationID: operationID, threadID: threadID)
            try ledger.markCompleted(operationID: operationID, threadID: threadID)
        }

        let replacementID = ledgerUUID(500)
        try ledger.markStarting(operationID: replacementID, workspaceID: "workspace-main")

        XCTAssertNil(try ledger.record(for: ledgerUUID(0)))
        XCTAssertEqual(try ledger.record(for: ledgerUUID(1))?.stage, .completed)
        XCTAssertEqual(try ledger.record(for: replacementID)?.stage, .starting)

        let restarted = CodexConversationTargetSelectionLedger(fileURL: fileURL)
        XCTAssertNil(try restarted.record(for: ledgerUUID(0)))
        XCTAssertEqual(try restarted.record(for: ledgerUUID(1))?.stage, .completed)
        XCTAssertEqual(try restarted.record(for: replacementID)?.stage, .starting)
    }

    func testSelectionLedgerNeverEvictsUncertainRecordsAtCapacity() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexSelectionLedgerPending-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("ledger.json")
        let ledger = CodexConversationTargetSelectionLedger(fileURL: fileURL)

        for index in 0..<128 {
            try ledger.markStarting(
                operationID: ledgerUUID(index),
                workspaceID: "workspace-main"
            )
        }
        let rejectedID = ledgerUUID(500)
        XCTAssertThrowsError(try ledger.markStarting(
            operationID: rejectedID,
            workspaceID: "workspace-main"
        ))
        XCTAssertEqual(try ledger.record(for: ledgerUUID(0))?.stage, .starting)
        XCTAssertEqual(try ledger.record(for: ledgerUUID(127))?.stage, .starting)
        XCTAssertNil(try ledger.record(for: rejectedID))
    }

    private let existingThreadID = "11111111-1111-4111-8111-111111111111"
    private let createdThreadID = "33333333-3333-4333-8333-333333333333"

    private func ledgerUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%012llx",
            Int64(value)
        ))!
    }

    private func makeTarget(
        kind: WatchCodexTargetKind,
        threadID: String? = nil,
        workspaceID: String = "workspace-example",
        workspaceLabel: String = "示例工作区",
        serverEpoch: UUID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
        catalogRevision: Int = 1,
        leaseID: UUID = UUID()
    ) -> WatchCodexConversationTarget {
        WatchCodexConversationTarget(
            leaseID: leaseID,
            kind: kind,
            serverEpoch: serverEpoch,
            catalogRevision: catalogRevision,
            entryRevision: 1,
            threadID: threadID,
            displayTitle: kind == .existing ? "已有会话" : "新建 Codex 会话",
            workspaceID: workspaceID,
            workspaceLabel: workspaceLabel,
            expiresAtEpochMilliseconds: 9_000_000_000_000
        )!
    }

    private func startResult(
        threadID: String,
        workspaceLabel: String
    ) -> CodexConversationStartResult {
        CodexConversationStartResult(conversation: CodexConversationCatalogEntry(
            threadID: threadID,
            title: "独立新会话",
            workspaceLabel: workspaceLabel,
            status: .idle,
            canAcceptDirectInput: true,
            updatedAtEpochSeconds: 1
        ))
    }
}

private enum CoordinatorTestError: Error, Equatable {
    case unexpectedCall
    case registrationFailed
    case startFailed
}

private final class CoordinatorWorkspaceFixture {
    let rootURL: URL
    let recentDirectoryURL: URL
    let canonicalRootURL: URL
    let executionDirectoryURL: URL
    let selectionLedgerURL: URL

    var provisionedWorkspace: CodexProvisionedWorkspace {
        CodexProvisionedWorkspace(
            canonicalRootURL: canonicalRootURL,
            executionDirectoryURL: executionDirectoryURL,
            usesDetachedWorktree: true
        )
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationTargetCoordinatorTests-" + UUID().uuidString,
            isDirectory: true
        )
        recentDirectoryURL = rootURL.appendingPathComponent("recent", isDirectory: true)
        canonicalRootURL = rootURL.appendingPathComponent("canonical", isDirectory: true)
        executionDirectoryURL = rootURL.appendingPathComponent("execution", isDirectory: true)
        selectionLedgerURL = rootURL.appendingPathComponent(
            "selection-ledger.json",
            isDirectory: false
        )
        for directory in [recentDirectoryURL, canonicalRootURL, executionDirectoryURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor CoordinatorStartGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

import XCTest
@testable import WristRemote

final class WatchCodexConversationProtocolTests: XCTestCase {
    private let serverEpoch = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let existingLeaseID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let newLeaseID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let refreshedAt: Int64 = 1_777_000_000_000
    private let expiresAt: Int64 = 1_777_000_600_000

    func testActiveVoiceSurvivesLeaseRenewalWithoutAllowingRetargetOrExpiry() throws {
        let current = try makeExistingTarget()
        func catalog(thread: String = "thread-example", workspace: String = "workspace-example",
                     epoch: UUID? = nil, acceptsInput: Bool = true,
                     entriesPresent: Bool = true) throws -> WatchCodexConversationCatalog {
            let target = try XCTUnwrap(WatchCodexConversationTarget(
                leaseID: UUID(), kind: .existing, serverEpoch: epoch ?? serverEpoch,
                catalogRevision: 5, entryRevision: 10, threadID: thread,
                displayTitle: "Renamed task", workspaceID: workspace,
                workspaceLabel: "Example workspace", expiresAtEpochMilliseconds: expiresAt + 60_000
            ))
            let entry = try XCTUnwrap(WatchCodexConversationEntry(
                threadID: thread, title: target.displayTitle, workspaceLabel: target.workspaceLabel,
                state: .idle, updatedAtEpochMilliseconds: refreshedAt,
                canAcceptInput: acceptsInput, entryRevision: 10, target: target
            ))
            return try XCTUnwrap(WatchCodexConversationCatalog(
                serverEpoch: target.serverEpoch, revision: 5,
                entries: entriesPresent ? [entry] : [], hasMore: false,
                refreshedAtEpochMilliseconds: refreshedAt
            ))
        }
        XCTAssertTrue(try catalog().permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog(thread: "other-task").permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog(workspace: "other-workspace").permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog(epoch: UUID()).permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog(acceptsInput: false).permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog(entriesPresent: false).permitsContinuingVoice(for: current, nowEpochMilliseconds: refreshedAt))
        XCTAssertFalse(try catalog().permitsContinuingVoice(for: current, nowEpochMilliseconds: expiresAt))
        XCTAssertFalse(try catalog().permitsContinuingVoice(for: makeNewTarget(), nowEpochMilliseconds: refreshedAt))
    }

    func testLeaseRenewalKeepsExactThreadWorkspaceAndEpoch() throws {
        let current = try makeExistingTarget()
        func replacement(thread: String = "thread-example", workspace: String = "workspace-example",
                         epoch: UUID? = nil, revision: Int = 5) throws -> WatchCodexConversationTarget {
            try XCTUnwrap(WatchCodexConversationTarget(leaseID: UUID(), kind: .existing,
                serverEpoch: epoch ?? serverEpoch, catalogRevision: revision, entryRevision: 10,
                threadID: thread, displayTitle: "Updated title", workspaceID: workspace,
                workspaceLabel: "Example workspace", expiresAtEpochMilliseconds: expiresAt))
        }
        func allowed(_ target: WatchCodexConversationTarget, at time: Int64? = nil) -> Bool {
            WatchCodexConversationSelectionResolution.permitsLeaseRenewal(
                current: current, replacement: target, nowEpochMilliseconds: time ?? refreshedAt)
        }
        XCTAssertTrue(allowed(try replacement()))
        XCTAssertFalse(allowed(try replacement(thread: "another-thread")))
        XCTAssertFalse(allowed(try replacement(workspace: "another-workspace")))
        XCTAssertFalse(allowed(try replacement(epoch: UUID())))
        XCTAssertFalse(allowed(try replacement(revision: 3)))
        XCTAssertFalse(allowed(try replacement(), at: expiresAt + 1))
        XCTAssertFalse(allowed(try makeNewTarget()))
    }

    func testSelectionRequestGateIsSingleFlight() throws {
        let requested = try makeNewTarget()

        XCTAssertEqual(
            WatchCodexConversationSelectionRequestGate.disposition(
                requested: requested,
                activeRequestID: nil,
                pendingTarget: nil
            ),
            .start
        )
        XCTAssertEqual(
            WatchCodexConversationSelectionRequestGate.disposition(
                requested: requested,
                activeRequestID: UUID(),
                pendingTarget: requested
            ),
            .alreadyPending
        )
        XCTAssertEqual(
            WatchCodexConversationSelectionRequestGate.disposition(
                requested: requested,
                activeRequestID: UUID(),
                pendingTarget: try makeExistingTarget()
            ),
            .busy
        )
        XCTAssertEqual(
            WatchCodexConversationSelectionRequestGate.disposition(
                requested: requested,
                activeRequestID: nil,
                pendingTarget: requested
            ),
            .busy
        )
    }

    func testCatalogRoundTripsWithoutAWorkingDirectory() throws {
        let catalog = try makeCatalog()
        let data = try JSONEncoder().encode(catalog)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("cwd"))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertEqual(try JSONDecoder().decode(WatchCodexConversationCatalog.self, from: data), catalog)
        XCTAssertEqual(catalog.entries.map(\.target.kind), [.existing, .newConversation])
        XCTAssertEqual(catalog.entries.map(\.threadID), ["thread-example", nil])
        XCTAssertEqual(
            catalog.entries.map(\.id),
            ["existing:thread-example", "new:workspace-example"]
        )
    }

    func testTargetRejectsUnsignedOrAmbiguousDestinationShapes() {
        XCTAssertNil(WatchCodexConversationTarget(
            leaseID: existingLeaseID,
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 9,
            threadID: nil,
            displayTitle: "Existing",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
        XCTAssertNil(WatchCodexConversationTarget(
            leaseID: newLeaseID,
            kind: .newConversation,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 1,
            threadID: "watch-invented-thread",
            displayTitle: "New conversation",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
        XCTAssertNil(WatchCodexConversationTarget(
            leaseID: existingLeaseID,
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: -1,
            entryRevision: 9,
            threadID: "thread-example",
            displayTitle: "Existing",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
        XCTAssertNil(WatchCodexConversationTarget(
            leaseID: existingLeaseID,
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 9,
            threadID: "thread-example",
            displayTitle: " Existing ",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
    }

    func testCatalogRejectsDuplicateThreadsAndMismatchedEpochs() throws {
        let target = try makeExistingTarget()
        let entry = try makeEntry(target: target)
        let duplicateTarget = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 10,
            threadID: target.threadID,
            displayTitle: "Duplicate",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
        let duplicateEntry = try XCTUnwrap(WatchCodexConversationEntry(
            threadID: duplicateTarget.threadID,
            title: duplicateTarget.displayTitle,
            workspaceLabel: duplicateTarget.workspaceLabel,
            state: .idle,
            updatedAtEpochMilliseconds: refreshedAt,
            canAcceptInput: true,
            entryRevision: duplicateTarget.entryRevision,
            target: duplicateTarget
        ))
        XCTAssertNil(WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: 4,
            entries: [entry, duplicateEntry],
            hasMore: false,
            refreshedAtEpochMilliseconds: refreshedAt
        ))

        let otherEpochTarget = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: UUID(),
            catalogRevision: 4,
            entryRevision: 11,
            threadID: "thread-other",
            displayTitle: "Other",
            workspaceID: "workspace-example",
            workspaceLabel: "Example",
            expiresAtEpochMilliseconds: expiresAt
        ))
        let otherEpochEntry = try makeEntry(target: otherEpochTarget)
        XCTAssertNil(WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: 4,
            entries: [otherEpochEntry],
            hasMore: false,
            refreshedAtEpochMilliseconds: refreshedAt
        ))
    }

    func testCatalogAcceptanceRejectsRollbackAndSameRevisionConflict() throws {
        let current = try makeOrderedCatalog(
            epoch: serverEpoch,
            revision: 4,
            leaseID: existingLeaseID,
            title: "Current"
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: nil,
                candidate: current
            ),
            .install
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: current,
                candidate: current
            ),
            .unchanged
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: current,
                candidate: try makeOrderedCatalog(
                    epoch: serverEpoch,
                    revision: 3,
                    leaseID: UUID(),
                    title: "Delayed"
                )
            ),
            .rejectRevisionRollback
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: current,
                candidate: try makeOrderedCatalog(
                    epoch: serverEpoch,
                    revision: 4,
                    leaseID: UUID(),
                    title: "Conflicting"
                )
            ),
            .rejectRevisionConflict
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: current,
                candidate: try makeOrderedCatalog(
                    epoch: serverEpoch,
                    revision: 5,
                    leaseID: UUID(),
                    title: "Newer"
                )
            ),
            .install
        )
        XCTAssertEqual(
            WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: current,
                candidate: try makeOrderedCatalog(
                    epoch: UUID(),
                    revision: 0,
                    leaseID: UUID(),
                    title: "Restarted Bridge"
                )
            ),
            .install
        )
    }

    func testInvalidTargetFailsDuringUntrustedDecoding() throws {
        let target = try makeExistingTarget()
        let encoded = try JSONEncoder().encode(target)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["threadID"] = "-unsafe"
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(WatchCodexConversationTarget.self, from: invalidData)
        )
    }

    func testCatalogRequestSnapshotSelectionAndResultAreBoundToCanonicalIDs() throws {
        let requestID = UUID()
        let catalog = try makeCatalog()
        let request = WatchRemoteProtocol.codexConversationCatalogRequestMessage(
            requestID: requestID
        )
        XCTAssertEqual(
            WatchRemoteProtocol.kind(from: request),
            .codexConversationCatalogRequest
        )
        XCTAssertEqual(
            WatchRemoteProtocol.codexConversationCatalogRequest(from: request),
            requestID
        )

        let snapshot = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationCatalogSnapshotMessage(
                catalog,
                requestID: requestID
            )
        )
        let decodedSnapshot = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationCatalogSnapshot(from: snapshot)
        )
        XCTAssertEqual(decodedSnapshot.catalog, catalog)
        XCTAssertEqual(decodedSnapshot.requestID, requestID)

        let target = try makeExistingTarget()
        let selection = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationTargetSelectMessage(
                requestID: requestID,
                target: target
            )
        )
        let decodedSelection = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationTargetSelection(from: selection)
        )
        XCTAssertEqual(decodedSelection.requestID, requestID)
        XCTAssertEqual(decodedSelection.target, target)

        let acceptedResult = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationTargetResultMessage(
                requestID: requestID,
                accepted: true,
                selectedTarget: target,
                detail: nil
            )
        )
        XCTAssertEqual(
            WatchRemoteProtocol.codexConversationTargetResult(from: acceptedResult)?.selectedTarget,
            target
        )
        XCTAssertNil(WatchRemoteProtocol.codexConversationTargetResultMessage(
            requestID: requestID,
            accepted: true,
            selectedTarget: nil
        ))

        var lowercasedRequest = request
        lowercasedRequest[WatchRemoteProtocol.Key.requestID.rawValue] = requestID.uuidString.lowercased()
        XCTAssertNil(
            WatchRemoteProtocol.codexConversationCatalogRequest(from: lowercasedRequest)
        )
    }

    func testSelectionResolutionAllowsNewTargetToBecomeAnIndependentExistingThread() throws {
        let catalog = try makeCatalog()
        let requested = try makeNewTarget()
        let created = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: requested.serverEpoch,
            catalogRevision: requested.catalogRevision,
            entryRevision: refreshedAt + 1,
            threadID: "thread-created-independently",
            displayTitle: "New Codex task",
            workspaceID: requested.workspaceID,
            workspaceLabel: requested.workspaceLabel,
            expiresAtEpochMilliseconds: expiresAt
        ))

        XCTAssertTrue(WatchCodexConversationSelectionResolution.isAccepted(
            requested: requested,
            selected: created,
            catalog: catalog,
            nowEpochMilliseconds: refreshedAt + 1
        ))

        let installed = try XCTUnwrap(
            catalog.installingImmediatelyCreatedConversation(
                created,
                nowEpochMilliseconds: refreshedAt + 1
            )
        )
        XCTAssertEqual(installed.revision, catalog.revision)
        XCTAssertEqual(installed.entries.first?.target, created)
        XCTAssertEqual(installed.entries.first?.updatedAtEpochMilliseconds, created.entryRevision)
        XCTAssertTrue(installed.entries.contains(where: {
            $0.target == created && $0.canAcceptInput
        }))
        let installedAgain = try XCTUnwrap(
            installed.installingImmediatelyCreatedConversation(
                created,
                nowEpochMilliseconds: refreshedAt + 2
            )
        )
        XCTAssertEqual(installedAgain, installed)
        XCTAssertTrue(WatchCodexConversationSelectionResolution.isSafeReplacement(
            requested: requested,
            selected: created,
            nowEpochMilliseconds: refreshedAt + 1
        ))
    }

    func testSelectionResolutionRejectsWorkspaceSwapOrExistingTargetReplacement() throws {
        let catalog = try makeCatalog()
        let requestedNew = try makeNewTarget()
        let wrongWorkspace = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: requestedNew.serverEpoch,
            catalogRevision: requestedNew.catalogRevision,
            entryRevision: refreshedAt + 1,
            threadID: "thread-created-in-wrong-workspace",
            displayTitle: "Wrong workspace",
            workspaceID: "workspace-wrong",
            workspaceLabel: requestedNew.workspaceLabel,
            expiresAtEpochMilliseconds: expiresAt
        ))
        XCTAssertFalse(WatchCodexConversationSelectionResolution.isAccepted(
            requested: requestedNew,
            selected: wrongWorkspace,
            catalog: catalog,
            nowEpochMilliseconds: refreshedAt + 1
        ))

        let requestedExisting = try makeExistingTarget()
        let replacementExisting = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: requestedExisting.serverEpoch,
            catalogRevision: requestedExisting.catalogRevision,
            entryRevision: requestedExisting.entryRevision,
            threadID: "thread-different",
            displayTitle: requestedExisting.displayTitle,
            workspaceID: requestedExisting.workspaceID,
            workspaceLabel: requestedExisting.workspaceLabel,
            expiresAtEpochMilliseconds: expiresAt
        ))
        XCTAssertFalse(WatchCodexConversationSelectionResolution.isAccepted(
            requested: requestedExisting,
            selected: replacementExisting,
            catalog: catalog,
            nowEpochMilliseconds: refreshedAt + 1
        ))
    }

    func testNewConversationOperationBookReusesIDAcrossCapabilityRefresh() throws {
        let operationID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let original = try makeNewTarget()
        let refreshed = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .newConversation,
            serverEpoch: UUID(),
            catalogRevision: original.catalogRevision + 1,
            entryRevision: original.entryRevision + 1,
            threadID: nil,
            displayTitle: original.displayTitle,
            workspaceID: original.workspaceID,
            workspaceLabel: original.workspaceLabel,
            expiresAtEpochMilliseconds: original.expiresAtEpochMilliseconds + 1
        ))
        var operations = WatchCodexConversationSelectionOperationBook.empty

        XCTAssertEqual(
            operations.operationID(for: original, creating: operationID),
            operationID
        )
        XCTAssertEqual(
            operations.operationID(for: refreshed, creating: UUID()),
            operationID
        )
        XCTAssertEqual(operations.pendingCount, 1)
    }

    func testNewConversationOperationBookKeepsUnknownWorkspacesUntilCompletion() throws {
        let first = try makeNewTarget()
        let second = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .newConversation,
            serverEpoch: first.serverEpoch,
            catalogRevision: first.catalogRevision,
            entryRevision: first.entryRevision,
            threadID: nil,
            displayTitle: first.displayTitle,
            workspaceID: "workspace-second",
            workspaceLabel: "Second workspace",
            expiresAtEpochMilliseconds: first.expiresAtEpochMilliseconds
        ))
        let firstID = UUID()
        let secondID = UUID()
        var operations = WatchCodexConversationSelectionOperationBook.empty

        XCTAssertEqual(operations.operationID(for: first, creating: firstID), firstID)
        XCTAssertEqual(operations.operationID(for: second, creating: secondID), secondID)
        XCTAssertEqual(operations.pendingCount, 2)

        operations.markCompleted(first)
        XCTAssertEqual(operations.pendingCount, 1)
        XCTAssertEqual(operations.operationID(for: second, creating: UUID()), secondID)
        XCTAssertNotEqual(operations.operationID(for: first, creating: UUID()), firstID)
    }

    func testNewConversationOperationStoreRoundTripsWithoutCapabilityData() throws {
        let suiteName = "WatchCodexConversationOperationStoreTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let target = try makeNewTarget()
        let operationID = UUID()
        var operations = WatchCodexConversationSelectionOperationBook.empty
        XCTAssertEqual(operations.operationID(for: target, creating: operationID), operationID)

        XCTAssertTrue(WatchCodexConversationSelectionOperationStore.save(
            operations,
            defaults: defaults
        ))
        XCTAssertEqual(
            WatchCodexConversationSelectionOperationStore.load(defaults: defaults),
            .loaded(operations)
        )
        let persisted = try XCTUnwrap(
            defaults.data(forKey: WatchCodexConversationSelectionOperationStore.defaultsKey)
        )
        let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(text.contains(target.leaseID.uuidString))
        XCTAssertFalse(text.contains(target.serverEpoch.uuidString))
        XCTAssertFalse(text.contains("cwd"))
    }

    func testConversationVoiceRequiresOneExactMacIssuedTarget() throws {
        let streamID = UUID()
        let target = try makeExistingTarget()
        let start = try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 7,
            intent: .codexConversation,
            codexConversationTarget: target
        ))
        let event = try XCTUnwrap(WatchRemoteProtocol.voiceEvent(from: start, kind: .voiceStart))
        XCTAssertEqual(event.intent, .codexConversation)
        XCTAssertEqual(event.codexConversationTarget, target)
        XCTAssertNil(event.codexTaskIdentity)

        XCTAssertNil(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 7,
            intent: .codexConversation
        ))
        XCTAssertNil(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 7,
            intent: .foregroundDictation,
            codexConversationTarget: target
        ))

        var inventedIdentity = start
        inventedIdentity[WatchRemoteProtocol.Key.threadID.rawValue] = "thread-invented"
        inventedIdentity[WatchRemoteProtocol.Key.turnID.rawValue] = "turn-invented"
        inventedIdentity[WatchRemoteProtocol.Key.taskRevision.rawValue] = 1
        XCTAssertNil(WatchRemoteProtocol.voiceEvent(
            from: inventedIdentity,
            kind: .voiceStart
        ))

        let unresolvedNewTarget = try makeNewTarget()
        XCTAssertNil(WatchRemoteProtocol.voiceStartMessage(
            streamID: UUID(),
            profileRevision: 7,
            intent: .codexConversation,
            codexConversationTarget: unresolvedNewTarget
        ))
        XCTAssertNil(WatchRemoteProtocol.voiceStartReply(
            accepted: true,
            streamID: UUID(),
            profileRevision: 7,
            intent: .codexConversation,
            codexConversationTarget: unresolvedNewTarget
        ))
    }

    func testConversationVoiceOutcomeCarriesAValidDraftLease() throws {
        let target = try makeExistingTarget()
        let draftID = UUID()
        let outcome = WatchVoiceOutcome(
            sessionID: UUID().uuidString,
            intent: .codexConversation,
            threadID: nil,
            kind: .draft,
            text: "发到所选会话",
            detail: "请确认",
            localeIdentifier: "zh-CN",
            draftID: draftID,
            codexConversationTarget: target,
            draftExpiresAtEpochMilliseconds: expiresAt - 1
        )
        XCTAssertTrue(outcome.hasValidWireShape)
        XCTAssertEqual(outcome.codexConversationDraftLease?.draftID, draftID)
        let message = try XCTUnwrap(WatchRemoteProtocol.voiceOutcomeMessage(outcome))
        XCTAssertEqual(WatchRemoteProtocol.voiceOutcome(from: message), outcome)

        let unbound = WatchVoiceOutcome(
            sessionID: UUID().uuidString,
            intent: .codexConversation,
            threadID: nil,
            kind: .draft,
            text: "发到未知目标",
            detail: nil,
            localeIdentifier: "zh-CN"
        )
        XCTAssertFalse(unbound.hasValidWireShape)
        XCTAssertNil(WatchRemoteProtocol.voiceOutcomeMessage(unbound))
    }

    func testDraftSubmissionPreservesExactTranscriptAndReceiptResolvesTarget() throws {
        let target = try makeExistingTarget()
        let submissionID = UUID()
        let draftID = UUID()
        let transcript = "  保留这段原文\n第二行  "
        let message = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationDraftSubmitMessage(
                submissionID: submissionID,
                draftID: draftID,
                target: target,
                transcript: transcript
            )
        )
        let decoded = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationDraftSubmit(from: message)
        )
        XCTAssertEqual(decoded.submissionID, submissionID)
        XCTAssertEqual(decoded.draftID, draftID)
        XCTAssertEqual(decoded.target, target)
        XCTAssertEqual(decoded.transcript, transcript)

        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftSubmitMessage(
            submissionID: submissionID,
            draftID: draftID,
            target: target,
            transcript: "  \n"
        ))
        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftSubmitMessage(
            submissionID: submissionID,
            draftID: draftID,
            target: target,
            transcript: String(
                repeating: "a",
                count: WatchCodexConversationWireValidation.maximumTranscriptCharacterCount + 1
            )
        ))

        let receipt = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationDraftReceiptMessage(
                accepted: true,
                submissionID: submissionID,
                draftID: draftID,
                resolvedTarget: target,
                detail: "已加入队列"
            )
        )
        let decodedReceipt = try XCTUnwrap(
            WatchRemoteProtocol.codexConversationDraftReceipt(from: receipt)
        )
        XCTAssertTrue(decodedReceipt.accepted)
        XCTAssertEqual(decodedReceipt.submissionID, submissionID)
        XCTAssertEqual(decodedReceipt.draftID, draftID)
        XCTAssertEqual(decodedReceipt.resolvedTarget, target)
        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftSubmit(from: receipt))

        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftReceiptMessage(
            accepted: false,
            submissionID: submissionID,
            draftID: draftID,
            resolvedTarget: target
        ))

        let unresolvedNewTarget = try makeNewTarget()
        XCTAssertNil(WatchCodexDraftLease(
            draftID: UUID(),
            target: unresolvedNewTarget,
            expiresAtEpochMilliseconds: unresolvedNewTarget.expiresAtEpochMilliseconds - 1
        ))
        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftSubmitMessage(
            submissionID: UUID(),
            draftID: UUID(),
            target: unresolvedNewTarget,
            transcript: "不能借新建入口隐式发送"
        ))

        var forgedNewTargetSubmit = message
        forgedNewTargetSubmit[
            WatchRemoteProtocol.Key.codexConversationTargetPayload.rawValue
        ] = try JSONEncoder().encode(unresolvedNewTarget).base64EncodedString()
        XCTAssertNil(WatchRemoteProtocol.codexConversationDraftSubmit(
            from: forgedNewTargetSubmit
        ))

        let forgedNewTargetOutcome = WatchVoiceOutcome(
            sessionID: UUID().uuidString,
            intent: .codexConversation,
            threadID: nil,
            kind: .draft,
            text: "不能签发草稿",
            detail: nil,
            localeIdentifier: "zh-CN",
            draftID: UUID(),
            codexConversationTarget: unresolvedNewTarget,
            draftExpiresAtEpochMilliseconds:
                unresolvedNewTarget.expiresAtEpochMilliseconds - 1
        )
        XCTAssertFalse(forgedNewTargetOutcome.hasValidWireShape)
    }

    func testBridgeWireMessageCarriesOptionalConversationCapabilityWithoutPaths() throws {
        let catalog = try makeCatalog()
        let message = WristBridgeWireMessage(
            type: "codexConversationCatalog",
            capabilities: [WristBridgeWireMessage.codexConversationsCapability],
            codexConversationCatalog: catalog
        )
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(WristBridgeWireMessage.codexConversationsCapability))
        XCTAssertFalse(json.contains("cwd"))
        XCTAssertEqual(
            try JSONDecoder().decode(WristBridgeWireMessage.self, from: data),
            message
        )
    }

    private func makeCatalog() throws -> WatchCodexConversationCatalog {
        let existingTarget = try makeExistingTarget()
        let newTarget = try makeNewTarget()
        return try XCTUnwrap(WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: 4,
            entries: [
                try makeEntry(target: existingTarget),
                try makeEntry(target: newTarget),
            ],
            hasMore: false,
            refreshedAtEpochMilliseconds: refreshedAt
        ))
    }

    private func makeOrderedCatalog(
        epoch: UUID,
        revision: Int,
        leaseID: UUID,
        title: String
    ) throws -> WatchCodexConversationCatalog {
        let target = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: leaseID,
            kind: .existing,
            serverEpoch: epoch,
            catalogRevision: revision,
            entryRevision: Int64(revision),
            threadID: "thread-ordered",
            displayTitle: title,
            workspaceID: "workspace-ordered",
            workspaceLabel: "Ordered workspace",
            expiresAtEpochMilliseconds: expiresAt
        ))
        let entry = try XCTUnwrap(WatchCodexConversationEntry(
            threadID: target.threadID,
            title: target.displayTitle,
            workspaceLabel: target.workspaceLabel,
            state: .idle,
            updatedAtEpochMilliseconds: refreshedAt,
            canAcceptInput: true,
            entryRevision: target.entryRevision,
            target: target
        ))
        return try XCTUnwrap(WatchCodexConversationCatalog(
            serverEpoch: epoch,
            revision: revision,
            entries: [entry],
            hasMore: false,
            refreshedAtEpochMilliseconds: refreshedAt
        ))
    }

    private func makeExistingTarget() throws -> WatchCodexConversationTarget {
        try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: existingLeaseID,
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 9,
            threadID: "thread-example",
            displayTitle: "Existing conversation",
            workspaceID: "workspace-example",
            workspaceLabel: "Example workspace",
            expiresAtEpochMilliseconds: expiresAt
        ))
    }

    private func makeNewTarget() throws -> WatchCodexConversationTarget {
        try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: newLeaseID,
            kind: .newConversation,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 1,
            threadID: nil,
            displayTitle: "New conversation",
            workspaceID: "workspace-example",
            workspaceLabel: "Example workspace",
            expiresAtEpochMilliseconds: expiresAt
        ))
    }

    private func makeEntry(
        target: WatchCodexConversationTarget
    ) throws -> WatchCodexConversationEntry {
        try XCTUnwrap(WatchCodexConversationEntry(
            threadID: target.threadID,
            title: target.displayTitle,
            workspaceLabel: target.workspaceLabel,
            state: .idle,
            updatedAtEpochMilliseconds: refreshedAt,
            canAcceptInput: true,
            entryRevision: target.entryRevision,
            target: target
        ))
    }
}

import XCTest
@testable import WristRemoteBridge

final class CodexConversationAuthorityTests: XCTestCase {
    func testAcceptedRecordingKeepsOriginalDestinationAcrossRefreshButNewStartsStayStrict() async throws {
        let authority = CodexConversationAuthority()
        let first = try await authority.makeCatalog(existing: [seed()],
            newConversationWorkspaces: [], hasMore: false, nowEpochMilliseconds: 1_000)
        let original = try XCTUnwrap(first.entries.first?.target)
        _ = try await authority.resolveSelection(original, nowEpochMilliseconds: 1_001)
        let refreshed = try await authority.makeCatalog(existing: [seed(updatedAt: 2_000)],
            newConversationWorkspaces: [], hasMore: false, nowEpochMilliseconds: 2_000)
        let renewed = try XCTUnwrap(refreshed.entries.first?.target)
        XCTAssertNotEqual(original.leaseID, renewed.leaseID)
        let resolved = try await authority.resolveActiveRecording(original, nowEpochMilliseconds: 2_001)
        XCTAssertEqual(resolved.target, original)
        XCTAssertEqual(resolved.threadID, original.threadID)
        XCTAssertEqual(resolved.cwd, seed().cwd)
        do {
            _ = try await authority.resolveSelection(original, nowEpochMilliseconds: 2_001)
            XCTFail("An old lease may finish its bound recording, not start a new one")
        } catch let error as CodexConversationAuthorityError {
            XCTAssertEqual(error, .staleCatalog)
        }
        _ = try await authority.makeCatalog(existing: [], newConversationWorkspaces: [],
            hasMore: false, nowEpochMilliseconds: 3_000)
        do {
            _ = try await authority.resolveActiveRecording(original, nowEpochMilliseconds: 3_001)
            XCTFail("A removed target may not receive old audio")
        } catch let error as CodexConversationAuthorityError {
            XCTAssertEqual(error, .invalidTarget)
        }
    }

    func testImmediateCreatedTargetCanFinishRecordingBeforeItIsPersisted() async throws {
        let authority = CodexConversationAuthority()
        _ = try await authority.makeCatalog(existing: [], newConversationWorkspaces: [
            .init(cwd: "/example/blank", workspaceLabel: "全新空白任务", workspaceID: "workspace-blank")
        ], hasMore: false, nowEpochMilliseconds: 1_000)
        let created = try await authority.registerCreatedConversation(
            threadID: "00000000-0000-0000-0000-000000000789", title: "空白任务",
            workspaceID: "workspace-blank", workspaceLabel: "全新空白任务",
            cwd: "/example/blank/independent", nowEpochMilliseconds: 1_100)
        let resolved = try await authority.resolveActiveRecording(created, nowEpochMilliseconds: 1_101)
        XCTAssertEqual(resolved.threadID, created.threadID)
        XCTAssertEqual(resolved.cwd, "/example/blank/independent")
    }
    func testBlankTaskCapabilityExistsWithoutAnyRecentConversation() async throws {
        let authority = CodexConversationAuthority()
        let catalog = try await authority.makeCatalog(existing: [], newConversationWorkspaces: [
            .init(cwd: "/example/private/blank-tasks", workspaceLabel: "全新空白任务",
                  workspaceID: WatchCodexConversationTarget.standaloneWorkspaceID)
        ], hasMore: false, nowEpochMilliseconds: 1_000)
        let entry = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertTrue(entry.target.isStandaloneNewConversation)
        XCTAssertEqual(entry.title, "全新空白任务")
        XCTAssertNil(entry.threadID)
        let resolved = try await authority.resolveSelection(entry.target, nowEpochMilliseconds: 1_001)
        XCTAssertNil(resolved.threadID)
        XCTAssertEqual(resolved.cwd, "/example/private/blank-tasks")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self).contains("/example/"))
    }
    func testRegistryCapacityDoesNotPoisonExistingWorkspaceIdentity() async throws {
        let authority = CodexConversationAuthority()
        let roots = (0..<128).map {
            CodexConversationWorkspaceSeed(cwd: "/example/workspace-\($0)", workspaceLabel: "示例项目")
        }
        let published = try await authority.makeCatalog(existing: [], newConversationWorkspaces: roots,
                                            hasMore: false, nowEpochMilliseconds: 1_000)
        let originalTarget = try XCTUnwrap(published.entries.first?.target)
        do {
            _ = try await authority.makeCatalog(existing: [], newConversationWorkspaces: [
                .init(cwd: "/example/extra-workspace", workspaceLabel: "另一个项目")
            ], hasMore: false, nowEpochMilliseconds: 2_000)
            XCTFail("A bounded registry must reject new identities when full")
        } catch let error as CodexConversationAuthorityError {
            XCTAssertEqual(error, .workspaceCapacityReached)
        }
        let stillValid = try await authority.resolveSelection(originalTarget,
                                                              nowEpochMilliseconds: 2_001)
        XCTAssertEqual(stillValid.target, originalTarget)
        let recovered = try await authority.makeCatalog(existing: [],
            newConversationWorkspaces: [roots[0]], hasMore: false, nowEpochMilliseconds: 3_000)
        XCTAssertEqual(recovered.entries.count, 1)
    }

    func testCatalogExposesLabelsButNeverWorkingDirectory() async throws {
        let authority = CodexConversationAuthority(
            serverEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let catalog = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )

        XCTAssertEqual(catalog.entries.filter { $0.target.kind == .existing }.count, 1)
        XCTAssertEqual(catalog.entries.filter { $0.target.kind == .newConversation }.count, 0)
        XCTAssertEqual(catalog.entries.first?.workspaceLabel, "示例项目")
        let encoded = try JSONEncoder().encode(catalog)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("/example/private/secret-project"))
        XCTAssertFalse(text.contains("cwd"))
    }

    func testNewConversationIsExposedOnlyForAnExplicitWorkspaceSeed() async throws {
        let authority = CodexConversationAuthority(
            serverEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let catalog = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [
                CodexConversationWorkspaceSeed(
                    cwd: "/canonical/project/root",
                    workspaceLabel: "独立项目"
                ),
            ],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )

        let newEntries = catalog.entries.filter { $0.target.kind == .newConversation }
        XCTAssertEqual(newEntries.count, 1)
        XCTAssertEqual(newEntries.first?.workspaceLabel, "独立项目")
        XCTAssertNil(newEntries.first?.threadID)

        let encoded = try JSONEncoder().encode(catalog)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/canonical/project/root"))
    }

    func testOldCatalogTargetCannotStartANewRecordingAfterRefresh() async throws {
        let authority = CodexConversationAuthority()
        let first = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let target = try XCTUnwrap(first.entries.first?.target)
        _ = try await authority.makeCatalog(
            existing: [seed(updatedAt: 2_000)],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 2_000
        )

        do {
            _ = try await authority.resolveSelection(target, nowEpochMilliseconds: 2_000)
            XCTFail("A target from a stale catalog must be rejected")
        } catch {
            XCTAssertEqual(error as? CodexConversationAuthorityError, .staleCatalog)
        }
    }

    func testWorkspaceIDsAreOpaqueDistinctAndStableForDuplicateLabels() async throws {
        let authority = CodexConversationAuthority(
            serverEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let firstSeed = CodexConversationCatalogSeed(
            threadID: "00000000-0000-0000-0000-000000000123",
            cwd: "/private/one/shared-name",
            title: "会话一",
            workspaceLabel: "同名项目",
            state: .idle,
            updatedAtEpochMilliseconds: 900,
            canAcceptInput: true
        )
        let secondSeed = CodexConversationCatalogSeed(
            threadID: "00000000-0000-0000-0000-000000000456",
            cwd: "/private/two/shared-name",
            title: "会话二",
            workspaceLabel: "同名项目",
            state: .idle,
            updatedAtEpochMilliseconds: 800,
            canAcceptInput: true
        )
        let firstCatalog = try await authority.makeCatalog(
            existing: [firstSeed, secondSeed],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let secondCatalog = try await authority.makeCatalog(
            existing: [firstSeed, secondSeed],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 2_000
        )

        func workspaceIDs(
            in catalog: WatchCodexConversationCatalog
        ) -> [String: String] {
            Dictionary(uniqueKeysWithValues: catalog.entries.compactMap { entry in
                guard entry.target.kind == .existing,
                      let threadID = entry.threadID
                else { return nil }
                return (threadID, entry.target.workspaceID)
            })
        }

        let firstIDs = workspaceIDs(in: firstCatalog)
        let secondIDs = workspaceIDs(in: secondCatalog)
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertNotEqual(firstIDs[firstSeed.threadID], firstIDs[secondSeed.threadID])
        for identifier in firstIDs.values {
            XCTAssertTrue(identifier.hasPrefix("workspace-"))
            XCTAssertFalse(identifier.contains("private"))
            XCTAssertFalse(identifier.contains("shared-name"))
            XCTAssertFalse(identifier.contains("同名项目"))
        }
    }

    func testMacIssuedWorkspaceIDSurvivesAuthorityRestart() async throws {
        let stableWorkspaceID = "workspace-0123456789abcdef01234567"
        let seed = CodexConversationWorkspaceSeed(
            cwd: "/canonical/project/root",
            workspaceLabel: "独立项目",
            workspaceID: stableWorkspaceID
        )
        let firstAuthority = CodexConversationAuthority(serverEpoch: UUID())
        let restartedAuthority = CodexConversationAuthority(serverEpoch: UUID())

        let first = try await firstAuthority.makeCatalog(
            existing: [],
            newConversationWorkspaces: [seed],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let restarted = try await restartedAuthority.makeCatalog(
            existing: [],
            newConversationWorkspaces: [seed],
            hasMore: false,
            nowEpochMilliseconds: 2_000
        )

        XCTAssertEqual(first.entries.first?.target.workspaceID, stableWorkspaceID)
        XCTAssertEqual(restarted.entries.first?.target.workspaceID, stableWorkspaceID)
        XCTAssertNotEqual(first.serverEpoch, restarted.serverEpoch)
    }

    func testManagedWorktreeAliasKeepsCanonicalWorkspaceIdentityAcrossRestart() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workspace-identities-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let storeURL = fixture.appendingPathComponent("identities.json")
        let store = CodexWorkspaceIdentityStore(fileURL: storeURL)
        let stableWorkspaceID = "workspace-0123456789abcdef01234567"
        let canonicalRoot = "/private/example/project"
        let worktree = "/private/example/Library/Application Support/WristRemoteBridge/CodexWorktrees/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let rootSeed = CodexConversationWorkspaceSeed(
            cwd: canonicalRoot,
            workspaceLabel: "示例项目",
            workspaceID: stableWorkspaceID
        )

        let firstAuthority = CodexConversationAuthority(
            serverEpoch: UUID(),
            workspaceIdentityStore: store
        )
        _ = try await firstAuthority.makeCatalog(
            existing: [],
            newConversationWorkspaces: [rootSeed],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let created = try await firstAuthority.registerCreatedConversation(
            threadID: "00000000-0000-0000-0000-000000000789",
            title: "新建任务",
            workspaceID: stableWorkspaceID,
            workspaceLabel: "示例项目",
            cwd: worktree,
            nowEpochMilliseconds: 1_100
        )
        XCTAssertEqual(created.workspaceID, stableWorkspaceID)

        let restartedAuthority = CodexConversationAuthority(
            serverEpoch: UUID(),
            workspaceIdentityStore: store
        )
        let restarted = try await restartedAuthority.makeCatalog(
            existing: [CodexConversationCatalogSeed(
                threadID: "00000000-0000-0000-0000-000000000789",
                cwd: worktree,
                title: "新建任务",
                workspaceLabel: "示例项目",
                state: .idle,
                updatedAtEpochMilliseconds: 2_000,
                canAcceptInput: true,
                workspaceID: "workspace-conflicting-derived-path-id"
            )],
            newConversationWorkspaces: [CodexConversationWorkspaceSeed(
                cwd: worktree,
                workspaceLabel: "示例项目",
                workspaceID: "workspace-conflicting-derived-path-id"
            )],
            hasMore: false,
            nowEpochMilliseconds: 2_000
        )

        let existing = try XCTUnwrap(
            restarted.entries.first { $0.target.kind == .existing }
        )
        XCTAssertEqual(existing.target.workspaceID, stableWorkspaceID)
        XCTAssertEqual(
            restarted.entries.filter { $0.target.kind == .newConversation }.count,
            1
        )
        XCTAssertEqual(
            restarted.entries.first { $0.target.kind == .newConversation }?.target.workspaceID,
            stableWorkspaceID
        )
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testDraftIsBoundToExactTargetTextAndSubmissionIdentity() async throws {
        let authority = CodexConversationAuthority()
        let catalog = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let target = try XCTUnwrap(catalog.entries.first?.target)
        let lease = try await authority.issueDraft(
            target: target,
            transcript: "继续检查这项任务",
            nowEpochMilliseconds: 1_100
        )
        let submissionID = UUID()
        let resolved = try await authority.resolveDraftSubmission(
            draftID: lease.draftID,
            target: target,
            transcript: "继续检查这项任务",
            submissionID: submissionID,
            nowEpochMilliseconds: 1_200
        )
        XCTAssertEqual(resolved.threadID, seed().threadID)
        XCTAssertEqual(resolved.cwd, seed().cwd)

        do {
            _ = try await authority.resolveDraftSubmission(
                draftID: lease.draftID,
                target: target,
                transcript: "换成另一句话",
                submissionID: submissionID,
                nowEpochMilliseconds: 1_300
            )
            XCTFail("Mutated text must not pass draft validation")
        } catch {
            XCTAssertEqual(error as? CodexConversationAuthorityError, .draftContentMismatch)
        }

        do {
            _ = try await authority.resolveDraftSubmission(
                draftID: lease.draftID,
                target: target,
                transcript: "继续检查这项任务",
                submissionID: UUID(),
                nowEpochMilliseconds: 1_300
            )
            XCTFail("A draft cannot be rebound to a different submission")
        } catch {
            XCTAssertEqual(error as? CodexConversationAuthorityError, .draftSubmissionMismatch)
        }
    }

    func testUnresolvedNewConversationCannotIssueOrSubmitDraft() async throws {
        let authority = CodexConversationAuthority()
        let catalog = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [CodexConversationWorkspaceSeed(
                cwd: "/canonical/project/root",
                workspaceLabel: "独立项目"
            )],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let unresolvedNewTarget = try XCTUnwrap(catalog.entries.first(where: {
            $0.target.kind == .newConversation
        })?.target)

        do {
            _ = try await authority.issueDraft(
                target: unresolvedNewTarget,
                transcript: "不得借草稿隐式创建任务",
                nowEpochMilliseconds: 1_100
            )
            XCTFail("A new-conversation capability must be selection-only")
        } catch {
            XCTAssertEqual(error as? CodexConversationAuthorityError, .invalidTarget)
        }

        do {
            _ = try await authority.resolveDraftSubmission(
                draftID: UUID(),
                target: unresolvedNewTarget,
                transcript: "不得借提交隐式创建任务",
                submissionID: UUID(),
                nowEpochMilliseconds: 1_200
            )
            XCTFail("A new-conversation capability must not reach draft submission")
        } catch {
            XCTAssertEqual(error as? CodexConversationAuthorityError, .invalidTarget)
        }

        let existingTarget = try XCTUnwrap(catalog.entries.first(where: {
            $0.target.kind == .existing
        })?.target)
        let existingLease = try await authority.issueDraft(
            target: existingTarget,
            transcript: "现有会话仍可签发草稿",
            nowEpochMilliseconds: 1_300
        )
        XCTAssertEqual(existingLease.target, existingTarget)
    }

    func testExpiredDraftFailsClosed() async throws {
        let authority = CodexConversationAuthority()
        let catalog = try await authority.makeCatalog(
            existing: [seed()],
            newConversationWorkspaces: [],
            hasMore: false,
            nowEpochMilliseconds: 1_000
        )
        let target = try XCTUnwrap(catalog.entries.first?.target)
        let lease = try await authority.issueDraft(
            target: target,
            transcript: "测试草稿",
            nowEpochMilliseconds: 1_100
        )

        do {
            _ = try await authority.resolveDraftSubmission(
                draftID: lease.draftID,
                target: target,
                transcript: "测试草稿",
                submissionID: UUID(),
                nowEpochMilliseconds: lease.expiresAtEpochMilliseconds
            )
            XCTFail("Expired drafts must not be accepted")
        } catch {
            XCTAssertTrue([
                CodexConversationAuthorityError.expiredDraft,
                .invalidDraft,
            ].contains(error as? CodexConversationAuthorityError))
        }
    }

    private func seed(updatedAt: Int64 = 900) -> CodexConversationCatalogSeed {
        CodexConversationCatalogSeed(
            threadID: "00000000-0000-0000-0000-000000000123",
            cwd: "/example/private/secret-project",
            title: "测试会话",
            workspaceLabel: "示例项目",
            state: .idle,
            updatedAtEpochMilliseconds: updatedAt,
            canAcceptInput: true
        )
    }
}

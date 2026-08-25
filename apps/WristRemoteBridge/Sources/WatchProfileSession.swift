import Foundation

enum WatchProfileUpdateDecision: Equatable {
    case accept(WatchActionProfileWire)
    case alreadyReady(revision: Int)
    case reject(revision: Int, detail: String)
}

/// A profile swap must not invalidate the revision that owns a live voice
/// stream. The caller can retry after the stream has finished.
enum WatchProfileRuntimeUpdatePolicy {
    static func retryReason(
        hasActiveVoiceSession: Bool
    ) -> WatchProfileUpdateRetryReason? {
        hasActiveVoiceSession ? .voiceActive : nil
    }

    static func acceptsUpdate(hasActiveVoiceSession: Bool) -> Bool {
        retryReason(hasActiveVoiceSession: hasActiveVoiceSession) == nil
    }

    static func retryReason(
        for voiceSession: BridgeVoiceSession
    ) -> WatchProfileUpdateRetryReason? {
        retryReason(hasActiveVoiceSession: voiceSession.hasInFlightSession)
    }
}

enum WatchProfileRuntimeInstallResult: Equatable {
    case accepted
    case rejected
    case retryable(WatchProfileUpdateRetryReason)

    var isAccepted: Bool {
        self == .accepted
    }
}

/// Global persistence gate shared by LAN and Internet profile updates. The
/// per-connection session gate cannot by itself prevent a freshly reinstalled
/// phone from replacing a newer profile already stored on the Mac.
enum WatchPersistedProfileGate {
    static func decide(
        candidate: WatchActionProfileWire,
        current: WatchActionProfileWire?
    ) -> WatchProfileUpdateDecision {
        guard let candidate = try? candidate.validatedAndNormalized() else {
            return .reject(revision: candidate.revision, detail: "映射数据无效。")
        }
        guard let current else { return .accept(candidate) }
        guard let current = try? current.validatedAndNormalized() else {
            return .reject(revision: candidate.revision, detail: "Mac 已保存的映射无效。")
        }
        if candidate.revision < current.revision {
            return .reject(revision: candidate.revision, detail: "映射版本已过期。")
        }
        if candidate.revision == current.revision {
            return candidate == current
                ? .alreadyReady(revision: candidate.revision)
                : .reject(revision: candidate.revision, detail: "同一版本的映射内容不一致。")
        }
        return .accept(candidate)
    }
}

/// A per-connection acknowledgement gate. Watch edges are accepted only when
/// they carry the exact revision installed for that encrypted connection.
struct WatchProfileSession: Equatable {
    private(set) var acceptedProfile: WatchActionProfileWire?
    private(set) var pendingProfile: WatchActionProfileWire?

    static func acceptsProfileUpdateSource(inputSource: String?) -> Bool {
        inputSource == BridgeWireMessage.appleWatchInputSource
    }

    mutating func begin(_ profile: WatchActionProfileWire) -> WatchProfileUpdateDecision {
        if pendingProfile != nil {
            return .reject(revision: profile.revision, detail: "映射正在更新，请稍后重试。")
        }
        if let acceptedProfile {
            if profile.revision < acceptedProfile.revision {
                return .reject(revision: profile.revision, detail: "映射版本已过期。")
            }
            if profile.revision == acceptedProfile.revision {
                return profile == acceptedProfile
                    ? .alreadyReady(revision: profile.revision)
                    : .reject(revision: profile.revision, detail: "同一版本的映射内容不一致。")
            }
        }
        pendingProfile = profile
        return .accept(profile)
    }

    mutating func complete(revision: Int, succeeded: Bool) -> Bool? {
        guard let pendingProfile, pendingProfile.revision == revision else { return nil }
        self.pendingProfile = nil
        if succeeded {
            acceptedProfile = pendingProfile
        }
        return succeeded
    }

    func accepts(inputSource: String?, revision: Int?) -> Bool {
        guard pendingProfile == nil,
              inputSource == BridgeWireMessage.appleWatchInputSource,
              let revision,
              revision == acceptedProfile?.revision
        else { return false }
        return true
    }

    mutating func reset() {
        acceptedProfile = nil
        pendingProfile = nil
    }
}

struct BridgeVoiceSession: Equatable {
    struct Identity: Equatable {
        let sessionID: UUID
        let profileRevision: Int
    }

    enum Phase: Equatable {
        case idle
        case starting(Identity)
        case active(Identity)
    }

    private(set) var phase: Phase = .idle

    var hasInFlightSession: Bool {
        phase != .idle
    }

    mutating func begin(
        sessionID: String?,
        inputSource: String?,
        profileRevision: Int?,
        acceptedProfileRevision: Int?
    ) -> Bool {
        guard case .idle = phase,
              inputSource == BridgeWireMessage.appleWatchInputSource,
              let rawSessionID = sessionID,
              let sessionID = UUID(uuidString: rawSessionID),
              let profileRevision,
              profileRevision >= 0,
              profileRevision == acceptedProfileRevision
        else { return false }
        phase = .starting(Identity(
            sessionID: sessionID,
            profileRevision: profileRevision
        ))
        return true
    }

    mutating func completeStart(succeeded: Bool) -> Identity? {
        guard case let .starting(identity) = phase else { return nil }
        phase = succeeded ? .active(identity) : .idle
        return identity
    }

    func acceptsAudio(
        sessionID: String?,
        inputSource: String?,
        profileRevision: Int?,
        acceptedProfileRevision: Int?
    ) -> Bool {
        guard case let .active(identity) = phase else { return false }
        return Self.matches(
            identity,
            sessionID: sessionID,
            inputSource: inputSource,
            profileRevision: profileRevision,
            acceptedProfileRevision: acceptedProfileRevision
        )
    }

    mutating func stop(
        sessionID: String?,
        inputSource: String? = nil,
        profileRevision: Int? = nil,
        acceptedProfileRevision: Int? = nil,
        force: Bool = false
    ) -> Bool {
        let identity: Identity
        switch phase {
        case .idle:
            return false
        case let .starting(value), let .active(value):
            identity = value
        }
        guard force || Self.matches(
            identity,
            sessionID: sessionID,
            inputSource: inputSource,
            profileRevision: profileRevision,
            acceptedProfileRevision: acceptedProfileRevision
        ) else { return false }
        phase = .idle
        return true
    }

    private static func matches(
        _ identity: Identity,
        sessionID: String?,
        inputSource: String?,
        profileRevision: Int?,
        acceptedProfileRevision: Int?
    ) -> Bool {
        guard inputSource == BridgeWireMessage.appleWatchInputSource,
              let sessionID,
              UUID(uuidString: sessionID) == identity.sessionID,
              profileRevision == identity.profileRevision,
              acceptedProfileRevision == identity.profileRevision
        else { return false }
        return true
    }
}

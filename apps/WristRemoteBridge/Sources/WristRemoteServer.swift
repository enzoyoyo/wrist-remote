import CryptoKit
import Darwin
import Foundation
import Network

enum WristRemoteHandshake {
    static let protocolID = BridgeWireMessage.wristRemoteProtocolID
    static let clientRole = BridgeWireMessage.wristRemoteClientRole
    static let serverRole = BridgeWireMessage.wristRemoteServerRole

    static func acceptsClient(_ message: BridgeWireMessage) -> Bool {
        message.type == "hello"
            && message.protocolID == protocolID
            && message.clientRole == clientRole
            && message.serverRole == nil
            && message.publicKey != nil
            && message.deviceName == nil
            && message.identityPublicKey == nil
            && message.identitySignature == nil
            && message.serverIdentityVersion == nil
            && message.serverIdentityPublicKey == nil
            && message.serverIdentitySignature == nil
            && message.serverIdentityPinned == nil
            && Set(message.capabilities ?? []).isSuperset(of: [
                BridgeWireMessage.secureSequenceCapability,
                BridgeWireMessage.audioDeliveryReceiptsCapability,
            ])
    }

    static func acceptsPersistedClientApproval(
        identityFingerprint: String?,
        persistenceSucceeded: Bool
    ) -> Bool {
        identityFingerprint != nil && persistenceSucceeded
    }
}

enum WristRemoteCodexTargetValidator {
    static func accepts(
        _ identity: WatchCodexTaskIdentity?,
        snapshot: WatchCodexTaskSnapshot?
    ) -> Bool {
        identity != nil
            && WatchCodexTaskIdentity(snapshot) == identity
            && snapshot?.state == .completed
    }
}

struct WristRemoteLocalBindCandidate: Equatable {
    let interfaceName: String
    let host: NWEndpoint.Host
}

enum WristRemoteListenerBindingPolicy {
    static func endpoint(
        from candidates: [WristRemoteLocalBindCandidate],
        port rawPort: UInt16
    ) -> NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { return nil }
        let ranked = candidates.compactMap { candidate -> (Int, Int, String, NWEndpoint.Host)? in
            guard let interfaceRank = interfaceRank(candidate.interfaceName),
                  let addressRank = addressRank(candidate.host)
            else { return nil }
            return (addressRank, interfaceRank, candidate.interfaceName, candidate.host)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return String(describing: $0.3) < String(describing: $1.3)
        }
        guard let host = ranked.first?.3 else { return nil }
        return .hostPort(host: host, port: port)
    }

    static func currentEndpoint(port: UInt16) -> NWEndpoint? {
        endpoint(from: currentCandidates(), port: port)
    }

    private static func addressRank(_ host: NWEndpoint.Host) -> Int? {
        switch host {
        case let .ipv4(address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return nil }
            if bytes[0] == 10
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) {
                return 0
            }
            if bytes[0] == 169 && bytes[1] == 254 { return 1 }
            return nil
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 16 && (bytes[0] & 0xfe) == 0xfc ? 2 : nil
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func interfaceRank(_ name: String) -> Int? {
        if name.hasPrefix("en") { return 0 }
        if name.hasPrefix("bridge") { return 1 }
        if name.hasPrefix("awdl") { return 2 }
        if name.hasPrefix("llw") { return 3 }
        return nil
    }

    private static func currentCandidates() -> [WristRemoteLocalBindCandidate] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var result: [WristRemoteLocalBindCandidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let address = interface.ifa_addr
            else { continue }
            let name = String(cString: interface.ifa_name)
            guard interfaceRank(name) != nil else { continue }

            let host: NWEndpoint.Host?
            switch address.pointee.sa_family {
            case UInt8(AF_INET):
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee.sin_addr
                let data = withUnsafeBytes(of: value) { Data($0) }
                host = IPv4Address(data).map(NWEndpoint.Host.ipv4)
            case UInt8(AF_INET6):
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee.sin6_addr
                let data = withUnsafeBytes(of: value) { Data($0) }
                host = IPv6Address(data).map(NWEndpoint.Host.ipv6)
            default:
                host = nil
            }
            if let host { result.append(.init(interfaceName: name, host: host)) }
        }
        return result
    }
}

struct WristRemoteTailnetBindCandidate: Equatable {
    let interfaceName: String
    let host: NWEndpoint.Host
}

enum WristRemoteTailnetBindingPolicy {
    static func endpoint(
        from candidates: [WristRemoteTailnetBindCandidate],
        port rawPort: UInt16
    ) -> NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { return nil }
        let ranked = candidates.compactMap {
            candidate -> (Int, String, NWEndpoint.Host)? in
            guard candidate.interfaceName.hasPrefix("utun"),
                  let rank = addressRank(candidate.host)
            else { return nil }
            return (rank, candidate.interfaceName, candidate.host)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return String(describing: $0.2) < String(describing: $1.2)
        }
        guard let host = ranked.first?.2 else { return nil }
        return .hostPort(host: host, port: port)
    }

    static func currentEndpoint(port: UInt16) -> NWEndpoint? {
        endpoint(from: currentCandidates(), port: port)
    }

    static func permitsPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return addressRank(host) != nil
    }

    static func isTailscaleIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 100 && (64 ... 127).contains(bytes[1])
    }

    static func isTailscaleIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0] == 0xfd
            && bytes[1] == 0x7a
            && bytes[2] == 0x11
            && bytes[3] == 0x5c
            && bytes[4] == 0xa1
            && bytes[5] == 0xe0
    }

    private static func addressRank(_ host: NWEndpoint.Host) -> Int? {
        switch host {
        case let .ipv4(address):
            return isTailscaleIPv4([UInt8](address.rawValue)) ? 0 : nil
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            if isTailscaleIPv6(bytes) { return 1 }
            let isMappedIPv4 = bytes.count == 16
                && bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
                && isTailscaleIPv4(Array(bytes[12 ..< 16]))
            return isMappedIPv4 ? 2 : nil
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func currentCandidates() -> [WristRemoteTailnetBindCandidate] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var result: [WristRemoteTailnetBindCandidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let address = interface.ifa_addr
            else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("utun") else { continue }

            let host: NWEndpoint.Host?
            switch address.pointee.sa_family {
            case UInt8(AF_INET):
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee.sin_addr
                let data = withUnsafeBytes(of: value) { Data($0) }
                host = IPv4Address(data).map(NWEndpoint.Host.ipv4)
            case UInt8(AF_INET6):
                let value = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee.sin6_addr
                let data = withUnsafeBytes(of: value) { Data($0) }
                host = IPv6Address(data).map(NWEndpoint.Host.ipv6)
            default:
                host = nil
            }
            if let host { result.append(.init(interfaceName: name, host: host)) }
        }
        return result
    }
}

enum WristRemotePeerAccessPolicy {
    static func permits(
        _ endpoint: NWEndpoint,
        localPhysicalIPv6Addresses: [Data] = []
    ) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return permits(host, localPhysicalIPv6Addresses: localPhysicalIPv6Addresses)
    }

    static func permits(
        _ host: NWEndpoint.Host,
        localPhysicalIPv6Addresses: [Data] = []
    ) -> Bool {
        _ = localPhysicalIPv6Addresses
        switch host {
        case let .ipv4(address):
            return isPermittedIPv4([UInt8](address.rawValue))
        case let .ipv6(address):
            return isPermittedIPv6([UInt8](address.rawValue))
        case .name:
            // An accepted inbound connection should already have a numeric
            // peer address. Never resolve or trust a hostname here.
            return false
        @unknown default:
            return false
        }
    }

    private static func isPermittedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10
            || bytes[0] == 127
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }

    private static func isPermittedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if WristRemoteTailnetBindingPolicy.isTailscaleIPv6(bytes) { return false }
        let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let mappedIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
            && isPermittedIPv4(Array(bytes[12 ..< 16]))
        return loopback || linkLocal || uniqueLocal || mappedIPv4
    }

}

struct WristRemoteClientSnapshot: Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let transport: String
}

/// Shared by the live attach/approve/close paths, not just test fixtures.
enum WristRemoteClientAdmissionPolicy {
    static func canApprove(identity: String, approvedIdentities: [String]) -> Bool {
        approvedIdentities.filter { $0 != identity }.count < WristRemoteServer.maximumApprovedClientCount
    }

    static func replaces(existingIdentity: String?, newlyApprovedIdentity: String?) -> Bool {
        guard let existingIdentity, let newlyApprovedIdentity else { return false }
        return existingIdentity == newlyApprovedIdentity
    }

    static func mayPresentApproval(hasPendingApproval: Bool) -> Bool { !hasPendingApproval }

    static func resetsProfile(wasApproved: Bool, remainingApprovedCount: Int) -> Bool {
        wasApproved && remainingApprovedCount == 0
    }
}

enum WristRemoteLocalListenerLifecyclePolicy {
    static func needsRebind(previous: NWEndpoint?, current: NWEndpoint?) -> Bool { previous != current }

    static func retryDelaySeconds(hasLANListener: Bool, hasHTTPListener: Bool) -> TimeInterval {
        hasLANListener && hasHTTPListener ? 15 : 5
    }
}

/// Compatibility press/release streams need one owner while Mac-side double
/// and long-press timers are pending. Semantic HTTP commands do not use this.
struct WristRemoteRawGestureOwnership {
    private(set) var ownerID: ObjectIdentifier?
    private(set) var pressedButtons: Set<WristRemoteButton> = []
    private var ownedButtons: Set<WristRemoteButton> = []

    mutating func accept(owner: ObjectIdentifier, button: WristRemoteButton, phase: WristRemoteButtonPhase) -> Bool {
        guard ownerID == nil || ownerID == owner else { return false }
        switch phase {
        case .press:
            guard !pressedButtons.contains(button) else { return false }
            ownerID = owner
            pressedButtons.insert(button)
            ownedButtons.insert(button)
        case .release:
            guard ownerID == owner, pressedButtons.remove(button) != nil else { return false }
        }
        return true
    }

    mutating func release(owner: ObjectIdentifier) -> Set<WristRemoteButton> {
        guard ownerID == owner else { return [] }
        let buttons = ownedButtons
        ownerID = nil
        pressedButtons.removeAll()
        ownedButtons.removeAll()
        return buttons
    }
}

struct WristRemoteVoiceOwnership {
    private(set) var ownerID: ObjectIdentifier?
    private(set) var sessionID: String?
    private(set) var ticket: UUID?

    mutating func reserve(owner: ObjectIdentifier, session: String) -> UUID? {
        guard ownerID == nil, WristDirectBridgeProtocol.isCanonicalSessionID(session) else { return nil }
        ownerID = owner
        sessionID = session
        let ticket = UUID()
        self.ticket = ticket
        return ticket
    }

    func matches(owner: ObjectIdentifier, session: String?, ticket: UUID? = nil) -> Bool {
        ownerID == owner && session != nil && sessionID == session && (ticket == nil || self.ticket == ticket)
    }

    mutating func release(owner: ObjectIdentifier, session: String?, ticket: UUID? = nil) {
        guard matches(owner: owner, session: session, ticket: ticket) else { return }
        ownerID = nil
        sessionID = nil
        self.ticket = nil
    }
}

final class WristRemoteServer {
    static let serviceType = "_wristremote._tcp"
    static let sessionSalt = "WristRemoteBridge nearby session"
    static let port: UInt16 = 60_927
    static let maximumUnauthenticatedClientCount = 8
    static let maximumApprovedClientCount = 4
    static let handshakeTimeoutSeconds: TimeInterval = 30
    static let identityUnavailableDetail =
        "无法读取腕上遥控桥的长期身份；请解锁 Mac 后重试。为保护已配对设备，服务不会自动更换身份。"

    enum Status: Equatable {
        case stopped
        case loadingIdentity
        case starting
        case ready
        case connected(String)
        case identityUnavailable(String)
        case failed(String)
    }

    enum TailnetStatus: Equatable {
        case disabled
        case waiting
        case starting
        case ready
        case failed(String)
    }

    private enum InboundRoute: Equatable {
        case lan
        case tailnet
        case directHTTP
    }

    typealias ApprovalHandler = (
        _ deviceName: String,
        _ pairingCode: String,
        _ fingerprint: String?,
        _ completion: @escaping (Bool) -> Void
    ) -> Void

    typealias IdentityLoader = () -> P256.Signing.PrivateKey?

    private let queue = DispatchQueue(label: "WristRemoteBridge.server", qos: .userInitiated)
    private let identityQueue = DispatchQueue(
        label: "WristRemoteBridge.server-identity",
        qos: .userInitiated
    )
    private let identityLoader: IdentityLoader
    private let localEndpointProvider: (UInt16) -> NWEndpoint?
    private let advertisesBonjour: Bool
    private var serverIdentityPrivateKey: P256.Signing.PrivateKey?
    private var identityLoadGeneration = 0
    private var isIdentityLoadInProgress = false
    private var shouldRun = false
    private var listener: NWListener?
    private var lanLocalEndpoint: NWEndpoint?
    private var lanRetryWorkItem: DispatchWorkItem?
    private var directHTTPServer: WristDirectBridgeHTTPServer?
    private var directHTTPEndpoint: NWEndpoint?
    private var directBridgeConfiguration: WristDirectBridgeConfiguration?
    private var currentWatchProfile: WatchActionProfileWire?
    private var pendingApprovalID: ObjectIdentifier?
    private var rawGestureOwnership = WristRemoteRawGestureOwnership()
    private var rawGestureReapWorkItem: DispatchWorkItem?
    private var voiceOwnership = WristRemoteVoiceOwnership()
    private var tailnetListener: NWListener?
    private var tailnetLocalEndpoint: NWEndpoint?
    private var tailnetRetryWorkItem: DispatchWorkItem?
    private var tailnetAccessEnabled = false
    private var clients: [ObjectIdentifier: WristRemoteServerClient] = [:]
    private var clientRoutes: [ObjectIdentifier: InboundRoute] = [:]
    private var applicationTitles: [String: String] = [:]
    private var codexTaskSnapshot: WatchCodexTaskSnapshot?
    private var codexTaskStateRevision = 0
    private var codexConversationCatalog: WatchCodexConversationCatalog?
    private var speechLocaleIdentifier = "zh-CN"
    private var internetRelayProvisioning: String?

    var onStatus: ((Status) -> Void)?
    var onTailnetStatus: ((TailnetStatus) -> Void)?
    var onDirectBridgeConfiguration: ((WristDirectBridgeConfiguration?) -> Void)?
    var onClientSnapshots: (([WristRemoteClientSnapshot]) -> Void)?
    var onApprovalRequested: ApprovalHandler?
    var onApprovalCancelled: (() -> Void)?
    var isIdentityTrusted: ((String) -> Bool)?
    var onIdentityApproved: ((String) -> Bool)?
    var onWatchProfileUpdate: ((
        WatchActionProfileWire,
        @escaping (WatchProfileRuntimeInstallResult) -> Void
    ) -> Void)?
    var onWatchButtonEvent: ((WristRemoteButton, WristRemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onWatchButtonTrigger: ((WristRemoteButton, WristRemoteTrigger, Int, Int64, @escaping (Bool) -> Void) -> Void)?
    var onWatchButtonCancel: ((WristRemoteButton) -> Void)?
    var onProfileReset: (() -> Void)?
    var onVoiceStart: ((
        String?,
        WatchVoiceIntent,
        WatchCodexTaskIdentity?,
        WatchCodexConversationTarget?,
        @escaping (Bool) -> Void
    ) -> Void)?
    var onVoiceStop: ((String?) -> Void)?
    var onVoiceCancel: ((String?) -> Void)?
    var onAudio: ((String?, [Int16]) -> Bool)?
    var onCodexReplySubmit: ((
        UUID,
        WatchCodexTaskIdentity,
        String,
        @escaping (Bool, String?) -> Void
    ) -> Void)?
    var onCodexConversationCatalogRequest: ((
        UUID,
        @escaping (WatchCodexConversationCatalog?, String?) -> Void
    ) -> Void)?
    var onCodexConversationTargetSelect: ((
        UUID,
        WatchCodexConversationTarget,
        @escaping (Bool, WatchCodexConversationTarget?, String?) -> Void
    ) -> Void)?
    var onCodexConversationDraftSubmit: ((
        UUID,
        UUID,
        WatchCodexConversationTarget,
        String,
        @escaping (Bool, WatchCodexConversationTarget?, String?) -> Void
    ) -> Void)?

    init(
        serverIdentityPrivateKey: P256.Signing.PrivateKey? = nil,
        identityLoader: @escaping IdentityLoader = {
            WristRemoteServerIdentityStore.loadOrCreate()
        },
        localEndpointProvider: @escaping (UInt16) -> NWEndpoint? = {
            WristRemoteListenerBindingPolicy.currentEndpoint(port: $0)
        },
        advertisesBonjour: Bool = true
    ) {
        self.serverIdentityPrivateKey = serverIdentityPrivateKey
        self.identityLoader = identityLoader
        self.localEndpointProvider = localEndpointProvider
        self.advertisesBonjour = advertisesBonjour
    }

    func start(tailnetAccessEnabled: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.tailnetAccessEnabled = tailnetAccessEnabled
            self.startOnQueue()
        }
    }

    func setTailnetAccessEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, tailnetAccessEnabled != enabled else { return }
            tailnetAccessEnabled = enabled
            reconcileTailnetListener()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            shouldRun = false
            identityLoadGeneration += 1
            isIdentityLoadInProgress = false
            listener?.cancel()
            listener = nil
            lanLocalEndpoint = nil
            lanRetryWorkItem?.cancel()
            lanRetryWorkItem = nil
            directHTTPServer?.stop()
            directHTTPServer = nil
            directHTTPEndpoint = nil
            setDirectConfiguration(nil)
            tailnetRetryWorkItem?.cancel()
            tailnetRetryWorkItem = nil
            tailnetListener?.cancel()
            tailnetListener = nil
            tailnetLocalEndpoint = nil
            let currentClients = Array(clients.values)
            clients.removeAll()
            clientRoutes.removeAll()
            currentClients.forEach { $0.cancel() }
            voiceOwnership = WristRemoteVoiceOwnership()
            publish(.stopped)
            publishTailnet(.disabled)
            publishClientSnapshots()
        }
    }

    func updateApplicationTitles(_ titles: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            applicationTitles = titles
            clients.values.forEach { $0.updateApplicationTitles(titles) }
        }
    }

    func updateWatchProfile(_ profile: WatchActionProfileWire?) {
        queue.async { [weak self] in self?.setWatchProfileOnQueue(profile) }
    }

    private func setWatchProfileOnQueue(_ profile: WatchActionProfileWire?) {
        guard currentWatchProfile != profile else { return }
        if let owner = rawGestureOwnership.ownerID { releaseRawGestureOwner(owner) }
        currentWatchProfile = profile
        clients.values.forEach { $0.updateWatchProfile(profile) }
    }

    func updateCodexTask(
        _ snapshot: WatchCodexTaskSnapshot?,
        stateRevision: Int
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            codexTaskSnapshot = snapshot
            codexTaskStateRevision = stateRevision
            clients.values.forEach {
                $0.updateCodexTask(snapshot, stateRevision: stateRevision)
            }
        }
    }

    func updateCodexConversationCatalog(_ catalog: WatchCodexConversationCatalog?) {
        queue.async { [weak self] in
            guard let self else { return }
            codexConversationCatalog = catalog
            clients.values.forEach { $0.updateCodexConversationCatalog(catalog) }
        }
    }

    func updateSpeechLocaleIdentifier(_ identifier: String) {
        queue.async { [weak self] in
            guard let self else { return }
            speechLocaleIdentifier = identifier
            clients.values.forEach { $0.updateSpeechLocaleIdentifier(identifier) }
        }
    }

    func updateInternetRelayProvisioning(_ encoded: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            internetRelayProvisioning = encoded
            clients.values.forEach { $0.updateInternetRelayProvisioning(encoded) }
        }
    }

    func sendVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        queue.async { [weak self] in
            guard let self else { return }
            if let owner = voiceOwnership.ownerID {
                voiceOwnership.release(owner: owner, session: outcome.sessionID)
            }
            clients.values.forEach { $0.sendVoiceOutcome(outcome) }
        }
    }

    func invalidateProfiles(detail: String) {
        queue.async { [weak self] in
            guard let self else { return }
            clients.values.forEach { $0.invalidateProfile(detail: detail) }
            if let owner = rawGestureOwnership.ownerID { releaseRawGestureOwner(owner) }
            onProfileReset?()
        }
    }

    private func startOnQueue() {
        guard shouldRun else { return }
        guard serverIdentityPrivateKey != nil else {
            beginIdentityLoadOnQueue()
            return
        }
        startLANListenerOnQueue()
        reconcileTailnetListener()
    }

    private func beginIdentityLoadOnQueue() {
        guard !isIdentityLoadInProgress else { return }
        isIdentityLoadInProgress = true
        identityLoadGeneration += 1
        let generation = identityLoadGeneration
        let identityLoader = identityLoader
        publish(.loadingIdentity)

        identityQueue.async { [weak self] in
            let identity = identityLoader()
            self?.queue.async { [weak self] in
                self?.completeIdentityLoadOnQueue(identity, generation: generation)
            }
        }
    }

    private func completeIdentityLoadOnQueue(
        _ identity: P256.Signing.PrivateKey?,
        generation: Int
    ) {
        guard generation == identityLoadGeneration else { return }
        isIdentityLoadInProgress = false
        guard shouldRun else { return }
        guard let identity else {
            publish(.identityUnavailable(Self.identityUnavailableDetail))
            if tailnetAccessEnabled {
                publishTailnet(.failed("长期身份不可用，私有监听未启动。"))
            }
            return
        }
        serverIdentityPrivateKey = identity
        startLANListenerOnQueue()
        reconcileTailnetListener()
    }

    private func startLANListenerOnQueue() {
        guard shouldRun, serverIdentityPrivateKey != nil else { return }
        lanRetryWorkItem?.cancel()
        let currentEndpoint = localEndpointProvider(Self.port)
        if WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: lanLocalEndpoint, current: currentEndpoint) {
            listener?.cancel()
            listener = nil
            lanLocalEndpoint = currentEndpoint
            cancelClients(on: .lan)
        }
        reconcileDirectHTTPListener()
        let healthCheck = DispatchWorkItem { [weak self] in self?.startLANListenerOnQueue() }
        lanRetryWorkItem = healthCheck
        queue.asyncAfter(deadline: .now() + WristRemoteLocalListenerLifecyclePolicy.retryDelaySeconds(
            hasLANListener: listener != nil, hasHTTPListener: directHTTPServer != nil
        ), execute: healthCheck)
        guard listener == nil else { return }
        publish(.starting)
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            guard let localEndpoint = currentEndpoint else {
                publish(.failed("未找到可安全监听的本地局域网地址。"))
                return
            }
            parameters.requiredLocalEndpoint = localEndpoint
            let listener = try NWListener(using: parameters)
            if advertisesBonjour {
                listener.service = NWListener.Service(
                    name: Self.serviceName,
                    type: Self.serviceType
                )
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.publishConnectionStatus()
                case let .failed(error):
                    self.listener = nil
                    self.publish(.failed(error.localizedDescription))
                case .cancelled:
                    if self.listener != nil { self.publish(.stopped) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, route: .lan)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func reconcileDirectHTTPListener() {
        let endpoint = localEndpointProvider(UInt16(WristDirectBridgeConfiguration.port))
        if WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: directHTTPEndpoint, current: endpoint) {
            directHTTPServer?.stop()
            directHTTPServer = nil
            directHTTPEndpoint = endpoint
            setDirectConfiguration(nil)
        }
        guard directHTTPServer == nil, let endpoint else { return }
        let http = WristDirectBridgeHTTPServer(queue: queue)
        directHTTPServer = http
        http.onSession = { [weak self] transport in
            self?.attach(transport, route: .directHTTP) ?? false
        }
        http.onReady = { [weak self, weak http] in
            guard let self, directHTTPServer === http,
                  case let .hostPort(host, port) = endpoint,
                  port.rawValue == UInt16(WristDirectBridgeConfiguration.port),
                  let identity = serverIdentityPrivateKey
            else { return }
            let rawHost = String(describing: host)
            let urlHost = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
            let configuration = WristDirectBridgeConfiguration(
                endpoint: "http://\(urlHost):\(port.rawValue)\(WristDirectBridgeConfiguration.route)",
                serverIdentityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
                serverName: String(Self.macName.prefix(80))
            )
            setDirectConfiguration(configuration.validated())
        }
        http.onFailure = { [weak self, weak http] in
            guard let self, directHTTPServer === http else { return }
            directHTTPServer = nil
            setDirectConfiguration(nil)
        }
        do { try http.start(endpoint: endpoint) }
        catch {
            directHTTPServer = nil
            setDirectConfiguration(nil)
        }
    }

    private func setDirectConfiguration(_ configuration: WristDirectBridgeConfiguration?) {
        guard directBridgeConfiguration != configuration else { return }
        directBridgeConfiguration = configuration
        clients.values.forEach { $0.updateDirectBridgeConfiguration(configuration) }
        DispatchQueue.main.async { [weak self] in self?.onDirectBridgeConfiguration?(configuration) }
    }

    private func reconcileTailnetListener() {
        tailnetRetryWorkItem?.cancel()
        tailnetRetryWorkItem = nil
        guard tailnetAccessEnabled else {
            tailnetListener?.cancel()
            tailnetListener = nil
            tailnetLocalEndpoint = nil
            cancelClients(on: .tailnet)
            publishTailnet(.disabled)
            return
        }
        guard serverIdentityPrivateKey != nil else {
            tailnetListener?.cancel()
            tailnetListener = nil
            tailnetLocalEndpoint = nil
            cancelClients(on: .tailnet)
            publishTailnet(.failed("长期身份不可用，私有监听未启动。"))
            return
        }

        guard let endpoint = WristRemoteTailnetBindingPolicy.currentEndpoint(port: Self.port) else {
            tailnetListener?.cancel()
            tailnetListener = nil
            tailnetLocalEndpoint = nil
            cancelClients(on: .tailnet)
            publishTailnet(.waiting)
            scheduleTailnetRetry()
            return
        }
        if tailnetLocalEndpoint == endpoint, tailnetListener != nil { return }

        tailnetListener?.cancel()
        tailnetListener = nil
        cancelClients(on: .tailnet)
        tailnetLocalEndpoint = endpoint
        publishTailnet(.starting)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = endpoint
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, listener === self.tailnetListener else { return }
                switch state {
                case .ready:
                    self.publishTailnet(.ready)
                case let .failed(error):
                    self.tailnetRetryWorkItem?.cancel()
                    self.tailnetRetryWorkItem = nil
                    self.tailnetListener = nil
                    self.tailnetLocalEndpoint = nil
                    self.cancelClients(on: .tailnet)
                    self.publishTailnet(.failed(error.localizedDescription))
                    self.scheduleTailnetRetry()
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, route: .tailnet)
            }
            tailnetListener = listener
            listener.start(queue: queue)
            scheduleTailnetHealthCheck()
        } catch {
            tailnetListener = nil
            tailnetLocalEndpoint = nil
            publishTailnet(.failed(error.localizedDescription))
            scheduleTailnetRetry()
        }
    }

    private func scheduleTailnetRetry() {
        guard tailnetAccessEnabled, tailnetRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            tailnetRetryWorkItem = nil
            reconcileTailnetListener()
        }
        tailnetRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func scheduleTailnetHealthCheck() {
        guard tailnetAccessEnabled else { return }
        tailnetRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            tailnetRetryWorkItem = nil
            reconcileTailnetListener()
            if tailnetListener != nil { scheduleTailnetHealthCheck() }
        }
        tailnetRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func accept(_ connection: NWConnection, route: InboundRoute) {
        let isPermitted: Bool
        switch route {
        case .lan:
            isPermitted = WristRemotePeerAccessPolicy.permits(connection.endpoint)
        case .tailnet:
            isPermitted = tailnetAccessEnabled
                && WristRemoteTailnetBindingPolicy.permitsPeer(connection.endpoint)
        case .directHTTP:
            isPermitted = false // HTTP owns its separately validated request listener.
        }
        guard isPermitted else {
            connection.cancel()
            return
        }
        let transport = WristRemoteTCPSessionTransport(connection: connection, queue: queue)
        if !attach(transport, route: route) { transport.cancel() }
    }

    @discardableResult
    private func attach(_ transport: WristRemoteSessionTransport, route: InboundRoute) -> Bool {
        guard shouldRun, let serverIdentityPrivateKey,
              clients.values.lazy.filter({ !$0.hasApprovedSession }).count
                < Self.maximumUnauthenticatedClientCount
        else {
            return false
        }
        let client = WristRemoteServerClient(
            transport: transport,
            queue: queue,
            serverIdentityPrivateKey: serverIdentityPrivateKey,
            handshakeTimeoutSeconds: Self.handshakeTimeoutSeconds,
            macName: Self.macName,
            appVersion: Self.appVersion,
            applicationTitles: applicationTitles,
            codexTaskSnapshot: codexTaskSnapshot,
            codexTaskStateRevision: codexTaskStateRevision,
            codexConversationCatalog: codexConversationCatalog,
            speechLocaleIdentifier: speechLocaleIdentifier,
            internetRelayProvisioning: internetRelayProvisioning,
            directBridgeConfiguration: directBridgeConfiguration,
            currentWatchProfile: currentWatchProfile
        )
        let id = ObjectIdentifier(client)
        clients[id] = client
        clientRoutes[id] = route
        client.isIdentityTrusted = { [weak self] fingerprint in
            self?.isIdentityTrusted?(fingerprint) ?? false
        }
        client.onIdentityApproved = { [weak self] fingerprint in
            self?.onIdentityApproved?(fingerprint) ?? false
        }
        client.canApproveIdentity = { [weak self] fingerprint in
            guard let self else { return false }
            return WristRemoteClientAdmissionPolicy.canApprove(
                identity: fingerprint, approvedIdentities: clients.values.compactMap(\.approvedIdentityFingerprint)
            )
        }
        client.onApprovalRequested = { [weak self, weak client] name, code, fingerprint in
            guard let self, let client else { return }
            guard WristRemoteClientAdmissionPolicy.mayPresentApproval(hasPendingApproval: pendingApprovalID != nil),
                  let approval = onApprovalRequested else {
                client.resolveApproval(false)
                return
            }
            pendingApprovalID = id
            approval(name, code, fingerprint) { [weak self, weak client] allowed in
                self?.queue.async {
                    guard let self, self.pendingApprovalID == id else { return }
                    self.pendingApprovalID = nil
                    client?.resolveApproval(allowed)
                }
            }
        }
        client.onApproved = { [weak self, weak client] _ in
            guard let self, let client else { return }
            if pendingApprovalID == id { pendingApprovalID = nil }
            let others = clients.values.filter {
                $0 !== client && WristRemoteClientAdmissionPolicy.replaces(
                    existingIdentity: $0.approvedIdentityFingerprint,
                    newlyApprovedIdentity: client.approvedIdentityFingerprint
                )
            }
            others.forEach { $0.cancel() }
            publishConnectionStatus()
            publishClientSnapshots()
        }
        client.onWatchProfileUpdate = { [weak self] profile, completion in
            guard let handler = self?.onWatchProfileUpdate else {
                completion(.rejected)
                return
            }
            handler(profile) { [weak self] result in
                self?.queue.async {
                    if result.isAccepted { self?.setWatchProfileOnQueue(profile) }
                    completion(result)
                }
            }
        }
        client.onWatchButtonEvent = { [weak self] button, phase, completion in
            guard let self, let handler = onWatchButtonEvent,
                  rawGestureOwnership.accept(owner: id, button: button, phase: phase)
            else {
                completion(false)
                return
            }
            rawGestureReapWorkItem?.cancel()
            rawGestureReapWorkItem = nil
            if rawGestureOwnership.pressedButtons.isEmpty {
                let item = DispatchWorkItem { [weak self] in self?.releaseRawGestureOwner(id) }
                rawGestureReapWorkItem = item
                // Covers the 320 ms double-click window plus scheduling slack.
                queue.asyncAfter(deadline: .now() + 0.75, execute: item)
            }
            handler(button, phase, completion)
        }
        client.onWatchButtonTrigger = { [weak self] button, trigger, revision, issuedAt, completion in
            guard let handler = self?.onWatchButtonTrigger else { completion(false); return }
            handler(button, trigger, revision, issuedAt, completion)
        }
        client.onVoiceStart = {
            [weak self] sessionID, intent, identity, conversationTarget, completion in
            guard let self, let handler = onVoiceStart, let sessionID,
                  let ticket = voiceOwnership.reserve(owner: id, session: sessionID)
            else {
                completion(false)
                return
            }
            handler(sessionID, intent, identity, conversationTarget) { [weak self] started in
                self?.queue.async {
                    guard let self, self.voiceOwnership.matches(owner: id, session: sessionID, ticket: ticket) else {
                        completion(false)
                        return
                    }
                    if !started { self.voiceOwnership.release(owner: id, session: sessionID, ticket: ticket) }
                    completion(started)
                }
            }
        }
        client.onVoiceStop = { [weak self] sessionID in
            guard let self, voiceOwnership.matches(owner: id, session: sessionID) else { return }
            // Keep ownership during finalization until the exact outcome arrives.
            onVoiceStop?(sessionID)
        }
        client.onVoiceCancel = { [weak self] sessionID in
            guard let self, voiceOwnership.matches(owner: id, session: sessionID) else { return }
            voiceOwnership.release(owner: id, session: sessionID)
            onVoiceCancel?(sessionID)
        }
        client.onAudio = { [weak self] sessionID, samples in
            guard let self, voiceOwnership.matches(owner: id, session: sessionID) else { return false }
            return onAudio?(sessionID, samples) ?? false
        }
        client.onCodexReplySubmit = {
            [weak self] submissionID, identity, transcript, completion in
            guard let handler = self?.onCodexReplySubmit else {
                completion(false, "Codex 回复服务未就绪。")
                return
            }
            handler(submissionID, identity, transcript, completion)
        }
        client.onCodexConversationCatalogRequest = { [weak self] requestID, completion in
            guard let handler = self?.onCodexConversationCatalogRequest else {
                completion(nil, "Codex 会话目录服务未就绪。")
                return
            }
            handler(requestID, completion)
        }
        client.onCodexConversationTargetSelect = {
            [weak self] requestID, target, completion in
            guard let handler = self?.onCodexConversationTargetSelect else {
                completion(false, nil, "Codex 会话选择服务未就绪。")
                return
            }
            handler(requestID, target, completion)
        }
        client.onCodexConversationDraftSubmit = {
            [weak self] submissionID, draftID, target, transcript, completion in
            guard let handler = self?.onCodexConversationDraftSubmit else {
                completion(false, nil, "Codex 会话发送服务未就绪。")
                return
            }
            handler(submissionID, draftID, target, transcript, completion)
        }
        client.onClosed = { [weak self] wasApproved, _ in
            guard let self else { return }
            clients.removeValue(forKey: id)
            clientRoutes.removeValue(forKey: id)
            releaseRawGestureOwner(id)
            if WristRemoteClientAdmissionPolicy.resetsProfile(
                wasApproved: wasApproved, remainingApprovedCount: clients.values.filter(\.hasApprovedSession).count
            ) { onProfileReset?() }
            if wasApproved {
                publishConnectionStatus()
                publishClientSnapshots()
            }
            if pendingApprovalID == id {
                pendingApprovalID = nil
                onApprovalCancelled?()
            }
        }
        client.start()
        return true
    }

    private func cancelClients(on route: InboundRoute) {
        let matchingClients = clientRoutes.compactMap { id, clientRoute in
            clientRoute == route ? clients[id] : nil
        }
        matchingClients.forEach { $0.cancel() }
    }

    private func releaseRawGestureOwner(_ id: ObjectIdentifier) {
        guard rawGestureOwnership.ownerID == id else { return }
        rawGestureReapWorkItem?.cancel()
        rawGestureReapWorkItem = nil
        rawGestureOwnership.release(owner: id).forEach { onWatchButtonCancel?($0) }
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    private func publishConnectionStatus() {
        let names = clients.values.filter(\.hasApprovedSession).map(\.deviceName).sorted()
        if !names.isEmpty { publish(.connected(names.joined(separator: "、"))) }
        else if shouldRun { publish(.ready) }
    }

    private func publishClientSnapshots() {
        let snapshots = clients.values.filter(\.hasApprovedSession).map { client in
            WristRemoteClientSnapshot(
                id: client.sessionIdentifier,
                name: client.deviceName,
                role: WristRemoteHandshake.clientRole,
                transport: client.transportName
            )
        }.sorted { $0.id < $1.id }
        DispatchQueue.main.async { [weak self] in self?.onClientSnapshots?(snapshots) }
    }

    private func publishTailnet(_ status: TailnetStatus) {
        DispatchQueue.main.async { [weak self] in self?.onTailnetStatus?(status) }
    }

    private static var serviceName: String {
        "\(macName) · Wrist Remote"
    }

    private static var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

final class WristRemoteServerClient {
    private struct VoiceTarget {
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let codexConversationTarget: WatchCodexConversationTarget?
    }

    private let transport: WristRemoteSessionTransport
    let sessionIdentifier = UUID().uuidString
    private let queue: DispatchQueue
    private let serverIdentityPrivateKey: P256.Signing.PrivateKey // gitleaks:allow
    private let handshakeTimeoutSeconds: TimeInterval
    private let macName: String
    private let appVersion: String?
    private var applicationTitles: [String: String]
    private var codexTaskSnapshot: WatchCodexTaskSnapshot?
    private var codexTaskStateRevision: Int
    private var codexConversationCatalog: WatchCodexConversationCatalog?
    private var speechLocaleIdentifier: String
    private var internetRelayProvisioning: String?
    private var directBridgeConfiguration: WristDirectBridgeConfiguration?
    private var currentWatchProfile: WatchActionProfileWire?
    private var handledButtonRequestIDs: [String: Int64] = [:]
    private var receiveBuffer = Data()
    private var sessionKey: SymmetricKey?
    private var secureChannel = WristBridgeSecureChannel()
    private var identityFingerprint: String?
    private var pendingName: String?
    private var connectedDeviceName = "Wrist Remote"
    private var pendingPairingCode: String?
    private var didReceiveHello = false
    private var didReceiveClientAuthentication = false
    private var clientEphemeralPublicKey: Data?
    private var serverEphemeralPublicKey: Data?
    private var serverIdentityPublicKey: Data?
    private var clientHadPinnedServerIdentity = false
    private var requestedApproval = false
    private var approved = false
    private var closed = false
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var watchProfileSession = WatchProfileSession()
    private var voiceSession = BridgeVoiceSession()
    private var audioReceiveGate = WristBridgeAudioReceiveGate()
    private var activeVoiceIntent: WatchVoiceIntent = .foregroundDictation
    private var activeVoiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var activeVoiceCodexConversationTarget: WatchCodexConversationTarget?
    private var activeVoiceSessionID: String?
    private var awaitingVoiceOutcomes: [String: VoiceTarget] = [:]

    var isIdentityTrusted: ((String) -> Bool)?
    var onIdentityApproved: ((String) -> Bool)?
    var canApproveIdentity: ((String) -> Bool)?
    var onApprovalRequested: ((String, String, String?) -> Void)?
    var onApproved: ((String) -> Void)?
    var onWatchProfileUpdate: ((
        WatchActionProfileWire,
        @escaping (WatchProfileRuntimeInstallResult) -> Void
    ) -> Void)?
    var onWatchButtonEvent: ((WristRemoteButton, WristRemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onWatchButtonTrigger: ((WristRemoteButton, WristRemoteTrigger, Int, Int64, @escaping (Bool) -> Void) -> Void)?
    var onVoiceStart: ((
        String?,
        WatchVoiceIntent,
        WatchCodexTaskIdentity?,
        WatchCodexConversationTarget?,
        @escaping (Bool) -> Void
    ) -> Void)?
    var onVoiceStop: ((String?) -> Void)?
    var onVoiceCancel: ((String?) -> Void)?
    var onAudio: ((String?, [Int16]) -> Bool)?
    var onCodexReplySubmit: ((
        UUID,
        WatchCodexTaskIdentity,
        String,
        @escaping (Bool, String?) -> Void
    ) -> Void)?
    var onCodexConversationCatalogRequest: ((
        UUID,
        @escaping (WatchCodexConversationCatalog?, String?) -> Void
    ) -> Void)?
    var onCodexConversationTargetSelect: ((
        UUID,
        WatchCodexConversationTarget,
        @escaping (Bool, WatchCodexConversationTarget?, String?) -> Void
    ) -> Void)?
    var onCodexConversationDraftSubmit: ((
        UUID,
        UUID,
        WatchCodexConversationTarget,
        String,
        @escaping (Bool, WatchCodexConversationTarget?, String?) -> Void
    ) -> Void)?
    var onClosed: ((Bool, Bool) -> Void)?

    var hasApprovedSession: Bool { approved }
    var approvedIdentityFingerprint: String? { approved ? identityFingerprint : nil }
    var deviceName: String { connectedDeviceName }
    var transportName: String { transport.name }
    private var isDirectHTTP: Bool { transport is WristDirectHTTPSessionTransport }

    init(
        transport: WristRemoteSessionTransport,
        queue: DispatchQueue,
        serverIdentityPrivateKey: P256.Signing.PrivateKey,
        handshakeTimeoutSeconds: TimeInterval,
        macName: String,
        appVersion: String?,
        applicationTitles: [String: String],
        codexTaskSnapshot: WatchCodexTaskSnapshot?,
        codexTaskStateRevision: Int,
        codexConversationCatalog: WatchCodexConversationCatalog?,
        speechLocaleIdentifier: String,
        internetRelayProvisioning: String?,
        directBridgeConfiguration: WristDirectBridgeConfiguration?,
        currentWatchProfile: WatchActionProfileWire?
    ) {
        self.transport = transport
        self.queue = queue
        self.serverIdentityPrivateKey = serverIdentityPrivateKey
        self.handshakeTimeoutSeconds = handshakeTimeoutSeconds
        self.macName = macName
        self.appVersion = appVersion
        self.applicationTitles = applicationTitles
        self.codexTaskSnapshot = codexTaskSnapshot
        self.codexTaskStateRevision = codexTaskStateRevision
        self.codexConversationCatalog = codexConversationCatalog
        self.speechLocaleIdentifier = speechLocaleIdentifier
        self.internetRelayProvisioning = internetRelayProvisioning
        self.directBridgeConfiguration = directBridgeConfiguration
        self.currentWatchProfile = currentWatchProfile
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !approved else { return }
            cancel()
        }
        handshakeTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + handshakeTimeoutSeconds, execute: timeout)
        transport.onData = { [weak self] data in self?.consume(data) }
        transport.onClosed = { [weak self] in self?.close() }
        transport.start()
    }

    func cancel() {
        close()
    }

    func resolveApproval(_ allowed: Bool) {
        guard !closed, requestedApproval, !approved else { return }
        guard allowed,
              let identityFingerprint,
              canApproveIdentity?(identityFingerprint) == true
        else {
            sendSecure(BridgeWireMessage(type: "denied")) { [weak self] in
                // HTTP must flush the denial before closing its session.
                self?.queue.asyncAfter(deadline: .now() + 0.1) { self?.cancel() }
            }
            return
        }
        let persistenceSucceeded = onIdentityApproved?(identityFingerprint) ?? false
        guard WristRemoteHandshake.acceptsPersistedClientApproval(
            identityFingerprint: identityFingerprint,
            persistenceSucceeded: persistenceSucceeded
        )
        else {
            sendSecure(BridgeWireMessage(
                type: "denied",
                detail: "Mac 无法安全保存设备身份，配对已拒绝"
            )) { [weak self] in
                self?.queue.asyncAfter(deadline: .now() + 0.1) { self?.cancel() }
            }
            return
        }
        approved = true
        sendReady()
    }

    func updateDirectBridgeConfiguration(_ configuration: WristDirectBridgeConfiguration?) {
        directBridgeConfiguration = configuration
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "directBridgeConfiguration",
            directBridgeConfiguration: configuration.flatMap { try? $0.encodeBase64() },
            directBridgeConfigurationCleared: configuration == nil
        ))
    }

    func updateWatchProfile(_ profile: WatchActionProfileWire?) {
        currentWatchProfile = profile
        if let accepted = watchProfileSession.acceptedProfile,
           accepted != profile,
           watchProfileSession.pendingProfile != profile {
            invalidateProfile(detail: "其他设备已更新映射，请重新同步当前版本。")
        }
        guard approved, isDirectHTTP else { return }
        sendSecure(BridgeWireMessage(
            type: "watchProfileSnapshot",
            profileRevision: profile?.revision,
            watchProfile: profile.flatMap { try? $0.encodedBase64() }
        ))
    }

    func updateApplicationTitles(_ titles: [String: String]) {
        applicationTitles = titles
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "watchApplicationTitles",
            watchApplicationTitles: titles
        ))
    }

    func updateCodexConversationCatalog(_ catalog: WatchCodexConversationCatalog?) {
        let activeTarget = activeVoiceCodexConversationTarget
        let stillAvailable = activeTarget.map { target in
            catalog?.permitsContinuingVoice(
                for: target,
                nowEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            ) == true
        } ?? true
        if activeVoiceIntent == .codexConversation,
           !stillAvailable,
           let activeVoiceSessionID,
           voiceSession.stop(sessionID: activeVoiceSessionID, force: true) {
            onVoiceCancel?(activeVoiceSessionID)
            sendVoiceOutcome(WatchVoiceOutcome(
                sessionID: activeVoiceSessionID,
                intent: .codexConversation,
                threadID: nil,
                kind: .failed,
                text: nil,
                detail: "会话目录已更新，旧录音已取消。",
                localeIdentifier: speechLocaleIdentifier
            ))
            clearActiveVoiceTarget()
        }
        codexConversationCatalog = catalog
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "codexConversationCatalogSnapshot",
            codexConversationCatalog: catalog
        ))
    }

    func updateCodexTask(
        _ snapshot: WatchCodexTaskSnapshot?,
        stateRevision: Int
    ) {
        let nextIdentity = WatchCodexTaskIdentity(snapshot)
        if activeVoiceIntent == .codexTask,
           let activeVoiceSessionID,
           let activeVoiceCodexTaskIdentity,
           activeVoiceCodexTaskIdentity != nextIdentity {
            if voiceSession.stop(sessionID: activeVoiceSessionID, force: true) {
                onVoiceCancel?(activeVoiceSessionID)
            }
            sendVoiceOutcome(WatchVoiceOutcome(
                sessionID: activeVoiceSessionID,
                intent: .codexTask,
                threadID: activeVoiceCodexTaskIdentity.threadID,
                turnID: activeVoiceCodexTaskIdentity.turnID,
                taskRevision: activeVoiceCodexTaskIdentity.revision,
                kind: .failed,
                text: nil,
                detail: "Codex 任务已更新，旧录音已拒绝。",
                localeIdentifier: speechLocaleIdentifier
            ))
            clearActiveVoiceTarget()
        }
        codexTaskSnapshot = snapshot
        codexTaskStateRevision = stateRevision
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "codexTaskSnapshot",
            codexTask: snapshot,
            codexTaskCleared: snapshot == nil,
            codexTaskStateRevision: stateRevision
        ))
    }

    func updateSpeechLocaleIdentifier(_ identifier: String) {
        speechLocaleIdentifier = identifier
    }

    func updateInternetRelayProvisioning(_ encoded: String?) {
        internetRelayProvisioning = encoded
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "internetRelayProvisioning",
            internetRelayProvisioning: encoded,
            internetRelayProvisioningCleared: encoded == nil
        ))
    }

    func sendVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        guard approved,
              UUID(uuidString: outcome.sessionID) != nil,
              let expected = awaitingVoiceOutcomes[outcome.sessionID],
              expected.intent == outcome.intent
        else { return }

        let normalized: WatchVoiceOutcome
        switch expected.intent {
        case .foregroundDictation:
            guard outcome.threadID == nil,
                  outcome.turnID == nil,
                  outcome.taskRevision == nil
            else { return }
            normalized = outcome
        case .codexTask:
            guard let identity = expected.codexTaskIdentity,
                  (outcome.threadID == nil || outcome.threadID == identity.threadID),
                  (outcome.turnID == nil || outcome.turnID == identity.turnID),
                  (outcome.taskRevision == nil
                    || outcome.taskRevision == identity.revision)
            else { return }
            if WatchCodexTaskIdentity(codexTaskSnapshot) == identity {
                normalized = outcome.bound(to: identity)
            } else {
                normalized = WatchVoiceOutcome(
                    sessionID: outcome.sessionID,
                    intent: .codexTask,
                    threadID: identity.threadID,
                    turnID: identity.turnID,
                    taskRevision: identity.revision,
                    kind: .failed,
                    text: nil,
                    detail: "Codex 任务已更新，旧录音结果已拒绝。",
                    localeIdentifier: outcome.localeIdentifier
                )
            }
        case .codexConversation:
            guard let target = expected.codexConversationTarget,
                  outcome.threadID == nil,
                  outcome.turnID == nil,
                  outcome.taskRevision == nil,
                  outcome.hasValidWireShape
            else { return }
            switch outcome.kind {
            case .draft:
                guard outcome.codexConversationTarget == target else { return }
            case .delivered, .failed:
                // Non-draft conversation outcomes intentionally contain no
                // target fields; the session's expected target already binds
                // the result and avoids leaking a stale capability.
                guard outcome.codexConversationTarget == nil else { return }
            }
            normalized = outcome
        }
        awaitingVoiceOutcomes.removeValue(forKey: outcome.sessionID)
        sendSecure(BridgeWireMessage(
            type: "voiceOutcome",
            detail: normalized.detail,
            sessionID: normalized.sessionID,
            voiceIntent: normalized.intent.rawValue,
            threadID: normalized.threadID,
            turnID: normalized.turnID,
            taskRevision: normalized.taskRevision,
            transcript: normalized.text,
            draftID: normalized.draftID?.uuidString,
            draftExpiresAtEpochMilliseconds: normalized.draftExpiresAtEpochMilliseconds,
            codexConversationTarget: normalized.codexConversationTarget,
            voiceOutcome: normalized.kind.rawValue,
            speechLocaleIdentifier: normalized.localeIdentifier
        ))
    }

    func invalidateProfile(detail: String) {
        let revision = watchProfileSession.acceptedProfile?.revision
        if voiceSession.stop(sessionID: nil, force: true) { onVoiceCancel?(activeVoiceSessionID) }
        clearActiveVoiceTarget()
        awaitingVoiceOutcomes.removeAll()
        watchProfileSession.reset()
        guard approved, let revision else { return }
        sendWatchProfileRejected(revision: revision, detail: detail)
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        guard receiveBuffer.count <= 2 * 1_024 * 1_024 else {
            cancel()
            return
        }
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(
                BridgeWireMessage.self,
                from: frame
            ) else {
                cancel()
                return
            }
            handleEnvelope(message)
        }
    }

    private func handleEnvelope(_ envelope: BridgeWireMessage) {
        if envelope.type == "hello" {
            guard !didReceiveHello else {
                cancel()
                return
            }
            establishSession(with: envelope)
            return
        }
        guard didReceiveHello,
              envelope.type == "secure",
              let message = decrypt(envelope)
        else {
            cancel()
            return
        }
        (transport as? WristDirectHTTPSessionTransport)?.didAuthenticateInput(message)
        if message.type == "clientAuth" {
            guard !didReceiveClientAuthentication, !approved else {
                cancel()
                return
            }
            authenticateClient(message)
            return
        }
        guard approved else {
            cancel()
            return
        }
        handleSecure(message)
    }

    private func establishSession(with message: BridgeWireMessage) {
        guard WristRemoteHandshake.acceptsClient(message),
              let encoded = message.publicKey,
              let publicData = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: publicData
              )
        else {
            cancel()
            return
        }
        didReceiveHello = true
        (transport as? WristDirectHTTPSessionTransport)?.didAuthenticateInput(message)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverEphemeralData = privateKey.publicKey.rawRepresentation
        let serverIdentityData = serverIdentityPrivateKey.publicKey.rawRepresentation
        guard let proof = BridgeWireMessage.serverIdentityProof(
            clientEphemeralPublicKey: publicData,
            serverEphemeralPublicKey: serverEphemeralData
        ), let transcript = BridgeWireMessage.sessionTranscript(
            clientEphemeralPublicKey: publicData,
            serverEphemeralPublicKey: serverEphemeralData,
            serverIdentityPublicKey: serverIdentityData
        ), let serverIdentitySignature = try? serverIdentityPrivateKey.signature(for: proof),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        else {
            cancel()
            return
        }
        secureChannel.reset()
        sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(WristRemoteServer.sessionSalt.utf8),
            sharedInfo: Data(SHA256.hash(data: transcript)),
            outputByteCount: 32
        )
        clientEphemeralPublicKey = publicData
        serverEphemeralPublicKey = serverEphemeralData
        serverIdentityPublicKey = serverIdentityData
        sendPlain(BridgeWireMessage(
            type: "serverKey",
            protocolID: WristRemoteHandshake.protocolID,
            serverRole: WristRemoteHandshake.serverRole,
            publicKey: serverEphemeralData.base64EncodedString(),
            serverIdentityVersion: BridgeWireMessage.serverIdentityVersion,
            serverIdentityPublicKey: serverIdentityData.base64EncodedString(),
            serverIdentitySignature: serverIdentitySignature.rawRepresentation.base64EncodedString()
        ))
    }

    private func authenticateClient(_ message: BridgeWireMessage) {
        guard message.protocolID == nil,
              message.clientRole == nil,
              message.serverRole == nil,
              message.publicKey == nil,
              message.serverIdentityVersion == nil,
              message.serverIdentityPublicKey == nil,
              message.serverIdentitySignature == nil,
              let serverIdentityPinned = message.serverIdentityPinned,
              let clientEphemeralPublicKey,
              let serverEphemeralPublicKey,
              let serverIdentityPublicKey,
              let encodedIdentityKey = message.identityPublicKey,
              let identityData = Data(base64Encoded: encodedIdentityKey),
              let identityKey = try? P256.Signing.PublicKey(rawRepresentation: identityData),
              let encodedSignature = message.identitySignature,
              let signatureData = Data(base64Encoded: encodedSignature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              let proof = BridgeWireMessage.clientAuthenticationProof(
                  clientEphemeralPublicKey: clientEphemeralPublicKey,
                  serverEphemeralPublicKey: serverEphemeralPublicKey,
                  serverIdentityPublicKey: serverIdentityPublicKey,
                  clientIdentityPublicKey: identityData
              ), identityKey.isValidSignature(signature, for: proof),
              sessionKey != nil
        else {
            cancel()
            return
        }
        didReceiveClientAuthentication = true
        clientHadPinnedServerIdentity = serverIdentityPinned
        identityFingerprint = SHA256.hash(data: identityData)
            .map { String(format: "%02x", $0) }
            .joined()
        requestedApproval = true
        let trimmedName = message.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingName = trimmedName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "iPhone"
        connectedDeviceName = pendingName ?? "Wrist Remote"
        pendingPairingCode = sessionKey.map(Self.pairingCode)
        finishSessionSetup()
    }

    private func finishSessionSetup() {
        guard requestedApproval,
              !approved,
              let name = pendingName,
              let pairingCode = pendingPairingCode
        else { return }
        pendingName = nil
        pendingPairingCode = nil
        guard let identityFingerprint, canApproveIdentity?(identityFingerprint) == true else {
            resolveApproval(false)
            return
        }
        if clientHadPinnedServerIdentity,
           isIdentityTrusted?(identityFingerprint) == true {
            approved = true
            sendReady()
            return
        }
        onApprovalRequested?(name, pairingCode, identityFingerprint)
    }

    private func sendReady() {
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        let capabilities = [
            BridgeWireMessage.watchActionProfileCapability,
            BridgeWireMessage.connectionLivenessCapability,
            BridgeWireMessage.serverIdentityCapability,
            BridgeWireMessage.secureSequenceCapability,
            WristDirectBridgeProtocol.capability,
            WristDirectBridgeProtocol.buttonTriggerCapability,
        ] + (isDirectHTTP ? [] : [
            BridgeWireMessage.voiceSessionsCapability,
            BridgeWireMessage.codexTasksCapability,
            BridgeWireMessage.voiceOutcomesCapability,
            BridgeWireMessage.codexReplyReceiptsCapability,
            BridgeWireMessage.codexConversationsCapability,
            BridgeWireMessage.audioDeliveryReceiptsCapability,
        ])
        sendSecure(BridgeWireMessage(
            type: "ready",
            protocolID: WristRemoteHandshake.protocolID,
            serverRole: WristRemoteHandshake.serverRole,
            deviceName: macName,
            buttonTitles: [:],
            appVersion: appVersion,
            capabilities: capabilities,
            profileRevision: currentWatchProfile?.revision,
            watchProfile: currentWatchProfile.flatMap { try? $0.encodedBase64() },
            watchApplicationTitles: applicationTitles,
            codexTask: codexTaskSnapshot,
            codexTaskCleared: codexTaskSnapshot == nil,
            codexTaskStateRevision: codexTaskStateRevision,
            codexConversationCatalog: codexConversationCatalog,
            speechLocaleIdentifier: speechLocaleIdentifier,
            internetRelayProvisioning: internetRelayProvisioning,
            internetRelayProvisioningCleared: internetRelayProvisioning == nil,
            directBridgeConfiguration: directBridgeConfiguration.flatMap { try? $0.encodeBase64() },
            directBridgeConfigurationCleared: directBridgeConfiguration == nil
        )) { [weak self] in
            guard let self else { return }
            onApproved?(connectedDeviceName)
        }
    }

    private func handleSecure(_ message: BridgeWireMessage) {
        if isDirectHTTP && !["livenessProbe", "watchProfileUpdate", "buttonTrigger"].contains(message.type) {
            sendOperationError("Watch 私网直连目前仅支持状态和按钮遥控；语音请使用手机中继。")
            return
        }
        switch message.type {
        case "hello", "serverKey", "clientAuth", "ready":
            cancel()

        case "livenessProbe":
            guard BridgeWireMessage.isValidProbeID(message.probeID),
                  let probeID = message.probeID
            else { return }
            sendSecure(BridgeWireMessage(type: "livenessAck", probeID: probeID))

        case "watchProfileUpdate":
            handleWatchProfileUpdate(message)

        case "buttonTrigger":
            handleButtonTrigger(message)

        case "buttonEvent":
            guard let command = message.command,
                  let button = WristRemoteButton(rawValue: command),
                  let rawPhase = message.buttonPhase,
                  let phase = WristRemoteButtonPhase(rawValue: rawPhase),
                  watchProfileSession.accepts(
                      inputSource: message.inputSource,
                      revision: message.profileRevision
                  ),
                  currentWatchProfile == watchProfileSession.acceptedProfile,
                  let onWatchButtonEvent
            else {
                sendWatchProfileRejected(
                    revision: message.profileRevision,
                    detail: "映射尚未确认，来源错误，或版本已经变化。"
                )
                return
            }
            onWatchButtonEvent(button, phase) { [weak self] succeeded in
                self?.queue.async {
                    if !succeeded { self?.sendOperationError("该动作当前不可用。") }
                }
            }

        case "voiceStart":
            let parsedIntent = message.voiceIntent.flatMap(WatchVoiceIntent.init(rawValue:))
            let parsedTarget = parsedIntent.flatMap {
                voiceTarget(from: message, intent: $0)
            }
            guard let intent = parsedIntent,
                  let target = parsedTarget,
                  acceptsVoiceTarget(target),
                  watchProfileSession.accepts(
                inputSource: message.inputSource,
                revision: message.profileRevision
            ), voiceSession.begin(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ) else {
                sendVoiceRejected(
                    sessionID: message.sessionID,
                    profileRevision: message.profileRevision,
                    target: parsedTarget
                )
                return
            }
            activeVoiceIntent = intent
            activeVoiceCodexTaskIdentity = target.codexTaskIdentity
            activeVoiceCodexConversationTarget = target.codexConversationTarget
            activeVoiceSessionID = message.sessionID
            guard let startToken = voiceSession.startToken else { return }
            guard let onVoiceStart else {
                _ = voiceSession.completeStart(token: startToken, succeeded: false)
                clearActiveVoiceTarget()
                sendVoiceRejected(
                    sessionID: message.sessionID,
                    profileRevision: message.profileRevision,
                    target: target
                )
                return
            }
            onVoiceStart(
                message.sessionID,
                intent,
                target.codexTaskIdentity,
                target.codexConversationTarget
            ) { [weak self] succeeded in
                self?.queue.async {
                    guard let self,
                          let identity = self.voiceSession.completeStart(token: startToken, succeeded: succeeded)
                    else { return }
                    self.sendSecure(BridgeWireMessage(
                        type: succeeded ? "voiceReady" : "voiceRejected",
                        sessionID: identity.sessionID.uuidString,
                        inputSource: BridgeWireMessage.appleWatchInputSource,
                        profileRevision: identity.profileRevision,
                        voiceIntent: target.intent.rawValue,
                        threadID: target.codexTaskIdentity?.threadID,
                        turnID: target.codexTaskIdentity?.turnID,
                        taskRevision: target.codexTaskIdentity?.revision,
                        codexConversationTarget: target.codexConversationTarget
                    ))
                    if succeeded {
                        self.audioReceiveGate.reset()
                        self.awaitingVoiceOutcomes[identity.sessionID.uuidString] = target
                    } else {
                        self.clearActiveVoiceTarget()
                    }
                }
            }

        case "voiceStop":
            if messageMatchesActiveVoiceTarget(message), voiceSession.stop(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ) {
                onVoiceStop?(activeVoiceSessionID)
                clearActiveVoiceTarget()
            }

        case "voiceCancel":
            if messageMatchesActiveVoiceTarget(message), voiceSession.stop(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ) {
                onVoiceCancel?(activeVoiceSessionID)
                clearActiveVoiceTarget()
            }

        case "audio":
            guard let audioSequence = message.audioSequence else { return }
            let samples: [Int16]?
            if watchProfileSession.accepts(
                inputSource: message.inputSource,
                revision: message.profileRevision
            ), voiceSession.acceptsAudio(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ), messageMatchesActiveVoiceTarget(message),
               message.audioAccepted == nil,
               message.audioContiguousThrough == nil,
               let encoded = message.samples,
               let data = Data(base64Encoded: encoded),
               !data.isEmpty,
               data.count.isMultiple(of: MemoryLayout<Int16>.size) {
                samples = Self.samples(from: data)
            } else {
                samples = nil
            }
            let receipt: WristBridgeAudioDeliveryReceipt
            if let samples {
                receipt = audioReceiveGate.receive(sequence: audioSequence) {
                    onAudio?(message.sessionID, samples) ?? false
                }
            } else {
                receipt = WristBridgeAudioDeliveryReceipt(
                    sequence: audioSequence,
                    accepted: false,
                    contiguousThrough: audioReceiveGate.contiguousThrough
                )
            }
            sendAudioReceipt(receipt, for: message)

        case "codexReplySubmit":
            let text = message.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let rawSubmissionID = message.submissionID,
                  let submissionID = UUID(uuidString: rawSubmissionID),
                  submissionID.uuidString == rawSubmissionID,
                  let identity = wireCodexTaskIdentity(from: message)
            else {
                sendOperationError("Codex 回复缺少有效提交身份，语音未发送。")
                return
            }
            guard
                  WatchCodexTaskIdentity(codexTaskSnapshot) == identity,
                  codexTaskSnapshot?.state == .completed,
                  !text.isEmpty,
                  text.count <= 2_000,
                  let onCodexReplySubmit
            else {
                let detail = "Codex 任务已变化，语音未发送。"
                sendCodexReplyResult(
                    submissionID: submissionID,
                    identity: identity,
                    accepted: false,
                    detail: detail
                )
                sendOperationError(detail)
                return
            }
            onCodexReplySubmit(submissionID, identity, text) { [weak self] accepted, detail in
                self?.queue.async {
                    guard let self else { return }
                    self.sendCodexReplyResult(
                        submissionID: submissionID,
                        identity: identity,
                        accepted: accepted,
                        detail: detail
                    )
                    if !accepted {
                        self.sendOperationError(detail ?? "Codex 暂时无法接收回复。")
                    }
                }
            }

        case "codexConversationCatalogRequest":
            guard let requestID = Self.canonicalUUID(message.requestID),
                  let onCodexConversationCatalogRequest
            else { return }
            onCodexConversationCatalogRequest(requestID) {
                [weak self] catalog, detail in
                self?.queue.async {
                    guard let self else { return }
                    if let catalog { self.codexConversationCatalog = catalog }
                    self.sendSecure(BridgeWireMessage(
                        type: "codexConversationCatalogSnapshot",
                        detail: detail,
                        requestID: requestID.uuidString,
                        codexConversationCatalog: catalog
                    ))
                }
            }

        case "codexConversationTargetSelect":
            guard let requestID = Self.canonicalUUID(message.requestID),
                  let target = message.codexConversationTarget,
                  let onCodexConversationTargetSelect
            else { return }
            onCodexConversationTargetSelect(requestID, target) {
                [weak self] accepted, selectedTarget, detail in
                self?.queue.async {
                    self?.sendSecure(BridgeWireMessage(
                        type: "codexConversationTargetResult",
                        detail: detail,
                        requestID: requestID.uuidString,
                        codexConversationTarget: selectedTarget,
                        accepted: accepted
                    ))
                }
            }

        case "codexConversationDraftSubmit":
            let text = message.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            guard let submissionID = Self.canonicalUUID(message.submissionID),
                  let draftID = Self.canonicalUUID(message.draftID),
                  let target = message.codexConversationTarget,
                  target.kind == .existing,
                  WatchCodexConversationWireValidation.isValidTranscript(text),
                  let onCodexConversationDraftSubmit
            else { return }
            onCodexConversationDraftSubmit(submissionID, draftID, target, text) {
                [weak self] accepted, resolvedTarget, detail in
                self?.queue.async {
                    self?.sendSecure(BridgeWireMessage(
                        type: "codexConversationDraftReceipt",
                        detail: detail,
                        submissionID: submissionID.uuidString,
                        draftID: draftID.uuidString,
                        codexConversationTarget: target,
                        resolvedCodexConversationTarget: resolvedTarget,
                        accepted: accepted
                    ))
                }
            }

        case "command":
            // This service accepts only the dedicated Wrist Remote protocol.
            sendOperationError("腕上遥控桥只接受 Apple Watch 独立映射事件。")

        default:
            break
        }
    }

    private func handleWatchProfileUpdate(_ message: BridgeWireMessage) {
        guard WatchProfileSession.acceptsProfileUpdateSource(
                  inputSource: message.inputSource
              ),
              let encoded = message.watchProfile,
              let profile = try? WatchActionProfileWire.decodeBase64(encoded),
              message.profileRevision == profile.revision
        else {
            sendWatchProfileRejected(revision: message.profileRevision, detail: "映射数据无效。")
            return
        }
        if let retryReason = WatchProfileRuntimeUpdatePolicy.retryReason(for: voiceSession) {
            sendWatchProfileRejected(
                revision: profile.revision,
                detail: "语音进行中，独立映射保持不变；结束语音后将自动重试。",
                retryReason: retryReason
            )
            return
        }
        switch watchProfileSession.begin(profile) {
        case let .alreadyReady(revision):
            sendWatchProfileReady(revision)
        case let .reject(revision, detail):
            sendWatchProfileRejected(revision: revision, detail: detail)
        case let .accept(profile):
            guard let onWatchProfileUpdate else {
                _ = watchProfileSession.complete(revision: profile.revision, succeeded: false)
                sendWatchProfileRejected(revision: profile.revision, detail: "无法安装映射。")
                return
            }
            onWatchProfileUpdate(profile) { [weak self] result in
                self?.queue.async {
                    guard let self,
                          let accepted = self.watchProfileSession.complete(
                              revision: profile.revision,
                              succeeded: result.isAccepted
                          )
                    else { return }
                    if accepted {
                        self.sendWatchProfileReady(profile.revision)
                    } else {
                        let retryReason: WatchProfileUpdateRetryReason?
                        let detail: String
                        switch result {
                        case .accepted:
                            retryReason = nil
                            detail = "无法安装映射。"
                        case .rejected:
                            retryReason = nil
                            detail = "映射引用了腕上遥控桥中不存在的独立 App。"
                        case let .retryable(reason):
                            retryReason = reason
                            detail = "语音进行中，独立映射保持不变；结束语音后将自动重试。"
                        }
                        self.sendWatchProfileRejected(
                            revision: profile.revision,
                            detail: detail,
                            retryReason: retryReason
                        )
                    }
                }
            }
        }
    }

    private func handleButtonTrigger(_ message: BridgeWireMessage) {
        guard let requestID = message.requestID,
              WristDirectBridgeProtocol.isCanonicalSessionID(requestID)
        else { sendOperationError("按键缺少有效请求编号。"); return }
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        handledButtonRequestIDs = handledButtonRequestIDs.filter {
            now >= $0.value && now - $0.value <= WristDirectBridgeProtocol.buttonCommitLifetimeMilliseconds
        }
        guard WristDirectBridgeProtocol.isFreshButtonCommit(message, nowEpochMilliseconds: now),
              handledButtonRequestIDs[requestID] == nil,
              handledButtonRequestIDs.count < 256,
              message.inputSource == "iPhone" || message.inputSource == BridgeWireMessage.appleWatchInputSource,
              let command = message.command, let button = WristRemoteButton(rawValue: command),
              let rawTrigger = message.buttonTrigger, let trigger = WristRemoteTrigger(rawValue: rawTrigger),
              let revision = message.profileRevision,
              let issuedAt = message.issuedAtEpochMilliseconds,
              watchProfileSession.accepts(inputSource: BridgeWireMessage.appleWatchInputSource, revision: revision),
              currentWatchProfile == watchProfileSession.acceptedProfile,
              let onWatchButtonTrigger
        else {
            sendSecure(BridgeWireMessage(
                type: "buttonTriggerResult", detail: "按键已过期、已处理，或映射尚未确认。",
                requestID: requestID, accepted: false
            ))
            return
        }
        handledButtonRequestIDs[requestID] = now
        onWatchButtonTrigger(button, trigger, revision, issuedAt) { [weak self] accepted in
            self?.queue.async {
                guard let self, !self.closed else { return }
                self.sendSecure(BridgeWireMessage(
                    type: "buttonTriggerResult",
                    detail: accepted ? nil : "动作未执行，请检查系统权限和当前映射。",
                    requestID: requestID, accepted: accepted
                ))
            }
        }
    }

    private func sendWatchProfileReady(_ revision: Int) {
        sendSecure(BridgeWireMessage(type: "watchProfileReady", profileRevision: revision))
    }

    private func sendWatchProfileRejected(
        revision: Int?,
        detail: String,
        retryReason: WatchProfileUpdateRetryReason? = nil
    ) {
        sendSecure(BridgeWireMessage(
            type: "watchProfileRejected",
            detail: detail,
            profileRevision: revision,
            profileUpdateRetryReason: retryReason
        ))
    }

    private func sendVoiceRejected(
        sessionID: String?,
        profileRevision: Int?,
        target: VoiceTarget?
    ) {
        sendSecure(BridgeWireMessage(
            type: "voiceRejected",
            sessionID: sessionID,
            inputSource: BridgeWireMessage.appleWatchInputSource,
            profileRevision: profileRevision,
            voiceIntent: target?.intent.rawValue,
            threadID: target?.codexTaskIdentity?.threadID,
            turnID: target?.codexTaskIdentity?.turnID,
            taskRevision: target?.codexTaskIdentity?.revision,
            codexConversationTarget: target?.codexConversationTarget
        ))
    }

    private func sendAudioReceipt(
        _ receipt: WristBridgeAudioDeliveryReceipt,
        for message: BridgeWireMessage
    ) {
        sendSecure(BridgeWireMessage(
            type: "audioAck",
            audioSequence: receipt.sequence,
            audioAccepted: receipt.accepted,
            audioContiguousThrough: receipt.contiguousThrough,
            sessionID: message.sessionID,
            inputSource: BridgeWireMessage.appleWatchInputSource,
            profileRevision: message.profileRevision,
            voiceIntent: activeVoiceIntent.rawValue,
            threadID: activeVoiceCodexTaskIdentity?.threadID,
            turnID: activeVoiceCodexTaskIdentity?.turnID,
            taskRevision: activeVoiceCodexTaskIdentity?.revision,
            codexConversationTarget: activeVoiceCodexConversationTarget
        ))
    }

    private func sendOperationError(_ detail: String) {
        sendSecure(BridgeWireMessage(type: "error", detail: detail))
    }

    private func sendCodexReplyResult(
        submissionID: UUID,
        identity: WatchCodexTaskIdentity,
        accepted: Bool,
        detail: String?
    ) {
        sendSecure(BridgeWireMessage(
            type: "codexReplyResult",
            detail: detail,
            threadID: identity.threadID,
            turnID: identity.turnID,
            taskRevision: identity.revision,
            submissionID: submissionID.uuidString,
            accepted: accepted
        ))
    }

    private func acceptsVoiceTarget(_ target: VoiceTarget) -> Bool {
        switch target.intent {
        case .foregroundDictation:
            return target.codexTaskIdentity == nil
                && target.codexConversationTarget == nil
        case .codexTask:
            return target.codexConversationTarget == nil
                && WristRemoteCodexTargetValidator.accepts(
                target.codexTaskIdentity,
                snapshot: codexTaskSnapshot
            )
        case .codexConversation:
            guard target.codexTaskIdentity == nil,
                  let conversationTarget = target.codexConversationTarget,
                  conversationTarget.kind == .existing,
                  !conversationTarget.isExpired(
                    atEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                  )
            else { return false }
            return codexConversationCatalog?.entries.contains(where: {
                $0.target == conversationTarget && $0.canAcceptInput
            }) == true
        }
    }

    private func voiceTarget(
        from message: BridgeWireMessage,
        intent: WatchVoiceIntent
    ) -> VoiceTarget? {
        let identity = wireCodexTaskIdentity(from: message)
        let conversationTarget = message.codexConversationTarget
        switch intent {
        case .foregroundDictation:
            guard message.threadID == nil,
                  message.turnID == nil,
                  message.taskRevision == nil,
                  conversationTarget == nil
            else { return nil }
        case .codexTask:
            guard identity != nil, conversationTarget == nil else { return nil }
        case .codexConversation:
            guard identity == nil, conversationTarget != nil else { return nil }
        }
        return VoiceTarget(
            intent: intent,
            codexTaskIdentity: identity,
            codexConversationTarget: conversationTarget
        )
    }

    private func wireCodexTaskIdentity(
        from message: BridgeWireMessage
    ) -> WatchCodexTaskIdentity? {
        WatchCodexTaskIdentity(
            threadID: message.threadID,
            turnID: message.turnID,
            revision: message.taskRevision
        )
    }

    private func messageMatchesActiveVoiceTarget(_ message: BridgeWireMessage) -> Bool {
        message.voiceIntent == activeVoiceIntent.rawValue
            && wireCodexTaskIdentity(from: message) == activeVoiceCodexTaskIdentity
            && message.codexConversationTarget == activeVoiceCodexConversationTarget
            && (activeVoiceIntent == .codexTask
                || (message.threadID == nil
                    && message.turnID == nil
                    && message.taskRevision == nil))
    }

    private func clearActiveVoiceTarget() {
        audioReceiveGate.reset()
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        activeVoiceCodexConversationTarget = nil
        activeVoiceSessionID = nil
    }

    private func close() {
        guard !closed else { return }
        closed = true
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        if voiceSession.stop(sessionID: nil, force: true) { onVoiceCancel?(activeVoiceSessionID) }
        clearActiveVoiceTarget()
        awaitingVoiceOutcomes.removeAll()
        watchProfileSession.reset()
        transport.onData = nil
        transport.onClosed = nil
        transport.cancel()
        sessionKey = nil
        secureChannel.reset()
        onClosed?(approved, requestedApproval && !approved)
        onClosed = nil
    }

    private func sendSecure(
        _ message: BridgeWireMessage,
        completion: (() -> Void)? = nil
    ) {
        guard let sessionKey,
              let envelope = secureChannel.seal(
                  message,
                  using: sessionKey,
                  senderRole: BridgeWireMessage.serverRole
              )
        else { return }
        sendPlain(envelope, cleartextMessage: message, completion: completion)
    }

    private func sendPlain(
        _ message: BridgeWireMessage,
        cleartextMessage: BridgeWireMessage? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        transport.send(data, message: cleartextMessage ?? message) { [weak self] succeeded in
            guard succeeded else {
                self?.cancel()
                return
            }
            completion?()
        }
    }

    private func decrypt(_ envelope: BridgeWireMessage) -> BridgeWireMessage? {
        guard let sessionKey else { return nil }
        return secureChannel.open(
            envelope,
            using: sessionKey,
            senderRole: BridgeWireMessage.clientRole
        )
    }

    private static func pairingCode(_ key: SymmetricKey) -> String {
        let value = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%06d", value % 1_000_000)
    }

    private static func canonicalUUID(_ rawValue: String?) -> UUID? {
        guard let rawValue,
              let value = UUID(uuidString: rawValue),
              value.uuidString == rawValue
        else { return nil }
        return value
    }

    private static func samples(from data: Data) -> [Int16] {
        var samples = [Int16]()
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(after: index)
            let low = UInt16(data[index])
            let high = UInt16(data[next]) << 8
            samples.append(Int16(bitPattern: low | high))
            index = data.index(next, offsetBy: 1)
        }
        return samples
    }

}

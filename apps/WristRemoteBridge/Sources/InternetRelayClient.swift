import Foundation

@MainActor
final class InternetRelayClient: ObservableObject {
    enum Status: Equatable {
        case stopped
        case connecting
        case connected
        case unavailable(String)
    }

    private struct RoomInitialization: Codable {
        let deviceID: String
        let deviceToken: String
    }

    private struct RoomInitializationResponse: Decodable {
        let initialized: Bool
        let protocolVersion: Int
    }

    private struct SocketMessage: Codable {
        let type: String
        let requestID: String
        let frame: WristInternetRelayFrame
    }

    @Published private(set) var status: Status = .stopped {
        didSet { onStatus?(status) }
    }

    let credentials: WristInternetRelayMacCredentials
    var onOperation: ((WristInternetRelayOperation) async -> WristInternetRelayResult)?
    var onStatus: ((Status) -> Void)?

    private let urlSession: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldRun = false
    private var reconnectAttempt = 0
    private var responseSequence: UInt64 = 0
    private let responseSenderID = UUID()
    private var replayWindow = WristInternetReplayWindow()
    private var recentResults: [UUID: WristInternetRelayResult] = [:]
    private var recentResultOrder: [UUID] = []

    init(
        credentials: WristInternetRelayMacCredentials,
        urlSession: URLSession? = nil
    ) {
        self.credentials = credentials
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            // Periodic 25-second WebSocket pings keep this long-lived session
            // below the inactivity budget. /init still has its own 12-second
            // request deadline.
            configuration.timeoutIntervalForRequest = 60
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    func start() {
        guard credentials.isValid else {
            status = .unavailable("公网凭证无效")
            return
        }
        shouldRun = true
        reconnectTask?.cancel()
        reconnectTask = nil
        guard connectionTask == nil, webSocket == nil else { return }
        connect()
    }

    func stop() {
        shouldRun = false
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        status = .stopped
    }

    private func connect() {
        guard shouldRun, connectionTask == nil else { return }
        status = .connecting
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { connectionTask = nil }
            do {
                try await initializeRoom()
                try Task.checkCancellation()
                let request = try bridgeRequest()
                let socket = urlSession.webSocketTask(with: request)
                webSocket = socket
                socket.resume()
                try await ping(socket)
                guard shouldRun, webSocket === socket else {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                reconnectAttempt = 0
                status = .connected
                beginReceiving(from: socket)
                beginHeartbeat(for: socket)
            } catch is CancellationError {
                return
            } catch {
                handleDisconnect(error.localizedDescription)
            }
        }
    }

    private func initializeRoom() async throws {
        let provisioning = credentials.provisioning
        let url = roomURL(pathSuffix: "init")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(credentials.macToken.wristBase64URLEncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(RoomInitialization(
            deviceID: provisioning.deviceID.uuidString,
            deviceToken: provisioning.deviceToken.wristBase64URLEncodedString()
        ))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw InternetRelayClientError.roomInitializationFailed }
        guard let initialization = try? JSONDecoder().decode(
            RoomInitializationResponse.self,
            from: data
        ), initialization.initialized
        else { throw InternetRelayClientError.roomInitializationFailed }
        guard WristInternetRelayConfiguration.supportsServerProtocolVersion(
            initialization.protocolVersion
        ) else {
            throw InternetRelayClientError.unsupportedProtocol(
                initialization.protocolVersion
            )
        }
    }

    private func bridgeRequest() throws -> URLRequest {
        var components = URLComponents(
            url: roomURL(pathSuffix: "bridge"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = "wss"
        guard let url = components?.url else {
            throw InternetRelayClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(credentials.macToken.wristBase64URLEncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func beginReceiving(from socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while shouldRun, webSocket === socket, !Task.isCancelled {
                    let message = try await socket.receive()
                    try await handle(message, socket: socket)
                }
            } catch is CancellationError {
                return
            } catch {
                guard shouldRun, webSocket === socket else { return }
                handleDisconnect(error.localizedDescription)
            }
        }
    }

    private func beginHeartbeat(for socket: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while shouldRun, webSocket === socket, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(25))
                    try Task.checkCancellation()
                    guard shouldRun, webSocket === socket else { return }
                    try await ping(socket)
                }
            } catch is CancellationError {
                return
            } catch {
                guard shouldRun, webSocket === socket else { return }
                handleDisconnect(error.localizedDescription)
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message,
        socket: URLSessionWebSocketTask
    ) async throws {
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw InternetRelayClientError.invalidMessage
        }
        guard data.count <= WristInternetRelayConfiguration.maximumCiphertextBytes + 8_192,
              let socketMessage = try? JSONDecoder().decode(SocketMessage.self, from: data),
              socketMessage.type == "relayRequest",
              UUID(uuidString: socketMessage.requestID) != nil
        else { throw InternetRelayClientError.invalidMessage }

        let frame = socketMessage.frame
        let result: WristInternetRelayResult
        if let cached = recentResults[frame.operationID] {
            result = cached
        } else if replayWindow.accept(frame, direction: .deviceToMac),
                  let operation = try? frame.open(
                    WristInternetRelayOperation.self,
                    direction: .deviceToMac,
                    operationID: frame.operationID,
                    keyData: credentials.provisioning.encryptionKey
                  ),
                  operation.operationID == frame.operationID,
                  let operation = operation.validated() {
            if let onOperation {
                result = await onOperation(operation)
            } else {
                result = WristInternetRelayResult(
                    operationID: operation.operationID,
                    accepted: false,
                    detail: "腕上遥控桥尚未就绪"
                )
            }
            remember(result)
        } else {
            result = WristInternetRelayResult(
                operationID: frame.operationID,
                accepted: false,
                detail: "请求已过期、重复或校验失败"
            )
        }

        responseSequence &+= 1
        let responseFrame = try WristInternetRelayFrame.seal(
            result,
            operationID: frame.operationID,
            senderID: responseSenderID,
            sequence: responseSequence,
            direction: .macToDevice,
            keyData: credentials.provisioning.encryptionKey
        )
        let response = SocketMessage(
            type: "relayResponse",
            requestID: socketMessage.requestID,
            frame: responseFrame
        )
        let encoded = try JSONEncoder().encode(response)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw InternetRelayClientError.invalidMessage
        }
        try await socket.send(.string(text))
    }

    private func remember(_ result: WristInternetRelayResult) {
        guard recentResults[result.operationID] == nil else { return }
        recentResults[result.operationID] = result
        recentResultOrder.append(result.operationID)
        if recentResultOrder.count > 256 {
            let overflow = recentResultOrder.count - 256
            let removed = Array(recentResultOrder.prefix(overflow))
            recentResultOrder.removeFirst(overflow)
            removed.forEach { recentResults.removeValue(forKey: $0) }
        }
    }

    private func handleDisconnect(_ detail: String) {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        guard shouldRun else {
            status = .stopped
            return
        }
        status = .unavailable(detail)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun, reconnectTask == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30)
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, shouldRun else { return }
            reconnectTask = nil
            connect()
        }
    }

    private func roomURL(pathSuffix: String) -> URL {
        credentials.provisioning.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("rooms")
            .appendingPathComponent(credentials.provisioning.roomID.uuidString)
            .appendingPathComponent(pathSuffix)
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum WristInternetRelayMacCredentialStore {
    private static let account = "mac-credentials-v1"
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge").internet-relay"
    }

    static func loadOrCreate() -> WristInternetRelayMacCredentials? {
        if let stored = WristInternetRelayKeychain.load(
            WristInternetRelayMacCredentials.self,
            account: account,
            service: service
        ), stored.isValid {
            guard stored.provisioning.baseURL
                    != WristInternetRelayConfiguration.productionBaseURL
            else { return stored }
            let migrated = WristInternetRelayMacCredentials(
                provisioning: WristInternetRelayDeviceProvisioning(
                    baseURL: WristInternetRelayConfiguration.productionBaseURL,
                    roomID: stored.provisioning.roomID,
                    deviceID: stored.provisioning.deviceID,
                    deviceToken: stored.provisioning.deviceToken,
                    encryptionKey: stored.provisioning.encryptionKey
                ),
                macToken: stored.macToken
            )
            guard WristInternetRelayKeychain.save(
                migrated,
                account: account,
                service: service
            ) else { return nil }
            return migrated
        }
        guard let generated = try? WristInternetRelayMacCredentials.generate(),
              WristInternetRelayKeychain.save(
                generated,
                account: account,
                service: service
              )
        else { return nil }
        return generated
    }
}

enum InternetRelayClientError: LocalizedError {
    case invalidURL
    case invalidMessage
    case roomInitializationFailed
    case unsupportedProtocol(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "公网中继地址无效"
        case .invalidMessage: return "公网中继返回了无效消息"
        case .roomInitializationFailed: return "无法初始化公网遥控房间"
        case let .unsupportedProtocol(version):
            return "公网中继协议不兼容（服务器 v\(version)）"
        }
    }
}

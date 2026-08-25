import Foundation

actor WristInternetRelayHTTPClient {
    private struct HTTPResponse: Codable {
        let requestID: String
        let frame: WristInternetRelayFrame
    }

    private let provisioning: WristInternetRelayDeviceProvisioning
    private let urlSession: URLSession
    private let senderID = UUID()
    private var sequence: UInt64 = 0
    private var isSending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        provisioning: WristInternetRelayDeviceProvisioning,
        urlSession: URLSession? = nil
    ) {
        self.provisioning = provisioning
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Public control has no offline queue: fail promptly and let the
            // foreground status recovery retry, never replay a stale action.
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = TimeInterval(
                WristInternetRelayRequestBudget.timeoutMilliseconds
            ) / 1_000
            configuration.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    func send(
        _ operation: WristInternetRelayOperation
    ) async throws -> WristInternetRelayResult {
        guard provisioning.isValid, operation.validated() != nil else {
            throw WristInternetRelayHTTPError.invalidRequest
        }
        await acquireSendSlot()
        defer { releaseSendSlot() }
        try Task.checkCancellation()
        if operation.kind == .buttonEvent, !operation.hasFreshButtonCommit() {
            throw WristInternetRelayHTTPError.expired
        }

        sequence &+= 1
        let frame = try WristInternetRelayFrame.seal(
            operation,
            operationID: operation.operationID,
            senderID: senderID,
            sequence: sequence,
            direction: .deviceToMac,
            keyData: provisioning.encryptionKey
        )
        var request = URLRequest(url: commandURL)
        request.httpMethod = "POST"
        // The caller must always outlive the Worker's 15-second response
        // deadline, otherwise an action could complete after Watch reports a
        // client-side timeout and invite an unsafe retry.
        request.timeoutInterval = TimeInterval(
            WristInternetRelayRequestBudget.timeoutMilliseconds
        ) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(provisioning.deviceToken.wristBase64URLEncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(frame)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WristInternetRelayHTTPError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw WristInternetRelayHTTPError.notAuthorized
        case 408, 429:
            throw WristInternetRelayHTTPError.busy
        case 503:
            throw WristInternetRelayHTTPError.bridgeOffline
        default:
            throw WristInternetRelayHTTPError.server(http.statusCode)
        }
        guard data.count <= WristInternetRelayConfiguration.maximumCiphertextBytes + 8_192,
              let wrapper = try? JSONDecoder().decode(HTTPResponse.self, from: data),
              UUID(uuidString: wrapper.requestID) != nil,
              wrapper.frame.operationID == operation.operationID,
              let result = try? wrapper.frame.open(
                WristInternetRelayResult.self,
                direction: .macToDevice,
                operationID: operation.operationID,
                keyData: provisioning.encryptionKey
              ),
              result.isValid(for: operation.operationID)
        else { throw WristInternetRelayHTTPError.invalidResponse }
        return result
    }

    private var commandURL: URL {
        provisioning.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("rooms")
            .appendingPathComponent(provisioning.roomID.uuidString)
            .appendingPathComponent("command")
    }

    private func acquireSendSlot() async {
        if !isSending {
            isSending = true
            return
        }
        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    private func releaseSendSlot() {
        guard !sendWaiters.isEmpty else {
            isSending = false
            return
        }
        let next = sendWaiters.removeFirst()
        next.resume()
    }
}

enum WristInternetRelayHTTPError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case notAuthorized
    case bridgeOffline
    case busy
    case expired
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "公网请求无效"
        case .invalidResponse: return "公网中继返回无效数据"
        case .notAuthorized: return "公网遥控凭证已失效，请在局域网内重新连接一次"
        case .bridgeOffline: return "Mac 或腕上遥控桥当前离线"
        case .busy: return "公网中继繁忙，请稍后重试"
        case .expired: return "公网按键已过期，本次未执行"
        case let .server(code): return "公网中继错误（\(code)）"
        }
    }
}

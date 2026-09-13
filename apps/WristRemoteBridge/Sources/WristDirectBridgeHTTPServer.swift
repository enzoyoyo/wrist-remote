import Foundation
import Network

/// All implementations are confined to WristRemoteServer's serial queue.
protocol WristRemoteSessionTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    var name: String { get }
    func start()
    func send(_ data: Data, message: WristBridgeWireMessage, completion: @escaping (Bool) -> Void)
    func cancel()
}

final class WristRemoteTCPSessionTransport: WristRemoteSessionTransport {
    let name = "TCP"
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, message: WristBridgeWireMessage, completion: @escaping (Bool) -> Void) {
        guard !closed else { completion(false); return }
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?()
        onClosed = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            if let data { onData?(data) }
            if complete || error != nil { cancel() } else if !closed { receive() }
        }
    }
}

enum WristDirectBridgeHTTPError: Error, Equatable {
    case badRequest, headerTooLarge, payloadTooLarge, methodNotAllowed
    case routeNotFound, unsupportedMediaType, conflict, gone, unavailable

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .headerTooLarge: return 431
        case .payloadTooLarge: return 413
        case .methodNotAllowed: return 405
        case .routeNotFound: return 404
        case .unsupportedMediaType: return 415
        case .conflict: return 409
        case .gone: return 410
        case .unavailable: return 503
        }
    }
}

enum WristDirectBridgeHTTPCodec {
    static let maximumHeaderBytes = 8 * 1_024

    static func parse(_ data: Data) throws -> WristDirectBridgeHTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maximumHeaderBytes { throw WristDirectBridgeHTTPError.headerTooLarge }
            return nil
        }
        guard separator.lowerBound <= maximumHeaderBytes,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else { throw WristDirectBridgeHTTPError.headerTooLarge }
        var lines = header.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else {
            throw WristDirectBridgeHTTPError.badRequest
        }
        guard first[0] == "POST" else { throw WristDirectBridgeHTTPError.methodNotAllowed }
        guard first[1] == Substring(WristDirectBridgeConfiguration.route) else {
            throw WristDirectBridgeHTTPError.routeNotFound
        }
        var headers: [String: String] = [:]
        let tokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw WristDirectBridgeHTTPError.badRequest }
            let rawName = String(line[..<colon])
            guard !rawName.isEmpty, rawName.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
                throw WristDirectBridgeHTTPError.badRequest
            }
            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 })
            else { throw WristDirectBridgeHTTPError.badRequest }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil,
              let length = headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let count = Int(length)
        else { throw WristDirectBridgeHTTPError.badRequest }
        guard count <= WristDirectBridgeProtocol.maximumRequestBodyBytes else {
            throw WristDirectBridgeHTTPError.payloadTooLarge
        }
        guard headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
        else { throw WristDirectBridgeHTTPError.unsupportedMediaType }
        let total = separator.upperBound + count
        guard data.count >= total else { return nil }
        guard data.count == total,
              let request = try? JSONDecoder().decode(
                  WristDirectBridgeHTTPRequest.self,
                  from: data[separator.upperBound ..< total]
              )
        else { throw WristDirectBridgeHTTPError.badRequest }
        if let id = request.sessionID {
            guard WristDirectBridgeProtocol.isCanonicalSessionID(id), request.message.type == "secure" else {
                throw WristDirectBridgeHTTPError.badRequest
            }
        } else if request.message.type != "hello" {
            throw WristDirectBridgeHTTPError.badRequest
        }
        return request
    }

    static func response(status: Int, body: Data = Data("{}".utf8)) -> Data {
        var data = Data(("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Request Failed")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

/// HTTP is framing, not a second authentication system. Every exchange after
/// hello must supply the next valid encrypted message to read the outbox.
final class WristDirectHTTPSessionTransport: WristRemoteSessionTransport {
    let id = UUID().uuidString
    let name = "HTTP"
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    var onFinished: (() -> Void)?
    private let queue: DispatchQueue
    private struct OutboxEntry {
        let envelope: WristBridgeWireMessage
        let marker: WristBridgeWireMessage
    }
    private var outbox: [OutboxEntry] = []
    private var pendingReply: ((Result<WristDirectBridgeHTTPResponse, WristDirectBridgeHTTPError>) -> Void)?
    private var expiry: DispatchWorkItem?
    private var closed = false
    private var inputIsAuthenticated = false
    private var expectedResponse: ((WristBridgeWireMessage) -> Bool)?

    init(queue: DispatchQueue) { self.queue = queue }
    func start() { renewExpiry() }

    func exchange(
        _ message: WristBridgeWireMessage,
        completion: @escaping (Result<WristDirectBridgeHTTPResponse, WristDirectBridgeHTTPError>) -> Void
    ) {
        guard !closed else { completion(.failure(.gone)); return }
        guard pendingReply == nil else { completion(.failure(.conflict)); return }
        guard var data = try? JSONEncoder().encode(message) else {
            completion(.failure(.badRequest)); return
        }
        inputIsAuthenticated = false
        expectedResponse = nil
        pendingReply = completion
        data.append(0x0a)
        onData?(data)
        // The session marks accepted input after hello validation or successful
        // AEAD open. A guessed sessionID cannot drain pre-existing output.
        queue.async { [weak self] in self?.flush() }
    }

    func didAuthenticateInput(_ input: WristBridgeWireMessage) {
        inputIsAuthenticated = true
        expectedResponse = { response in
            if response.type == "error" || response.type == "denied" { return true }
            switch input.type {
            case "hello": return response.type == "serverKey"
            case "clientAuth": return response.type == "ready"
            case "livenessProbe": return response.type == "livenessAck" && response.probeID == input.probeID
            case "watchProfileUpdate":
                return ["watchProfileReady", "watchProfileRejected"].contains(response.type)
                    && response.profileRevision == input.profileRevision
            case "buttonTrigger":
                return response.type == "buttonTriggerResult" && response.requestID == input.requestID
            default: return false
            }
        }
        renewExpiry()
    }

    func send(_ data: Data, message: WristBridgeWireMessage, completion: @escaping (Bool) -> Void) {
        guard !closed,
              let envelope = try? JSONDecoder().decode(WristBridgeWireMessage.self, from: data),
              outbox.count < WristDirectBridgeProtocol.maximumOutboxMessages
        else { completion(false); cancel(); return }
        // Only correlation metadata accompanies ciphertext inside the framing
        // layer; full plaintext payloads are never retained in this outbox.
        let marker = WristBridgeWireMessage(
            type: message.type, profileRevision: message.profileRevision,
            requestID: message.requestID, probeID: message.probeID
        )
        outbox.append(OutboxEntry(envelope: envelope, marker: marker))
        guard let encoded = try? JSONEncoder().encode(outbox.map(\.envelope)),
              encoded.count <= WristDirectBridgeProtocol.maximumResponseBodyBytes - 128
        else { completion(false); cancel(); return }
        completion(true)
        queue.async { [weak self] in self?.flush() }
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        expiry?.cancel()
        expiry = nil
        let reply = pendingReply
        pendingReply = nil
        outbox.removeAll()
        reply?(.failure(.gone))
        onClosed?()
        onClosed = nil
        onFinished?()
        onFinished = nil
    }

    private func flush() {
        guard !closed, inputIsAuthenticated, let expectedResponse,
              outbox.contains(where: { expectedResponse($0.marker) }), let reply = pendingReply else { return }
        pendingReply = nil
        let response = WristDirectBridgeHTTPResponse(sessionID: id, messages: outbox.map(\.envelope))
        outbox.removeAll(keepingCapacity: true)
        reply(.success(response))
    }

    private func renewExpiry() {
        expiry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.cancel() }
        expiry = item
        queue.asyncAfter(deadline: .now() + 60, execute: item)
    }
}

final class WristDirectBridgeHTTPServer {
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var requests: [ObjectIdentifier: WristDirectHTTPConnection] = [:]
    private var sessions: [String: WristDirectHTTPSessionTransport] = [:]
    var onSession: ((WristDirectHTTPSessionTransport) -> Bool)?
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start(endpoint: NWEndpoint) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = endpoint
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready: onReady?()
            case .failed:
                stop()
                onFailure?()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let currentSessions = Array(sessions.values)
        sessions.removeAll()
        currentSessions.forEach { $0.cancel() }
        let currentRequests = Array(requests.values)
        requests.removeAll()
        currentRequests.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard requests.count < 16, WristRemotePeerAccessPolicy.permits(connection.endpoint) else {
            connection.cancel(); return
        }
        let client = WristDirectHTTPConnection(connection: connection, queue: queue)
        let id = ObjectIdentifier(client)
        requests[id] = client
        client.onClosed = { [weak self] in self?.requests.removeValue(forKey: id) }
        client.onRequest = { [weak self, weak client] request in
            guard let self, let client else { return }
            let session: WristDirectHTTPSessionTransport
            if let sessionID = request.sessionID {
                guard let existing = sessions[sessionID] else { client.send(status: 410); return }
                session = existing
            } else {
                guard sessions.count < 12 else { client.send(status: 503); return }
                session = WristDirectHTTPSessionTransport(queue: queue)
                sessions[session.id] = session
                let sessionID = session.id
                session.onFinished = { [weak self] in self?.sessions.removeValue(forKey: sessionID) }
                guard onSession?(session) == true else {
                    session.cancel(); client.send(status: 503); return
                }
            }
            client.onAbandoned = { [weak session] in session?.cancel() }
            session.exchange(request.message) { [weak client] result in
                guard let client else { return }
                switch result {
                case let .success(response):
                    guard let data = try? JSONEncoder().encode(response) else {
                        client.send(status: 500); return
                    }
                    client.send(status: 200, body: data)
                case let .failure(error): client.send(status: error.statusCode)
                }
            }
        }
        client.start()
    }
}

private final class WristDirectHTTPConnection {
    var onRequest: ((WristDirectBridgeHTTPRequest) -> Void)?
    var onClosed: (() -> Void)?
    var onAbandoned: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var finished = false
    private var receivedRequest = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !finished, !receivedRequest else { return }
            send(status: 408)
        }
        queue.asyncAfter(deadline: .now() + 40) { [weak self] in self?.cancel() }
    }

    func send(status: Int, body: Data = Data("{}".utf8)) {
        guard !finished else { return }
        finished = true
        onAbandoned = nil
        connection.send(content: WristDirectBridgeHTTPCodec.response(status: status, body: body),
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onAbandoned?()
        onAbandoned = nil
        close()
    }

    private func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?()
        onClosed = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, complete, error in
            guard let self, !finished else { return }
            if receivedRequest {
                if data?.isEmpty == false || complete || error != nil { cancel() }
                else { receive() }
                return
            }
            if let data { buffer.append(data) }
            do {
                if let request = try WristDirectBridgeHTTPCodec.parse(buffer) {
                    receivedRequest = true
                    buffer.removeAll()
                    onRequest?(request)
                    if !finished { receive() }
                    return
                }
            } catch let error as WristDirectBridgeHTTPError {
                send(status: error.statusCode); return
            } catch {
                send(status: 400); return
            }
            if complete || error != nil { cancel() } else { receive() }
        }
    }
}

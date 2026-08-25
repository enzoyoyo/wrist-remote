import Foundation
import Network
import CryptoKit

final class CodexHookReceiver {
    static let loopbackHost = "127.0.0.1"
    static let port: UInt16 = 60_928
    static let route = "/codex-hook"

    enum State: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    private let coordinator: CodexTaskCoordinator
    private let listenPort: UInt16
    private let bearerToken: String?
    private let queue = DispatchQueue(label: "WristRemoteBridge.codex-hook", qos: .utility)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: CodexHookHTTPClient] = [:]

    var onStateChange: ((State) -> Void)?

    init(
        coordinator: CodexTaskCoordinator,
        port: UInt16 = CodexHookReceiver.port,
        bearerToken: String? = CodexHookTokenStore.loadOrCreate()
    ) {
        self.coordinator = coordinator
        listenPort = port
        self.bearerToken = bearerToken
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        publish(.starting)
        guard let bearerToken else {
            publish(.failed("Codex hook authentication could not be initialized."))
            return
        }
        do {
            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                publish(.failed("Codex hook port is invalid."))
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(Self.loopbackHost),
                port: port
            )
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.publish(.ready)
                case let .failed(error):
                    self.listener = nil
                    self.closeAllClients()
                    self.publish(.failed(error.localizedDescription))
                case .cancelled:
                    self.listener = nil
                    self.closeAllClients()
                    self.publish(.stopped)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, bearerToken: bearerToken)
            }
            listener.start(queue: queue)
        } catch {
            listener = nil
            publish(.failed(error.localizedDescription))
        }
    }

    private func stopOnQueue() {
        guard let listener else {
            closeAllClients()
            publish(.stopped)
            return
        }
        self.listener = nil
        listener.cancel()
        closeAllClients()
        publish(.stopped)
    }

    private func accept(_ connection: NWConnection, bearerToken: String) {
        let client = CodexHookHTTPClient(
            connection: connection,
            queue: queue,
            bearerToken: bearerToken
        )
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client
        client.onBody = { [weak self, weak client] body in
            guard let self, let client else { return }
            Task {
                let response: CodexHookHTTPResponse
                do {
                    let result = try await self.coordinator.ingest(jsonData: body)
                    response = .json(
                        statusCode: result.disposition == .accepted ? 202 : 200,
                        reason: result.disposition == .accepted ? "Accepted" : "OK",
                        body: CodexHookAcknowledgement(
                            accepted: true,
                            disposition: result.disposition.rawValue
                        )
                    )
                } catch {
                    response = .json(
                        statusCode: 422,
                        reason: "Unprocessable Content",
                        body: CodexHookAcknowledgement(
                            accepted: false,
                            disposition: "invalid_payload"
                        )
                    )
                }
                client.send(response)
            }
        }
        client.onClosed = { [weak self] in
            self?.clients.removeValue(forKey: identifier)
        }
        client.start()
    }

    private func closeAllClients() {
        let currentClients = Array(clients.values)
        clients.removeAll()
        currentClients.forEach { $0.cancel() }
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

private struct CodexHookAcknowledgement: Encodable {
    let accepted: Bool
    let disposition: String
}

struct CodexHookHTTPRequest: Equatable {
    let body: Data
}

enum CodexHookHTTPError: Error, Equatable {
    case badRequest
    case payloadTooLarge
    case headerTooLarge
    case methodNotAllowed
    case routeNotFound
    case unsupportedMediaType
    case unauthorized

    var response: CodexHookHTTPResponse {
        switch self {
        case .badRequest:
            return .plain(statusCode: 400, reason: "Bad Request")
        case .payloadTooLarge:
            return .plain(statusCode: 413, reason: "Content Too Large")
        case .headerTooLarge:
            return .plain(statusCode: 431, reason: "Request Header Fields Too Large")
        case .methodNotAllowed:
            return .plain(statusCode: 405, reason: "Method Not Allowed")
        case .routeNotFound:
            return .plain(statusCode: 404, reason: "Not Found")
        case .unsupportedMediaType:
            return .plain(statusCode: 415, reason: "Unsupported Media Type")
        case .unauthorized:
            return .plain(
                statusCode: 401,
                reason: "Unauthorized",
                headers: ["WWW-Authenticate": "Bearer"]
            )
        }
    }
}

enum CodexHookHTTPCodec {
    static let maximumHeaderBytes = 16 * 1_024
    static let maximumBodyBytes = 512 * 1_024
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    static func parse(
        _ data: Data,
        expectedBearerToken: String
    ) throws -> CodexHookHTTPRequest? {
        guard let delimiterRange = data.range(of: headerDelimiter) else {
            if data.count > maximumHeaderBytes { throw CodexHookHTTPError.headerTooLarge }
            return nil
        }
        guard delimiterRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(
                  data: data[..<delimiterRange.lowerBound],
                  encoding: .utf8
              )
        else { throw CodexHookHTTPError.headerTooLarge }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw CodexHookHTTPError.badRequest }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0"
        else { throw CodexHookHTTPError.badRequest }

        guard requestLine[0] == "POST" else { throw CodexHookHTTPError.methodNotAllowed }
        guard requestLine[1] == Substring(CodexHookReceiver.route) else {
            throw CodexHookHTTPError.routeNotFound
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                throw CodexHookHTTPError.badRequest
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else {
                throw CodexHookHTTPError.badRequest
            }
            headers[name] = value
        }

        guard headers["transfer-encoding"] == nil,
              let rawLength = headers["content-length"],
              let contentLength = Int(rawLength),
              contentLength >= 0
        else { throw CodexHookHTTPError.badRequest }
        guard contentLength <= maximumBodyBytes else {
            throw CodexHookHTTPError.payloadTooLarge
        }
        guard let contentType = headers["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              contentType == "application/json"
        else { throw CodexHookHTTPError.unsupportedMediaType }
        guard let authorization = headers["authorization"],
              authorization.hasPrefix("Bearer "),
              secureCompare(
                  String(authorization.dropFirst("Bearer ".count)),
                  expectedBearerToken
              )
        else { throw CodexHookHTTPError.unauthorized }

        let bodyStart = delimiterRange.upperBound
        let totalLength = bodyStart + contentLength
        guard data.count >= totalLength else { return nil }
        guard data.count == totalLength else { throw CodexHookHTTPError.badRequest }
        return CodexHookHTTPRequest(body: Data(data[bodyStart..<totalLength]))
    }

    private static func secureCompare(_ supplied: String, _ expected: String) -> Bool {
        let suppliedDigest = SHA256.hash(data: Data(supplied.utf8))
        let expectedDigest = SHA256.hash(data: Data(expected.utf8))
        return zip(suppliedDigest, expectedDigest).reduce(UInt8(0)) { mismatch, pair in
            mismatch | (pair.0 ^ pair.1)
        } == 0
    }
}

struct CodexHookHTTPResponse: Equatable {
    let statusCode: Int
    let reason: String
    let contentType: String
    let body: Data
    let headers: [String: String]

    static func plain(
        statusCode: Int,
        reason: String,
        headers: [String: String] = [:]
    ) -> CodexHookHTTPResponse {
        CodexHookHTTPResponse(
            statusCode: statusCode,
            reason: reason,
            contentType: "text/plain; charset=utf-8",
            body: Data(reason.utf8),
            headers: headers
        )
    }

    static func json<Body: Encodable>(
        statusCode: Int,
        reason: String,
        body: Body
    ) -> CodexHookHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(body)) ?? Data("{}".utf8)
        return CodexHookHTTPResponse(
            statusCode: statusCode,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            body: encoded,
            headers: [:]
        )
    }

    var encoded: Data {
        var response = Data(
            "HTTP/1.1 \(statusCode) \(reason)\r\n".utf8
        )
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Cache-Control: no-store\r\n".utf8))
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            response.append(Data("\(name): \(value)\r\n".utf8))
        }
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        return response
    }
}

private final class CodexHookHTTPClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let bearerToken: String
    private var buffer = Data()
    private var didFinish = false

    var onBody: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, bearerToken: String) {
        self.connection = connection
        self.queue = queue
        self.bearerToken = bearerToken
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !didFinish else { return }
            send(.plain(statusCode: 408, reason: "Request Timeout"))
        }
    }

    func send(_ response: CodexHookHTTPResponse) {
        queue.async { [weak self] in
            guard let self, !didFinish else { return }
            didFinish = true
            connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
                self?.onClosed?()
                self?.onClosed = nil
            })
        }
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        connection.cancel()
        onClosed?()
        onClosed = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] content, _, isComplete, error in
            guard let self, !didFinish else { return }
            if let content { buffer.append(content) }
            do {
                if let request = try CodexHookHTTPCodec.parse(
                    buffer,
                    expectedBearerToken: bearerToken
                ) {
                    onBody?(request.body)
                    return
                }
            } catch let error as CodexHookHTTPError {
                send(error.response)
                return
            } catch {
                send(CodexHookHTTPError.badRequest.response)
                return
            }
            if error != nil || isComplete {
                send(CodexHookHTTPError.badRequest.response)
            } else {
                receive()
            }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onClosed?()
        onClosed = nil
    }
}

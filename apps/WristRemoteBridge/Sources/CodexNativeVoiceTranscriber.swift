import Foundation

/// All cases occur before queue/add. Never include provider bodies, credentials,
/// audio paths or recognized speech in diagnostics.
enum CodexNativeVoiceError: Error, Equatable, LocalizedError {
    case authenticationRequired
    case invalidRecording
    case unavailable
    case rateLimited
    case emptyTranscript
    case responseTooLarge
    case cancelled
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Codex 转写需要已登录的 ChatGPT 账号；本次未发送。"
        case .invalidRecording:
            return "录音无效，未发送到 Codex。"
        case .unavailable:
            return "Codex 转写未成功，本次未发送；请稍后重新录音。"
        case .rateLimited:
            return "Codex 转写暂时受限，本次未发送；请稍后再试。"
        case .emptyTranscript:
            return "Codex 没有识别出文字，本次未发送；请重新录音。"
        case .responseTooLarge:
            return "转写结果超出安全限制，本次未发送。"
        case .cancelled:
            return "语音发送已取消，未进入 Codex 队列。"
        case .targetChanged:
            return "所选任务或连接已经变化，语音未发送；请重新选择。"
        }
    }
}

/// Obtained through the installed Codex app-server, never from auth files or
/// Keychain scraping. Deliberately not Codable; only retained for this request.
struct CodexNativeVoiceAuthentication: Sendable, CustomStringConvertible {
    fileprivate let token: String
    fileprivate let accountID: String?

    var description: String { "CodexNativeVoiceAuthentication(redacted)" }

    init(response: [String: Any]) throws {
        guard let method = response["authMethod"] as? String,
              ["chatgpt", "chatgptAuthTokens"].contains(method),
              let token = response["authToken"] as? String,
              Self.isSafeHeader(token, maximumBytes: 16 * 1_024)
        else { throw CodexNativeVoiceError.authenticationRequired }
        self.token = token
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded),
               let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let auth = claims["https://api.openai.com/auth"] as? [String: Any],
               let accountID = auth["chatgpt_account_id"] as? String {
                guard Self.isSafeHeader(accountID, maximumBytes: 256) else {
                    throw CodexNativeVoiceError.authenticationRequired
                }
                self.accountID = accountID
                return
            }
        }
        accountID = nil
    }

    private static func isSafeHeader(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

protocol CodexVoiceTranscriptionTransport: Sendable {
    func response(for request: URLRequest, maximumBytes: Int) async throws -> (Data, Int)
}

/// No cookies, disk cache, redirect following, retries, or configurable host.
struct CodexVoiceHTTPTransport: CodexVoiceTranscriptionTransport {
    final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func response(for request: URLRequest, maximumBytes: Int) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 35
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url == CodexNativeVoiceTranscriber.endpoint
        else { throw CodexNativeVoiceError.unavailable }
        guard response.statusCode == 200 else { return (Data(), response.statusCode) }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw CodexNativeVoiceError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw CodexNativeVoiceError.responseTooLarge }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}

struct CodexNativeVoiceTranscriber: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    static let maximumResponseBytes = 64 * 1_024
    private let transport: any CodexVoiceTranscriptionTransport

    init(transport: any CodexVoiceTranscriptionTransport = CodexVoiceHTTPTransport()) {
        self.transport = transport
    }

    func transcribe(audio: Data, authentication: CodexNativeVoiceAuthentication) async throws -> String {
        guard (44...(8 * 1_024 * 1_024)).contains(audio.count),
              String(data: audio.prefix(4), encoding: .ascii) == "RIFF",
              String(data: audio[8..<12], encoding: .ascii) == "WAVE"
        else { throw CodexNativeVoiceError.invalidRecording }
        do {
            try Task.checkCancellation()
            let boundary = "WristRemote-\(UUID().uuidString)"
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(audio)
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(authentication.token)", forHTTPHeaderField: "Authorization")
            request.setValue(authentication.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("wrist_remote_bridge", forHTTPHeaderField: "originator")
            request.setValue("WristRemoteBridge/0.5.0", forHTTPHeaderField: "User-Agent")
            let (data, status) = try await transport.response(for: request, maximumBytes: Self.maximumResponseBytes)
            try Task.checkCancellation()
            switch status {
            case 200: break
            case 401, 403: throw CodexNativeVoiceError.authenticationRequired
            case 429: throw CodexNativeVoiceError.rateLimited
            default: throw CodexNativeVoiceError.unavailable
            }
            guard data.count <= Self.maximumResponseBytes else { throw CodexNativeVoiceError.responseTooLarge }
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = result["text"] as? String
            else { throw CodexNativeVoiceError.unavailable }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw CodexNativeVoiceError.emptyTranscript }
            guard transcript.utf8.count <= 32 * 1_024 else { throw CodexNativeVoiceError.responseTooLarge }
            return transcript
        } catch is CancellationError {
            throw CodexNativeVoiceError.cancelled
        } catch let error as CodexNativeVoiceError {
            throw error
        } catch {
            throw Task.isCancelled ? CodexNativeVoiceError.cancelled : .unavailable
        }
    }
}

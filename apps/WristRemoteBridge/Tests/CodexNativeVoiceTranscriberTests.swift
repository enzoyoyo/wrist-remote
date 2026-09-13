import Foundation
import XCTest
@testable import WristRemoteBridge

actor StubCodexVoiceTransport: CodexVoiceTranscriptionTransport {
    private(set) var requests: [URLRequest] = []
    let data: Data
    let status: Int
    let suspends: Bool

    init(text: String = "测试语音", status: Int = 200, data: Data? = nil, suspends: Bool = false) {
        self.data = data ?? (try! JSONSerialization.data(withJSONObject: ["text": text]))
        self.status = status
        self.suspends = suspends
    }

    func response(for request: URLRequest, maximumBytes: Int) async throws -> (Data, Int) {
        requests.append(request)
        if suspends { try await Task.sleep(for: .seconds(60)) }
        return (data, status)
    }

    func waitUntilRequested() async {
        while requests.isEmpty { await Task.yield() }
    }
}

final class CodexNativeVoiceTranscriberTests: XCTestCase {
    func testUnitTestLaunchNeverStartsProductionBridge() {
        XCTAssertTrue(BridgeLaunchPolicy.isUnitTestHost(
            environment: [:], bundleIdentifier: "org.example.wristremote.bridge.testsession", xctestLoaded: false
        ))
        XCTAssertTrue(BridgeLaunchPolicy.isUnitTestHost(
            environment: ["XCTestConfigurationFilePath": "/test-only"], bundleIdentifier: nil, xctestLoaded: false
        ))
        XCTAssertTrue(BridgeLaunchPolicy.isUnitTestHost(
            environment: [:], bundleIdentifier: nil, xctestLoaded: true
        ))
        XCTAssertFalse(BridgeLaunchPolicy.isUnitTestHost(
            environment: [:], bundleIdentifier: "org.example.wristremote.bridge", xctestLoaded: false
        ))
    }

    private var audio: Data {
        var data = Data(repeating: 0, count: 44)
        data.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        data.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        return data
    }

    private func authentication() throws -> CodexNativeVoiceAuthentication {
        try .init(response: ["authMethod": "chatgpt", "authToken": "fake-test-only-token"])
    }

    func testOnlyChatGPTLoginAndSafeHeadersAreAccepted() throws {
        for response: [String: Any] in [
            [:], ["authMethod": "apikey", "authToken": "not-an-allowed-auth-mode"],
            ["authMethod": "chatgpt", "authToken": ""],
            ["authMethod": "chatgpt", "authToken": "fake\r\nInjected: yes"],
        ] {
            XCTAssertThrowsError(try CodexNativeVoiceAuthentication(response: response)) {
                XCTAssertEqual($0 as? CodexNativeVoiceError, .authenticationRequired)
            }
        }
        XCTAssertFalse(String(describing: try authentication()).contains("fake-test-only-token"))
    }

    func testFixedNativeEndpointMultipartAndTextParsing() async throws {
        let transport = StubCodexVoiceTransport(text: "  只回复语音收到。\n")
        let value = try await CodexNativeVoiceTranscriber(transport: transport).transcribe(
            audio: audio, authentication: authentication()
        )
        XCTAssertEqual(value, "只回复语音收到。")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-only-token")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: audio))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("filename=\"voice.wav\""))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\r\nzh\r\n"))
    }

    func testErrorsAreTypedRedactedAndNeverRetried() async throws {
        let cases: [(Data, Int, CodexNativeVoiceError)] = [
            (Data("provider-secret-body".utf8), 500, .unavailable),
            (Data(), 302, .unavailable),
            (Data(), 401, .authenticationRequired),
            (Data(), 429, .rateLimited),
            (Data("not-json".utf8), 200, .unavailable),
            (Data("{\"text\":\"   \"}".utf8), 200, .emptyTranscript),
            (Data(repeating: 65, count: 65 * 1_024), 200, .responseTooLarge),
        ]
        for (data, status, expected) in cases {
            let transport = StubCodexVoiceTransport(status: status, data: data)
            do {
                _ = try await CodexNativeVoiceTranscriber(transport: transport).transcribe(
                    audio: audio, authentication: authentication()
                )
                XCTFail("Expected a bounded native transcription failure")
            } catch {
                XCTAssertEqual(error as? CodexNativeVoiceError, expected)
                XCTAssertFalse(error.localizedDescription.contains("provider-secret-body"))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testInvalidWaveNeverLeavesDevice() async throws {
        let transport = StubCodexVoiceTransport()
        do {
            _ = try await CodexNativeVoiceTranscriber(transport: transport).transcribe(
                audio: Data(repeating: 0, count: 44), authentication: authentication()
            )
            XCTFail("Invalid audio must fail before HTTP")
        } catch { XCTAssertEqual(error as? CodexNativeVoiceError, .invalidRecording) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationStopsTranscription() async throws {
        let transport = StubCodexVoiceTransport(suspends: true)
        let audio = audio
        let authentication = try authentication()
        let task = Task {
            try await CodexNativeVoiceTranscriber(transport: transport).transcribe(
                audio: audio, authentication: authentication
            )
        }
        await transport.waitUntilRequested()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled audio must not yield a transcript")
        } catch { XCTAssertEqual(error as? CodexNativeVoiceError, .cancelled) }
    }

    func testRedirectDelegateNeverForwardsCredentials() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://example.invalid/redirect")!)
        let task = session.dataTask(with: CodexNativeVoiceTranscriber.endpoint)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: CodexNativeVoiceTranscriber.endpoint, statusCode: 302,
            httpVersion: nil, headerFields: nil
        ))
        var called = false
        CodexVoiceHTTPTransport.RedirectBlocker().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request
        ) {
            XCTAssertNil($0)
            called = true
        }
        XCTAssertTrue(called)
    }
}

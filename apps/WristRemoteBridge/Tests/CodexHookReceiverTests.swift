import Foundation
import XCTest
@testable import WristRemoteBridge

final class CodexHookReceiverTests: XCTestCase {
    private let bearerToken = String(repeating: "A", count: 43)

    func testReceiverUsesDedicatedIPv4LoopbackEndpoint() {
        XCTAssertEqual(CodexHookReceiver.loopbackHost, "127.0.0.1")
        XCTAssertEqual(CodexHookReceiver.port, 60_928)
        XCTAssertEqual(CodexHookReceiver.route, "/codex-hook")
        XCTAssertNotEqual(CodexHookReceiver.port, 60_927)
    }

    func testParsesCurlStyleJSONPostOnlyAfterCompleteBody() throws {
        let body = Data(#"{"session_id":"thread","turn_id":"turn"}"#.utf8)
        let request = makeRequest(body: body)
        XCTAssertNil(try CodexHookHTTPCodec.parse(
            request.dropLast(),
            expectedBearerToken: bearerToken
        ))

        let parsed = try XCTUnwrap(CodexHookHTTPCodec.parse(
            request,
            expectedBearerToken: bearerToken
        ))
        XCTAssertEqual(parsed.body, body)
    }

    func testRejectsNonPostWrongRouteAndNonJSON() {
        let body = Data("{}".utf8)
        assertHTTPError(
            makeRequest(method: "GET", body: body),
            equals: .methodNotAllowed
        )
        assertHTTPError(
            makeRequest(route: "/", body: body),
            equals: .routeNotFound
        )
        assertHTTPError(
            makeRequest(contentType: "text/plain", body: body),
            equals: .unsupportedMediaType
        )
    }

    func testRejectsDuplicateContentLengthAndTrailingBytes() {
        let duplicateLength = Data((
            "POST /codex-hook HTTP/1.1\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: 2\r\n"
                + "Content-Length: 2\r\n\r\n{}"
        ).utf8)
        assertHTTPError(duplicateLength, equals: .badRequest)

        var trailing = makeRequest(body: Data("{}".utf8))
        trailing.append(0)
        assertHTTPError(trailing, equals: .badRequest)
    }

    func testRejectsDeclaredOversizedBodyWithoutWaitingForIt() {
        let request = Data((
            "POST /codex-hook HTTP/1.1\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(CodexHookHTTPCodec.maximumBodyBytes + 1)\r\n\r\n"
        ).utf8)
        assertHTTPError(request, equals: .payloadTooLarge)
    }

    func testResponseIsConnectionClosingAndNoStore() {
        let response = CodexHookHTTPResponse.plain(statusCode: 400, reason: "Bad Request")
        let encoded = String(decoding: response.encoded, as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(encoded.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(encoded.contains("Connection: close\r\n"))
        XCTAssertTrue(encoded.hasSuffix("Bad Request"))
    }

    func testRejectsMissingOrIncorrectBearerToken() {
        assertHTTPError(
            makeRequest(omitAuthorization: true, body: Data("{}".utf8)),
            equals: .unauthorized
        )
        assertHTTPError(
            makeRequest(
                authorization: "Bearer incorrect",
                body: Data("{}".utf8)
            ),
            equals: .unauthorized
        )
    }

    func testReceiverAcceptsRealLoopbackPostAndUpdatesCoordinator() async throws {
        let coordinator = CodexTaskCoordinator()
        let receiver = CodexHookReceiver(
            coordinator: coordinator,
            port: 61_928,
            bearerToken: bearerToken
        )
        let ready = expectation(description: "loopback receiver ready")
        receiver.onStateChange = { state in
            if state == .ready { ready.fulfill() }
        }
        receiver.start()
        await fulfillment(of: [ready], timeout: 3)
        defer { receiver.stop() }

        let payload: [String: Any] = [
            "session_id": "11111111-1111-4111-8111-111111111111",
            "turn_id": "22222222-2222-4222-8222-222222222222",
            "hook_event_name": "UserPromptSubmit",
            "cwd": FileManager.default.temporaryDirectory.path,
            "prompt": "Example loopback prompt",
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:61928/codex-hook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot?.status, .running)
        XCTAssertEqual(snapshot?.summary, "Example loopback prompt")
    }

    private func makeRequest(
        method: String = "POST",
        route: String = "/codex-hook",
        contentType: String = "application/json",
        authorization: String? = nil,
        omitAuthorization: Bool = false,
        body: Data
    ) -> Data {
        let resolvedAuthorization = omitAuthorization
            ? nil
            : authorization ?? "Bearer \(bearerToken)"
        var data = Data((
            "\(method) \(route) HTTP/1.1\r\n"
                + "Host: 127.0.0.1:60928\r\n"
                + "Content-Type: \(contentType)\r\n"
                + (resolvedAuthorization.map { "Authorization: \($0)\r\n" } ?? "")
                + "Content-Length: \(body.count)\r\n\r\n"
        ).utf8)
        data.append(body)
        return data
    }

    private func assertHTTPError(
        _ data: Data,
        equals expected: CodexHookHTTPError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodexHookHTTPCodec.parse(data, expectedBearerToken: bearerToken),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? CodexHookHTTPError, expected, file: file, line: line)
        }
    }
}

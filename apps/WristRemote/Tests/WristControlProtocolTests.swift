import Foundation
import XCTest
@testable import WristRemote

final class WristControlProtocolTests: XCTestCase {
    func testPointerFlightLimitsAndClickBarrier() {
        XCTAssertTrue(WristControlFlightPolicy.mayStart(action: .pointer, direct: false, inFlight: 2, clickWaiting: false))
        XCTAssertFalse(WristControlFlightPolicy.mayStart(action: .pointer, direct: false, inFlight: 3, clickWaiting: false))
        XCTAssertFalse(WristControlFlightPolicy.mayStart(action: .pointer, direct: true, inFlight: 1, clickWaiting: false))
        XCTAssertFalse(WristControlFlightPolicy.mayStart(action: .pointer, direct: false, inFlight: 0, clickWaiting: true))
        XCTAssertFalse(WristControlFlightPolicy.mayStart(action: .click, direct: false, inFlight: 1, clickWaiting: false))
        XCTAssertTrue(WristControlFlightPolicy.mayStart(action: .click, direct: false, inFlight: 0, clickWaiting: false))
    }
    func testPointerBufferCoalescesFreshMovesAndDiscardsExpiredOrClearedMoves() {
        var buffer = WristPointerBuffer()
        let now = Date(timeIntervalSince1970: 10)
        buffer.add(x: 4, y: -3, now: now)
        buffer.add(x: 5, y: 1, now: now)
        let movement = buffer.take(now: now.addingTimeInterval(0.1))
        XCTAssertEqual(movement?.0, 9)
        XCTAssertEqual(movement?.1, -2)
        XCTAssertNil(buffer.take(now: now))
        buffer.add(x: 1000, y: -1000, now: now)
        let bounded = buffer.take(now: now)
        XCTAssertEqual(bounded?.0, 400)
        XCTAssertEqual(bounded?.1, -400)
        buffer.add(x: 5, y: 1, now: now)
        XCTAssertNil(buffer.take(now: now.addingTimeInterval(0.31)))
        buffer.add(x: 5, y: 1, now: now)
        buffer.add(x: 2, y: 3, now: now.addingTimeInterval(0.4))
        let recent = buffer.take(now: now.addingTimeInterval(0.4))
        XCTAssertEqual(recent?.0, 2)
        XCTAssertEqual(recent?.1, 3)
        buffer.add(x: 5, y: 1, now: now)
        buffer.clear()
        XCTAssertNil(buffer.take(now: now))
    }
    func testFreshnessCoordinatesAndTargetAreStrict() {
        let now: Int64 = 20_000
        XCTAssertTrue(WristControlCommand(action: .pointer, x: -240, y: 399, issuedAt: now).isValid(now: now))
        for issued in [now + 1, now - 1_501, 0] {
            XCTAssertFalse(WristControlCommand(action: .click, issuedAt: issued).isValid(now: now))
        }
        for value in [Double.nan, .infinity, -.infinity, 401, -401] {
            XCTAssertFalse(WristControlCommand(action: .pointer, x: value, issuedAt: now).isValid(now: now))
        }
        XCTAssertFalse(WristControlCommand(action: .click, x: 1, issuedAt: now).isValid(now: now))
        XCTAssertFalse(WristControlCommand(targetID: "mac;quit", action: .click, issuedAt: now).isValid(now: now))
    }

    func testDuplicateOperationsAreNeverReplayedAndExpiredOperationsStayRejected() {
        var gate = WristControlReplayGate()
        let command = WristControlCommand(action: .click, issuedAt: 20_000)
        XCTAssertTrue(gate.accept(command, now: 20_000))
        XCTAssertFalse(gate.accept(command, now: 20_001))
        XCTAssertFalse(gate.accept(command, now: 40_000))
        XCTAssertTrue(gate.accept(.init(action: .click, issuedAt: 40_000), now: 40_000))
    }

    func testCommandAndIndependentAudioModesSurviveWireEncoding() throws {
        for intent in [WatchVoiceIntent.recording, .wirelessMicrophone, .codexNativeDictation] {
            let wire = WristBridgeWireMessage(type: "voiceStart", voiceIntent: intent.rawValue)
            let decoded = try JSONDecoder().decode(WristBridgeWireMessage.self, from: JSONEncoder().encode(wire))
            XCTAssertEqual(decoded.voiceIntent, intent.rawValue)
            let outcome = WatchVoiceOutcome(sessionID: UUID().uuidString, intent: intent, threadID: nil,
                kind: .delivered, text: nil, detail: "已保存", localeIdentifier: "zh-CN")
            XCTAssertTrue(outcome.hasValidWireShape)
        }
        let command = WristControlCommand(action: .scroll, y: 20)
        XCTAssertEqual(try JSONDecoder().decode(WristControlCommand.self, from: JSONEncoder().encode(command)), command)
    }

    func testNativeCodexAudioCannotUsePublicRelay() {
        let start = WristInternetRelayOperation(kind: .voiceStart, profileRevision: 1,
            streamID: UUID(), voiceIntent: .codexNativeDictation)
        XCTAssertNil(start.validated())
    }

    func testReadingSessionControlsAreBoundedAndPreserveIdentity() {
        var state = WristReadingSessionState(id: UUID(), title: "提词", page: 0, pageCount: 3, isPlaying: false, speed: 1)
        let id = state.targetID
        XCTAssertTrue(state.isValid)
        XCTAssertTrue(state.apply(.previousPage)); XCTAssertEqual(state.page, 0)
        XCTAssertTrue(state.apply(.sessionPlayPause)); XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.apply(.nextPage)); XCTAssertEqual(state.page, 1)
        XCTAssertTrue(state.apply(.nextPage)); XCTAssertEqual(state.page, 2); XCTAssertFalse(state.isPlaying)
        for _ in 0..<50 { _ = state.apply(.sessionFaster) }
        XCTAssertEqual(state.speed, 2)
        for _ in 0..<50 { _ = state.apply(.sessionSlower) }
        XCTAssertEqual(state.speed, 0.5)
        XCTAssertFalse(state.apply(.pointer)); XCTAssertEqual(state.targetID, id)
        state.page = 3; XCTAssertFalse(state.isValid)
    }
}

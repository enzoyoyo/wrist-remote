import Foundation
import XCTest
@testable import WristRemoteBridge

final class WatchOnDeviceTranscriptAccumulatorTests: XCTestCase {
    func testVolatileCorrectionsReplaceTheTailInsteadOfDuplicatingIt() {
        var accumulator = WatchOnDeviceTranscriptAccumulator()

        accumulator.observe(text: "打开", isFinal: false)
        accumulator.observe(text: "打开 Codex", isFinal: false)

        XCTAssertEqual(accumulator.bestText, "打开 Codex")
    }

    func testFinalizedChineseSegmentsAreAssembledInOrder() {
        var accumulator = WatchOnDeviceTranscriptAccumulator()

        accumulator.observe(text: "请继续检查", isFinal: true)
        accumulator.observe(text: "这个任务。", isFinal: true)

        XCTAssertEqual(accumulator.bestText, "请继续检查这个任务。")
    }

    func testFinalizedTailReplacesMatchingVolatileGuess() {
        var accumulator = WatchOnDeviceTranscriptAccumulator()

        accumulator.observe(text: "新建一个会话", isFinal: false)
        accumulator.observe(text: "新建一个会话。", isFinal: true)

        XCTAssertEqual(accumulator.bestText, "新建一个会话。")
    }

    func testRepeatedFinalResultIsIdempotent() {
        var accumulator = WatchOnDeviceTranscriptAccumulator()

        accumulator.observe(text: "继续执行", isFinal: true)
        accumulator.observe(text: "继续执行", isFinal: true)

        XCTAssertEqual(accumulator.bestText, "继续执行")
    }

    func testEmptyObservationsNeverEraseRecognizedText() {
        var accumulator = WatchOnDeviceTranscriptAccumulator()

        accumulator.observe(text: "保留结果", isFinal: true)
        accumulator.observe(text: "  \n", isFinal: false)

        XCTAssertEqual(accumulator.bestText, "保留结果")
    }
}

final class WatchOnDeviceSpeechLimitsTests: XCTestCase {
    func testExactlyOneMinuteOfPCM16AtSixteenKilohertzIsAccepted() {
        XCTAssertTrue(WatchOnDeviceSpeechLimits.canAppend(
            currentSampleCount: 0,
            newSampleCount: WatchOnDeviceSpeechLimits.maximumSampleCount
        ))
    }

    func testAudioBeyondOneMinuteFailsClosed() {
        XCTAssertFalse(WatchOnDeviceSpeechLimits.canAppend(
            currentSampleCount: WatchOnDeviceSpeechLimits.maximumSampleCount,
            newSampleCount: 1
        ))
    }

    func testInvalidOrOverflowingSampleCountsAreRejected() {
        XCTAssertFalse(WatchOnDeviceSpeechLimits.canAppend(
            currentSampleCount: -1,
            newSampleCount: 1
        ))
        XCTAssertFalse(WatchOnDeviceSpeechLimits.canAppend(
            currentSampleCount: Int.max,
            newSampleCount: 1
        ))
        XCTAssertFalse(WatchOnDeviceSpeechLimits.canAppend(
            currentSampleCount: 0,
            newSampleCount: 0
        ))
    }
}

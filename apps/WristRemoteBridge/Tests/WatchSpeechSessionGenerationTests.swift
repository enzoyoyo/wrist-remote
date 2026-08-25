import Foundation
import Speech
import XCTest
@testable import WristRemoteBridge

final class WatchSpeechLocaleResolverTests: XCTestCase {
    private let supportedIdentifiers: Set<String> = [
        "en-US",
        "zh-CN",
        "zh-HK",
        "zh-TW",
    ]

    func testSimplifiedChineseMacLocaleResolvesToMainlandChinese() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "zh-Hans_US"),
                supportedIdentifiers: supportedIdentifiers
            ),
            "zh-CN"
        )
    }

    func testProductionPreferredLanguageDefaultDoesNotUseEnglishApplicationLocale() {
        let preferred = WatchSpeechLocaleResolver.defaultPreferredLocale(
            preferredLanguageIdentifiers: ["zh-Hans-US", "en-US"]
        )

        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: preferred,
                supportedIdentifiers: supportedIdentifiers
            ),
            "zh-CN"
        )
    }

    func testPreferredLanguageDefaultFallsBackToMainlandChineseWhenListIsEmpty() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.defaultPreferredLocale(
                preferredLanguageIdentifiers: []
            ).identifier,
            "zh-CN"
        )
    }

    func testTraditionalChineseRegionsResolveToTheirSupportedRecognizers() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "zh-Hant_HK"),
                supportedIdentifiers: supportedIdentifiers
            ),
            "zh-HK"
        )
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "zh-Hant_TW"),
                supportedIdentifiers: supportedIdentifiers
            ),
            "zh-TW"
        )
    }

    func testExactSupportedLocaleIsPreservedAcrossSeparatorStyles() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "zh_CN"),
                supportedIdentifiers: supportedIdentifiers
            ),
            "zh-CN"
        )
    }

    func testChineseFallsBackToAnotherChineseRecognizerBeforeEnglish() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "zh-Hans_SG"),
                supportedIdentifiers: ["en-US", "zh-TW"]
            ),
            "zh-TW"
        )
    }

    func testUnsupportedNonChineseLocaleUsesDeterministicEnglishFallback() {
        XCTAssertEqual(
            WatchSpeechLocaleResolver.resolveIdentifier(
                preferred: Locale(identifier: "fr-FR"),
                supportedIdentifiers: ["ja-JP", "en-US"]
            ),
            "en-US"
        )
    }

    @MainActor
    func testRealSpeechRecognizerUsesMainlandChineseForCurrentMacLocaleShape() {
        let transcriber = WatchSpeechTranscriber(
            locale: Locale(identifier: "zh-Hans_US")
        )

        XCTAssertEqual(transcriber.recognitionLocaleIdentifier, "zh-CN")
    }

    @MainActor
    func testNoArgumentRecognizerUsesTheFirstPreferredLanguage() throws {
        let preferred = WatchSpeechLocaleResolver.defaultPreferredLocale()
        let expected = try XCTUnwrap(WatchSpeechLocaleResolver.resolve(
            preferred: preferred,
            supportedLocales: SFSpeechRecognizer.supportedLocales()
        ))
        let transcriber = WatchSpeechTranscriber()

        XCTAssertEqual(
            transcriber.recognitionLocaleIdentifier,
            SFSpeechRecognizer(locale: expected)?.locale.identifier
        )
    }
}

final class WatchSpeechTranscriptBufferTests: XCTestCase {
    func testLatestNonEmptyPartialSurvivesAnEmptyFinalResult() {
        var buffer = WatchSpeechTranscriptBuffer()
        buffer.observe(" 今天天气 ")
        buffer.observe("   \n")

        XCTAssertEqual(buffer.latestNonEmptyText, "今天天气")
        XCTAssertEqual(
            WatchSpeechFinalizationPolicy.outcome(
                rawText: buffer.latestNonEmptyText
            ),
            .text("今天天气")
        )
    }

    func testNewerNonEmptyPartialReplacesTheOlderText() {
        var buffer = WatchSpeechTranscriptBuffer()
        buffer.observe("今天天气")
        buffer.observe("今天天气不错。")

        XCTAssertEqual(buffer.latestNonEmptyText, "今天天气不错。")
    }

    func testEmptyFinalizationProducesAnExplicitFailure() {
        XCTAssertEqual(WatchSpeechFinalizationPolicy.timeoutMilliseconds, 2_500)
        XCTAssertEqual(
            WatchSpeechFinalizationPolicy.outcome(rawText: " \n "),
            .failure(WatchSpeechFinalizationPolicy.emptyTranscriptionMessage)
        )
    }

    func testRecognitionErrorIsPreservedWhenNoPartialTextExists() {
        XCTAssertEqual(
            WatchSpeechFinalizationPolicy.outcome(
                rawText: "",
                error: "Recognition unavailable"
            ),
            .failure("Recognition unavailable")
        )
    }

    func testPartialTextWinsOverAnErrorDuringFinalization() {
        XCTAssertEqual(
            WatchSpeechFinalizationPolicy.outcome(
                rawText: "中文输入",
                error: "Late service error"
            ),
            .text("中文输入")
        )
    }
}

final class WatchSpeechSessionGenerationTests: XCTestCase {
    func testListeningAndFinalizingRejectOverlappingSessions() {
        XCTAssertTrue(WatchSpeechTranscriber.State.idle.acceptsNewSession)
        XCTAssertTrue(WatchSpeechTranscriber.State.failed("retry").acceptsNewSession)
        XCTAssertFalse(WatchSpeechTranscriber.State.listening.acceptsNewSession)
        XCTAssertFalse(WatchSpeechTranscriber.State.finalizing.acceptsNewSession)
    }

    func testLateCallbackFromAAfterBStartsCannotFinishBOrInjectAText() {
        var gate = WatchSpeechSessionGenerationGate()
        let a = gate.start()
        _ = gate.cancel()
        let b = gate.start()
        var injectedTexts: [String] = []

        if gate.finish(a.session, generation: a.generation) {
            injectedTexts.append("old A text")
        }

        XCTAssertEqual(gate.activeSession, b.session)
        XCTAssertTrue(gate.accepts(b.session, generation: b.generation))
        XCTAssertTrue(injectedTexts.isEmpty)
    }

    func testStopAdvancesOnlyCurrentSessionCallbackGeneration() throws {
        var gate = WatchSpeechSessionGenerationGate()
        let a = gate.start()
        let stoppedGeneration = try XCTUnwrap(gate.stop(a.session))

        XCTAssertFalse(gate.accepts(a.session, generation: a.generation))
        XCTAssertTrue(gate.accepts(a.session, generation: stoppedGeneration))
        XCTAssertTrue(gate.finish(a.session, generation: stoppedGeneration))
        XCTAssertNil(gate.activeSession)
    }

    func testCancelInvalidatesAllCallbacksWithoutChangingNewSession() {
        var gate = WatchSpeechSessionGenerationGate()
        let a = gate.start()
        _ = gate.cancel()
        XCTAssertFalse(gate.accepts(a.session, generation: a.generation))
        XCTAssertNil(gate.activeSession)

        let b = gate.start()
        XCTAssertFalse(gate.finish(a.session, generation: a.generation))
        XCTAssertEqual(gate.activeSession, b.session)
    }
}

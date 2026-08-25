import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Speech

struct WatchSpeechLocaleResolver {
    static func defaultPreferredLocale(
        preferredLanguageIdentifiers: [String] = Locale.preferredLanguages
    ) -> Locale {
        for identifier in preferredLanguageIdentifiers {
            let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedIdentifier.isEmpty {
                return Locale(identifier: trimmedIdentifier)
            }
        }
        return Locale(identifier: "zh-CN")
    }

    static func resolve(
        preferred: Locale,
        supportedLocales: Set<Locale>
    ) -> Locale? {
        let supportedIdentifiers = Set(supportedLocales.map(\.identifier))
        guard let resolvedIdentifier = resolveIdentifier(
            preferred: preferred,
            supportedIdentifiers: supportedIdentifiers
        ) else { return nil }

        return supportedLocales.first {
            normalizedIdentifier($0.identifier) == normalizedIdentifier(resolvedIdentifier)
        }
    }

    static func resolveIdentifier(
        preferred: Locale,
        supportedIdentifiers: Set<String>
    ) -> String? {
        var originalByNormalizedIdentifier: [String: String] = [:]
        for identifier in supportedIdentifiers.sorted() {
            let normalized = normalizedIdentifier(identifier)
            if originalByNormalizedIdentifier[normalized] == nil {
                originalByNormalizedIdentifier[normalized] = identifier
            }
        }
        guard !originalByNormalizedIdentifier.isEmpty else { return nil }

        func firstSupported(_ candidates: [String]) -> String? {
            for candidate in candidates {
                if let identifier = originalByNormalizedIdentifier[
                    normalizedIdentifier(candidate)
                ] {
                    return identifier
                }
            }
            return nil
        }

        if let exact = firstSupported([preferred.identifier]) {
            return exact
        }

        let language = preferred.language.languageCode?.identifier.lowercased()
        let script = preferred.language.script?.identifier.lowercased()
        let region = preferred.region?.identifier.uppercased()

        if language == "zh" {
            let candidates: [String]
            if script == "hant" {
                candidates = region == "HK" || region == "MO"
                    ? ["zh-HK", "zh-TW", "zh-CN"]
                    : ["zh-TW", "zh-HK", "zh-CN"]
            } else if region == "HK" || region == "MO" {
                candidates = ["zh-HK", "zh-TW", "zh-CN"]
            } else if region == "TW" {
                candidates = ["zh-TW", "zh-HK", "zh-CN"]
            } else {
                candidates = ["zh-CN", "zh-TW", "zh-HK"]
            }

            if let chinese = firstSupported(candidates) {
                return chinese
            }
        }

        if let language {
            let languagePrefix = "\(language)-"
            if let sameLanguage = originalByNormalizedIdentifier.keys.sorted().first(
                where: { $0 == language || $0.hasPrefix(languagePrefix) }
            ) {
                return originalByNormalizedIdentifier[sameLanguage]
            }
        }

        return firstSupported(["en-US"])
            ?? originalByNormalizedIdentifier.values.sorted().first
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

struct WatchSpeechTranscriptBuffer: Equatable {
    private(set) var latestNonEmptyText = ""

    mutating func observe(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            latestNonEmptyText = text
        }
    }
}

enum WatchSpeechFinalizationOutcome: Equatable {
    case text(String)
    case failure(String)
}

struct WatchSpeechFinalizationPolicy {
    static let timeoutMilliseconds = 2_500
    static let emptyTranscriptionMessage = "没有识别到语音，请再试一次。"

    static func outcome(
        rawText: String,
        error: String? = nil
    ) -> WatchSpeechFinalizationOutcome {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return .text(text)
        }

        let errorText = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(
            errorText.isEmpty ? emptyTranscriptionMessage : errorText
        )
    }
}

struct WatchSpeechSessionGenerationGate: Equatable {
    struct Session: Equatable {
        fileprivate let id: UInt64
    }

    private(set) var generation: UInt64 = 0
    private(set) var activeSession: Session?
    private var nextSessionID: UInt64 = 0

    mutating func start() -> (session: Session, generation: UInt64) {
        generation &+= 1
        nextSessionID &+= 1
        let session = Session(id: nextSessionID)
        activeSession = session
        return (session, generation)
    }

    mutating func stop(_ session: Session?) -> UInt64? {
        generation &+= 1
        guard let session, activeSession == session else { return nil }
        return generation
    }

    @discardableResult
    mutating func cancel() -> UInt64 {
        generation &+= 1
        activeSession = nil
        return generation
    }

    func accepts(_ session: Session, generation: UInt64) -> Bool {
        self.generation == generation && activeSession == session
    }

    mutating func finish(_ session: Session, generation: UInt64) -> Bool {
        guard accepts(session, generation: generation) else { return false }
        activeSession = nil
        return true
    }
}

@MainActor
final class WatchSpeechTranscriber {
    enum State: Equatable {
        case idle
        case listening
        case finalizing
        case failed(String)

        var acceptsNewSession: Bool {
            switch self {
            case .idle, .failed:
                return true
            case .listening, .finalizing:
                return false
            }
        }
    }

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generationGate = WatchSpeechSessionGenerationGate()
    private final class SessionContext {
        let session: WatchSpeechSessionGenerationGate.Session
        var generation: UInt64
        var transcriptBuffer = WatchSpeechTranscriptBuffer()

        init(
            session: WatchSpeechSessionGenerationGate.Session,
            generation: UInt64
        ) {
            self.session = session
            self.generation = generation
        }
    }
    private var sessionContext: SessionContext?
    private var finalizationTimeoutTask: Task<Void, Never>?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private(set) var state: State = .idle
    private(set) var recognitionLocaleIdentifier: String?
    var onStateChange: ((State) -> Void)?
    var onFinalText: ((String) -> Void)?

    convenience init() {
        self.init(locale: WatchSpeechLocaleResolver.defaultPreferredLocale())
    }

    init(locale: Locale) {
        let resolvedLocale = WatchSpeechLocaleResolver.resolve(
            preferred: locale,
            supportedLocales: SFSpeechRecognizer.supportedLocales()
        )
        let recognizer = resolvedLocale.flatMap { SFSpeechRecognizer(locale: $0) }
        self.recognizer = recognizer
        recognitionLocaleIdentifier = recognizer?.locale.identifier
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization(
        _ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    @discardableResult
    func start(requiresAccessibility: Bool = true) -> Bool {
        guard state.acceptsNewSession else { return false }
        cancel()
        let started = generationGate.start()
        let context = SessionContext(
            session: started.session,
            generation: started.generation
        )
        guard Self.authorizationStatus == .authorized,
              (!requiresAccessibility || WatchActionEngine.isAccessibilityTrusted),
              let recognizer,
              recognizer.isAvailable
        else {
            _ = generationGate.finish(context.session, generation: context.generation)
            publishState(
                .failed("需要语音识别与辅助功能权限。"),
                generation: context.generation
            )
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        sessionContext = context
        publishState(.listening, generation: context.generation)
        guard isCurrent(context) else {
            request.endAudio()
            return false
        }
        let recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self, weak context] result, error in
            Task { @MainActor [weak self] in
                guard let self, let context, self.isCurrent(context) else { return }
                if let result {
                    context.transcriptBuffer.observe(
                        result.bestTranscription.formattedString
                    )
                    if result.isFinal {
                        self.finish(
                            context: context,
                            with: context.transcriptBuffer.latestNonEmptyText
                        )
                        return
                    }
                }
                if let error {
                    self.finish(
                        context: context,
                        with: context.transcriptBuffer.latestNonEmptyText,
                        error: error.localizedDescription
                    )
                }
            }
        }
        guard isCurrent(context) else {
            recognitionTask.cancel()
            return false
        }
        task = recognitionTask
        return true
    }

    @discardableResult
    func append(samples: [Int16]) -> Bool {
        guard case .listening = state,
              let sessionContext,
              isCurrent(sessionContext),
              !samples.isEmpty,
              let request,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData?.pointee
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        request.append(buffer)
        return true
    }

    func stop() {
        guard case .listening = state,
              let context = sessionContext,
              let generation = generationGate.stop(context.session)
        else { return }
        context.generation = generation
        publishState(.finalizing, generation: generation)
        request?.endAudio()
        scheduleFinalizationTimeout(for: context)
    }

    func cancel() {
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        let generation = generationGate.cancel()
        let oldTask = task
        task = nil
        request = nil
        sessionContext = nil
        oldTask?.cancel()
        publishState(.idle, generation: generation)
    }

    private func finish(
        context: SessionContext,
        with rawText: String,
        error: String? = nil
    ) {
        let generation = context.generation
        guard isCurrent(context),
              generationGate.finish(context.session, generation: generation)
        else { return }
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        let oldTask = task
        task = nil
        request = nil
        sessionContext = nil
        oldTask?.cancel()
        switch WatchSpeechFinalizationPolicy.outcome(rawText: rawText, error: error) {
        case let .failure(message):
            publishState(.failed(message), generation: generation)
        case let .text(text):
            publishState(.idle, generation: generation)
            guard generationGate.generation == generation else { return }
            onFinalText?(text)
        }
    }

    private func scheduleFinalizationTimeout(for context: SessionContext) {
        finalizationTimeoutTask?.cancel()
        let generation = context.generation
        finalizationTimeoutTask = Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(for: .milliseconds(
                WatchSpeechFinalizationPolicy.timeoutMilliseconds
            ))
            guard let self,
                  let context,
                  !Task.isCancelled,
                  self.isCurrent(context),
                  context.generation == generation,
                  case .finalizing = self.state
            else { return }
            self.finish(
                context: context,
                with: context.transcriptBuffer.latestNonEmptyText
            )
        }
    }

    private func isCurrent(_ context: SessionContext) -> Bool {
        sessionContext === context
            && generationGate.accepts(
                context.session,
                generation: context.generation
            )
    }

    private func publishState(_ newState: State, generation: UInt64) {
        guard generationGate.generation == generation else { return }
        state = newState
        onStateChange?(newState)
    }
}

@MainActor
enum BridgeTextInjector {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
        }
    }

    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard WatchActionEngine.isAccessibilityTrusted,
              !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let injectedChangeCount = pasteboard.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard pasteboard.changeCount == injectedChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }
        return true
    }
}

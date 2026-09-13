import AVFoundation
import Foundation
import Speech

struct WatchOnDeviceSpeechLimits {
    static let sampleRate = 16_000
    static let maximumDurationSeconds = 60
    static let maximumSampleCount = sampleRate * maximumDurationSeconds

    static func canAppend(currentSampleCount: Int, newSampleCount: Int) -> Bool {
        guard currentSampleCount >= 0, newSampleCount > 0,
              currentSampleCount <= maximumSampleCount,
              newSampleCount <= maximumSampleCount - currentSampleCount
        else { return false }
        return true
    }
}

struct WatchOnDeviceTranscriptAccumulator: Equatable {
    private var finalizedSegments: [String] = []
    private var volatileTail = ""

    var bestText: String {
        Self.merge(finalizedText, volatileTail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func observe(text rawText: String, isFinal: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isFinal {
            volatileTail = ""
            let current = finalizedText
            if current == text || current.hasSuffix(text) { return }
            if !current.isEmpty, text.hasPrefix(current) {
                finalizedSegments = [text]
                return
            }
            finalizedSegments.append(text)
        } else {
            volatileTail = text
        }
    }

    private var finalizedText: String {
        finalizedSegments.reduce("") { Self.merge($0, $1) }
    }

    private static func merge(_ leading: String, _ trailing: String) -> String {
        guard !leading.isEmpty else { return trailing }
        guard !trailing.isEmpty else { return leading }
        if trailing.hasPrefix(leading) { return trailing }
        if leading.hasSuffix(trailing) { return leading }
        guard let last = leading.last, let first = trailing.first else {
            return leading + trailing
        }
        let needsSpace = last.isASCII && first.isASCII
            && (last.isLetter || last.isNumber)
            && (first.isLetter || first.isNumber)
        return leading + (needsSpace ? " " : "") + trailing
    }
}

@MainActor
final class WatchOnDeviceSpeechTranscriber {
    private static let finalizationTimeoutMilliseconds = 5_000

    private(set) var state: WatchSpeechTranscriber.State = .idle
    private(set) var recognitionLocaleIdentifier: String?
    var onStateChange: ((WatchSpeechTranscriber.State) -> Void)?
    var onFinalText: ((String) -> Void)?

    private let preferredLocale: Locale
    private var generationGate = WatchSpeechSessionGenerationGate()
    private var isPreparing = false

    @available(macOS 26.0, *)
    private final class SessionContext {
        let session: WatchSpeechSessionGenerationGate.Session
        var generation: UInt64
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var accumulator = WatchOnDeviceTranscriptAccumulator()
        var acceptedSampleCount = 0
        var analysisTask: Task<Void, Never>?
        var resultTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(
            session: WatchSpeechSessionGenerationGate.Session,
            generation: UInt64,
            analyzer: SpeechAnalyzer,
            continuation: AsyncStream<AnalyzerInput>.Continuation
        ) {
            self.session = session
            self.generation = generation
            self.analyzer = analyzer
            self.continuation = continuation
        }
    }

    private var sessionContext: AnyObject?

    convenience init() {
        self.init(locale: Locale(identifier: "zh-CN"))
    }

    init(locale: Locale) {
        preferredLocale = locale
    }

    var acceptsNewSession: Bool {
        state.acceptsNewSession && !isPreparing
    }

    func start() async -> Bool {
        guard acceptsNewSession else { return false }
        cancel()
        isPreparing = true
        let preparationGeneration = generationGate.generation
        defer { isPreparing = false }

        // SpeechAnalyzer transcriber modules are entirely on-device and do not
        // use the SFSpeechRecognizer service. They therefore must not inherit
        // the separate authorization gate used by foreground dictation.
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            publishFailure("这台 Mac 不支持本地实时中文转写。", generation: preparationGeneration)
            return false
        }

        let installedLocales = Set(await SpeechTranscriber.installedLocales)
        guard generationGate.generation == preparationGeneration,
              let locale = WatchSpeechLocaleResolver.resolve(
                  preferred: preferredLocale,
                  supportedLocales: installedLocales
              )
        else {
            publishFailure("本机尚未安装中文离线语音模型。", generation: preparationGeneration)
            return false
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ),
              generationGate.generation == preparationGeneration,
              Self.accepts(format)
        else {
            publishFailure("本机离线语音模型不接受 Watch 音频格式。", generation: preparationGeneration)
            return false
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            publishFailure("本地中文语音模型启动失败。", generation: preparationGeneration)
            return false
        }
        guard generationGate.generation == preparationGeneration else {
            await analyzer.cancelAndFinishNow()
            return false
        }

        let started = generationGate.start()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .unbounded
        )
        let context = SessionContext(
            session: started.session,
            generation: started.generation,
            analyzer: analyzer,
            continuation: continuation
        )
        sessionContext = context
        recognitionLocaleIdentifier = locale.identifier
        publishState(.listening, generation: context.generation)

        context.resultTask = Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                for try await result in transcriber.results {
                    guard self.isCurrent(context) else { return }
                    context.accumulator.observe(
                        text: String(result.text.characters),
                        isFinal: result.isFinal
                    )
                }
            } catch {
                guard self.isCurrent(context) else { return }
                self.finish(context, error: "本地中文转写中断。")
            }
        }

        context.analysisTask = Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                let lastSample = try await analyzer.analyzeSequence(stream)
                guard self.isCurrent(context) else { return }
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                await context.resultTask?.value
                guard self.isCurrent(context) else { return }
                self.finish(context)
            } catch {
                guard self.isCurrent(context) else { return }
                self.finish(context, error: "本地中文转写失败。")
            }
        }
        return true
    }

    @discardableResult
    func append(samples: [Int16]) -> Bool {
        guard #available(macOS 26.0, *),
              case .listening = state,
              let context = sessionContext as? SessionContext,
              isCurrent(context),
              WatchOnDeviceSpeechLimits.canAppend(
                  currentSampleCount: context.acceptedSampleCount,
                  newSampleCount: samples.count
              ),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(WatchOnDeviceSpeechLimits.sampleRate),
                  channels: 1,
                  interleaved: true
              ),
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
        switch context.continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued:
            context.acceptedSampleCount += samples.count
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func stop() {
        guard #available(macOS 26.0, *),
              case .listening = state,
              let context = sessionContext as? SessionContext,
              let generation = generationGate.stop(context.session)
        else { return }
        context.generation = generation
        publishState(.finalizing, generation: generation)
        context.continuation.finish()
        context.timeoutTask?.cancel()
        context.timeoutTask = Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(for: .milliseconds(Self.finalizationTimeoutMilliseconds))
            guard let self, let context,
                  !Task.isCancelled, self.isCurrent(context),
                  case .finalizing = self.state
            else { return }
            await context.analyzer.cancelAndFinishNow()
            self.finish(context, error: "本地中文转写超时。")
        }
    }

    func cancel() {
        isPreparing = false
        let generation = generationGate.cancel()
        if #available(macOS 26.0, *),
           let context = sessionContext as? SessionContext {
            context.continuation.finish()
            context.analysisTask?.cancel()
            context.resultTask?.cancel()
            context.timeoutTask?.cancel()
            Task { await context.analyzer.cancelAndFinishNow() }
        }
        sessionContext = nil
        publishState(.idle, generation: generation)
    }

    @available(macOS 26.0, *)
    private func finish(_ context: SessionContext, error: String? = nil) {
        let generation = context.generation
        guard isCurrent(context),
              generationGate.finish(context.session, generation: generation)
        else { return }
        context.timeoutTask?.cancel()
        context.timeoutTask = nil
        sessionContext = nil
        switch WatchSpeechFinalizationPolicy.outcome(
            rawText: context.accumulator.bestText,
            error: error
        ) {
        case let .failure(message):
            publishState(.failed(message), generation: generation)
        case let .text(text):
            publishState(.idle, generation: generation)
            guard generationGate.generation == generation else { return }
            onFinalText?(text)
        }
    }

    @available(macOS 26.0, *)
    private func isCurrent(_ context: SessionContext) -> Bool {
        sessionContext === context
            && generationGate.accepts(context.session, generation: context.generation)
    }

    private func publishFailure(_ message: String, generation: UInt64) {
        guard generationGate.generation == generation else { return }
        publishState(.failed(message), generation: generation)
    }

    private func publishState(
        _ newState: WatchSpeechTranscriber.State,
        generation: UInt64
    ) {
        guard generationGate.generation == generation else { return }
        state = newState
        onStateChange?(newState)
    }

    @available(macOS 26.0, *)
    private static func accepts(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatInt16
            && format.sampleRate == Double(WatchOnDeviceSpeechLimits.sampleRate)
            && format.channelCount == 1
    }
}

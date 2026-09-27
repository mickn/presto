import AVFoundation
import Speech

/// The audio thread's side: converts buffers to the recognizer's format, feeds them in, and
/// measures loudness for end-of-speech detection. Never touches the main actor directly.
nonisolated final class AudioPump: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat
    private let onLevel: @Sendable (_ rms: Float, _ voiced: Bool) -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var noiseFloor: Float = 0.004

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, targetFormat: AVAudioFormat,
         onLevel: @escaping @Sendable (_ rms: Float, _ voiced: Bool) -> Void) {
        self.continuation = continuation
        self.targetFormat = targetFormat
        self.onLevel = onLevel
    }

    func install(on node: AVAudioInputNode) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in
            process(buffer)
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let rms = Self.rms(buffer)
        let voiced = rms > max(noiseFloor * 3.5, 0.006)
        if !voiced { noiseFloor = noiseFloor * 0.97 + rms * 0.03 }
        onLevel(rms, voiced)
        if let converted = convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() { continuation.finish() }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0 ..< frames { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0 ..< frames {
                let sample = Float(data[i]) / Float(Int16.max)
                sum += sample * sample
            }
        }
        return (sum / Float(frames)).squareRoot()
    }
}

/// Streams speech from the microphone (or a recording, for testing) through `SpeechAnalyzer`
/// with volatile results, so the transcript updates word by word while the person is talking.
///
/// Two recognizers share one analyzer. `DictationTranscriber` drives the live transcript: measured
/// on this Mac it reports a new word every ~250 ms, where `SpeechTranscriber` batches words about
/// once a second. `SpeechTranscriber` is more accurate ("pizza", not "peak"), so its final text is
/// used where exact words matter: searches, web addresses, and text to type.
@MainActor
final class LiveTranscriber {
    enum Source: Equatable {
        case microphone
        /// Played at real-time speed, then followed by silence, exactly like a live speaker.
        case file(URL)
    }

    enum Failure: LocalizedError {
        case unsupportedLanguage, noAudioFormat, microphoneDenied, noMicrophone

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: "Speech recognition doesn't support this language on this Mac."
            case .noAudioFormat: "The speech recognizer didn't offer an audio format."
            case .microphoneDenied: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            case .noMicrophone: "No microphone is connected."
            }
        }
    }

    var onTranscript: (String) -> Void = { _ in }
    /// The speaker went quiet (or the recording ran out).
    var onSpeechEnded: () -> Void = {}
    /// A short pause after some words: a hint that the current clause may be complete.
    var onPause: () -> Void = {}
    var onLevel: (Float) -> Void = { _ in }
    /// Off while the shortcut is held down: releasing it ends the utterance instead.
    var endsOnSilence = true

    private(set) var isRunning = false
    private var analyzer: SpeechAnalyzer?
    private var pump: AudioPump?
    private var audioEngine: AVAudioEngine?
    private var fileTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var accurateTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var accurate: [String] = []
    private var accurateVolatile = ""
    private var pauseReported = true

    private var finalized: [String] = []
    private var volatile = ""
    private var heardVoice = false
    private var started = ContinuousClock.now
    private var lastVoice = ContinuousClock.now
    private var lastChange = ContinuousClock.now
    private var fileEnded: ContinuousClock.Instant?
    private var endReported = false

    /// When the last voiced audio was heard.
    var lastVoiceAt: ContinuousClock.Instant? { heardVoice ? lastVoice : nil }

    var transcript: String {
        (finalized + [volatile]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Setup

    static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    static func makeAccurateTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Picks the Mac's language (falling back to US English) and downloads the model if needed.
    static func prepare() async throws -> Locale {
        let preferred = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        let english = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = preferred ?? english else { throw Failure.unsupportedLanguage }
        let modules: [any SpeechModule] = [makeTranscriber(locale), makeAccurateTranscriber(locale)]
        if await AssetInventory.status(forModules: modules) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        return locale
    }

    static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Running

    func start(source: Source, locale: Locale) async throws {
        await cancel()
        finalized = []
        volatile = ""
        accurate = []
        accurateVolatile = ""
        pauseReported = true
        heardVoice = false
        started = .now
        lastVoice = .now
        lastChange = .now
        fileEnded = nil
        endReported = false

        let transcriber = Self.makeTranscriber(locale)
        let accurateTranscriber = Self.makeAccurateTranscriber(locale)
        let modules: [any SpeechModule] = [transcriber, accurateTranscriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw Failure.noAudioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = AudioPump(continuation: continuation, targetFormat: format) { [weak self] rms, voiced in
            Task { @MainActor in self?.heard(rms: rms, voiced: voiced) }
        }
        self.pump = pump

        // Audio starts before the analyzer is ready; the stream holds it, so no word is lost.
        switch source {
        case .microphone:
            guard await Self.microphoneAccess() else { throw Failure.microphoneDenied }
            let engine = AVAudioEngine()
            guard engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else { throw Failure.noMicrophone }
            pump.install(on: engine.inputNode)
            engine.prepare()
            try engine.start()
            audioEngine = engine
        case let .file(url):
            let file = try AVAudioFile(forReading: url)
            fileTask = Task.detached { [weak self] in
                await Self.play(file, into: pump)
                await MainActor.run { self?.fileEnded = .now }
            }
        }
        isRunning = true

        // Keep the model loaded between utterances so the next one starts instantly.
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.received(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {}
        }
        accurateTask = Task { [weak self] in
            do {
                for try await result in accurateTranscriber.results {
                    self?.receivedAccurate(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {}
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.checkForEnd()
            }
        }
    }

    /// The accurate recognizer's words so far.
    var accurateTranscript: String {
        (accurate + [accurateVolatile]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Stops listening and waits (briefly) for both recognizers' final words.
    func stop() async -> (fast: String, accurate: String) {
        guard isRunning else { return (transcript, accurateTranscript) }
        isRunning = false
        watchdog?.cancel()
        stopAudio()
        pump?.finish()
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            // Return as soon as both recognizers have finalized their words; the analyzer's own
            // shutdown can take a second longer than that.
            let deadline = ContinuousClock.now + .milliseconds(1200)
            while ContinuousClock.now < deadline {
                let fastDone = volatile.isEmpty
                let accurateDone = accurateVolatile.isEmpty && !accurate.isEmpty
                if fastDone && (accurateDone || transcript.isEmpty) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        analyzer = nil
        resultsTask?.cancel()
        accurateTask?.cancel()
        return (transcript, accurateTranscript)
    }

    func cancel() async {
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        watchdog?.cancel()
        stopAudio()
        pump?.finish()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resultsTask?.cancel()
        accurateTask?.cancel()
    }

    private func stopAudio() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        fileTask?.cancel()
        fileTask = nil
    }

    private func received(text: String, isFinal: Bool) {
        guard isRunning || analyzer != nil else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !clean.isEmpty { finalized.append(clean) }
            volatile = ""
        } else {
            volatile = clean
        }
        lastChange = .now
        pauseReported = false
        onTranscript(transcript)
    }

    private func receivedAccurate(text: String, isFinal: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !clean.isEmpty { accurate.append(clean) }
            accurateVolatile = ""
        } else {
            accurateVolatile = clean
        }
    }

    private func heard(rms: Float, voiced: Bool) {
        guard isRunning else { return }
        if voiced {
            heardVoice = true
            lastVoice = .now
        }
        onLevel(rms)
    }

    /// End of speech: a short silence after words, a stalled transcript, or the recording running out.
    private func checkForEnd() {
        guard isRunning, !endReported else { return }
        let now = ContinuousClock.now
        let hasWords = !transcript.isEmpty
        var ended = false
        if let fileEnded, now - fileEnded > .milliseconds(1500) { ended = true }
        if endsOnSilence {
            if heardVoice, hasWords, now - lastVoice > .milliseconds(800) { ended = true }
            if hasWords, now - lastChange > .milliseconds(2000), now - lastVoice > .milliseconds(500) { ended = true }
            if !hasWords, now - started > .seconds(8) { ended = true }
        }
        if now - started > .seconds(30) { ended = true }
        if !ended, !pauseReported, heardVoice, hasWords, now - lastVoice > .milliseconds(300) {
            pauseReported = true
            onPause()
        }
        if ended {
            endReported = true
            onSpeechEnded()
        }
    }

    /// Feeds a recording at real-time speed in 50 ms chunks, then a second of silence.
    nonisolated private static func play(_ file: AVAudioFile, into pump: AudioPump) async {
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.05)
        let clock = ContinuousClock()
        var next = clock.now
        while !Task.isCancelled {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            if buffer.frameLength == 0 { break }
            pump.process(buffer)
            next += .milliseconds(50)
            try? await clock.sleep(until: next)
        }
        for _ in 0 ..< 30 where !Task.isCancelled {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            silence.frameLength = chunk
            for channel in 0 ..< Int(format.channelCount) {
                if let data = silence.floatChannelData?[channel] { data.update(repeating: 0, count: Int(chunk)) }
                if let data = silence.int16ChannelData?[channel] { data.update(repeating: 0, count: Int(chunk)) }
            }
            pump.process(silence)
            next += .milliseconds(50)
            try? await clock.sleep(until: next)
        }
    }
}

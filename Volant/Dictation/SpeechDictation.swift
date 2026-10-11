import AVFoundation
import Foundation
import VolantCore

// Speech has existed since macOS 10.15, so canImport(Speech) is true even on the macOS 15 SDK
// where SpeechAnalyzer, SpeechTranscriber and AnalyzerInput do not exist. FoundationModels only
// ships in the macOS 26 SDK, so it stands in for "this was built against an SDK new enough to see
// those symbols". Without it the whole feature compiles out and reports that it needs macOS 26.
#if canImport(Speech) && canImport(FoundationModels)
import Speech
#endif

/// On-device dictation through Apple's SpeechAnalyzer. Audio never leaves this Mac, the models are
/// system-managed, and the transcript is handed back to the caller rather than written anywhere.
///
/// Speech transcription needs no entitlement of its own, but capturing the microphone does:
/// `com.apple.security.device.audio-input`, plus the usual microphone permission prompt. Both were
/// measured before this was written. The framework is macOS 26 and later while Volant supports
/// macOS 15, so this follows the pattern `AppleFoundationModel` established: absent, not broken.
final class SpeechDictation: ObservableObject {
    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var isReady: Bool { self == .ready }
        var reason: String? { if case .unavailable(let text) = self { return text }; return nil }
    }

    enum DictationError: LocalizedError {
        case noCompatibleAudioFormat
        var errorDescription: String? {
            "This Mac's microphone format cannot be used for dictation."
        }
    }

    enum Phase: Equatable {
        case idle, listening, finishing, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""

    var isListening: Bool { phase == .listening }

    /// Called on the main actor with each finalized phrase, in order, for typing while speaking.
    /// Volatile text that may still change is never passed here.
    var onFinalPhrase: ((String) -> Void)?

    nonisolated static var availability: Availability {
        #if canImport(Speech) && canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unavailable(requiresNewerSystem) }
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("On-device dictation is unavailable on this Mac.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return .unavailable("Microphone access is off. Turn it on in System Settings, Privacy & Security, Microphone.")
        default:
            return .ready
        }
        #else
        return .unavailable(requiresNewerSystem)
        #endif
    }

    private static var requiresNewerSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Dictation needs macOS 26 or later. This Mac runs macOS \(version.majorVersion).\(version.minorVersion)."
    }

    #if canImport(Speech) && canImport(FoundationModels)
    @available(macOS 26.0, *)
    private final class Session {
        let engine = AVAudioEngine()
        var analyzer: SpeechAnalyzer?
        var transcriber: SpeechTranscriber?
        var stream: AsyncStream<AnalyzerInput>.Continuation?
        var collector: Task<Void, Never>?
        var converter: AVAudioConverter?
    }
    private var session: Any?
    #endif

    /// Starts capture. `finished` receives the final transcript, or nil when nothing was said.
    func start(finished: @escaping (String?) -> Void) {
        guard phase != .listening else { return }
        let availability = Self.availability
        guard availability.isReady else {
            phase = .failed(availability.reason ?? "Dictation is unavailable.")
            finished(nil)
            return
        }
        transcript = ""
        #if canImport(Speech) && canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { phase = .failed(Self.requiresNewerSystem); finished(nil); return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard granted else {
                    self.phase = .failed("Dictation needs microphone access.")
                    finished(nil)
                    return
                }
                self.begin(finished: finished)
            }
        }
        #else
        phase = .failed(Self.requiresNewerSystem)
        finished(nil)
        #endif
    }

    #if canImport(Speech) && canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func begin(finished: @escaping (String?) -> Void) {
        let session = Session()
        self.session = session
        phase = .listening
        Task {
            do {
                let locale = await Self.bestLocale()
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults], attributeOptions: [])
                session.transcriber = transcriber
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                session.analyzer = analyzer

                // The microphone runs at the hardware rate, typically 48 kHz, while the analyzer
                // wants its own format, typically 16 kHz. AnalyzerInput traps on a mismatched
                // buffer, and the tap runs on the realtime audio thread where a trap kills the
                // process, so the conversion happens before anything is handed over.
                let inputFormat = session.engine.inputNode.inputFormat(forBus: 0)
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber], considering: inputFormat) else {
                    throw DictationError.noCompatibleAudioFormat
                }
                guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                    throw DictationError.noCompatibleAudioFormat
                }
                session.converter = converter

                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                session.stream = continuation
                session.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    // Nothing in here may trap: this is the realtime audio thread, where a trap
                    // takes the whole process down rather than surfacing as an error.
                    guard let converted = SpeechDictation.convert(buffer, using: converter, to: analyzerFormat)
                    else { return }
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                session.engine.prepare()
                try session.engine.start()
                try await analyzer.start(inputSequence: stream)

                session.collector = Task { @MainActor in
                    // Volatile results refine as you speak, so the newest value replaces the last.
                    var settled = ""
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            if result.isFinal {
                                settled += text
                                self.transcript = settled
                                self.onFinalPhrase?(text)
                            } else {
                                self.transcript = settled + text
                            }
                        }
                    } catch {
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                    self.session = nil
                    finished(nil)
                }
            }
        }
    }
    #endif


    /// Resamples a microphone buffer into the analyzer's format. `AnalyzerInput` traps on a buffer
    /// whose format does not match, and the caller is the realtime audio thread, so this returns
    /// nil for anything it cannot convert rather than raising.
    static func convert(_ buffer: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }

    /// Stops capture and reports the transcript. Safe to call when not listening.
    func stop(finished: @escaping (String?) -> Void) {
        #if canImport(Speech) && canImport(FoundationModels)
        guard #available(macOS 26.0, *), let session = session as? Session, phase == .listening else {
            finished(nil); return
        }
        phase = .finishing
        session.engine.inputNode.removeTap(onBus: 0)
        session.engine.stop()
        session.stream?.finish()
        Task {
            try? await session.analyzer?.finalizeAndFinishThroughEndOfInput()
            _ = await session.collector?.result
            await MainActor.run {
                self.session = nil
                let text = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if case .failed = self.phase {} else { self.phase = .idle }
                finished(text.isEmpty ? nil : text)
            }
        }
        #else
        finished(nil)
        #endif
    }

    func cancel() {
        #if canImport(Speech) && canImport(FoundationModels)
        if #available(macOS 26.0, *), let session = session as? Session {
            session.engine.inputNode.removeTap(onBus: 0)
            session.engine.stop()
            session.stream?.finish()
            session.collector?.cancel()
        }
        session = nil
        #endif
        transcript = ""
        phase = .idle
    }

    #if canImport(Speech) && canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func bestLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) { return current }
        return supported.first { $0.identifier(.bcp47) == "en-US" } ?? current
    }
    #endif
}

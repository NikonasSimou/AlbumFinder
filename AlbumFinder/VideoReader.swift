import AVFoundation
import Speech
import Vision

/// Turns a video into text: what is said (speech) and what is shown (on-screen text).
nonisolated enum VideoReader {
    enum ReadError: LocalizedError {
        case audioExportFailed
        case audioConversionFailed(String)
        case speechNotAllowed

        var errorDescription: String? {
            switch self {
            case .audioExportFailed: "Couldn't read the audio from this video."
            case .audioConversionFailed(let step): "Couldn't prepare the audio for transcription (\(step))."
            case .speechNotAllowed: "Speech recognition is turned off for Album Finder in Settings."
            }
        }
    }

    /// Transcribes the video's audio on-device. Returns "" for videos without sound.
    @concurrent static func transcript(of videoURL: URL) async throws -> String {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return "" }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw ReadError.speechNotAllowed }

        // The speech APIs read audio files, so pull the audio track out into an .m4a first.
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ReadError.audioExportFailed
        }
        let audioURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await export.export(to: audioURL, as: .m4a)

        // Music recommendation videos are almost always in English.
        let locale = Locale(identifier: "en-US")
        // SpeechTranscriber is more accurate but isn't supported everywhere (e.g. the simulator);
        // DictationTranscriber works on any device that supports dictation.
        if SpeechTranscriber.isAvailable {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            return try await run(transcriber, on: audioURL) {
                try await transcriber.results.reduce("") { $0 + String($1.text.characters) }
            }
        } else {
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            return try await run(transcriber, on: audioURL) {
                try await transcriber.results.reduce("") { $0 + String($1.text.characters) }
            }
        }
    }

    private static func run(
        _ module: some SpeechModule, on audioURL: URL, collect: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ReadError.audioConversionFailed("no supported format")
        }
        let audio = try convert(audioURL, to: format)

        let collector = Task { try await collect() }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: audio))
        continuation.finish()
        _ = try await analyzer.analyzeSequence(input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// The analyzer only accepts its own audio format (sample rate, channels), so resample the whole clip.
    private static func convert(_ audioURL: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: audioURL)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ReadError.audioConversionFailed("empty audio")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw ReadError.audioConversionFailed("\(file.processingFormat) to \(format)")
        }
        try file.read(into: source)

        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096) else {
            throw ReadError.audioConversionFailed("output buffer")
        }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return output
    }

    /// Reads text off frames sampled every 1.5 seconds (album titles in overlays, covers, captions).
    @concurrent static func onScreenText(of videoURL: URL) async throws -> [String] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let times = stride(from: 0.5, to: duration, by: 1.5).map { CMTime(seconds: $0, preferredTimescale: 600) }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate

        // The same overlay stays on screen across many frames, so keep each line once.
        var seen = Set<String>()
        var lines: [String] = []
        for await frame in generator.images(for: times) {
            guard let image = try? frame.image else { continue }
            for observation in try await request.perform(on: image) {
                guard let line = observation.topCandidates(1).first?.string, line.count > 1 else { continue }
                if seen.insert(line.lowercased()).inserted {
                    lines.append(line)
                }
            }
        }
        return lines
    }
}

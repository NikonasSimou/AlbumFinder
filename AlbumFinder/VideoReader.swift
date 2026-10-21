import AVFoundation
import Speech
import Vision

/// Turns a video into text: what is said (speech) and what is shown (on-screen text).
nonisolated enum VideoReader {
    enum ReadError: LocalizedError {
        case audioExportFailed
        case speechNotAllowed

        var errorDescription: String? {
            switch self {
            case .audioExportFailed: "Couldn't read the audio from this video."
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
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audioURL), finishAfterFile: true)
        return try await collector.value
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

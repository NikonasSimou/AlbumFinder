import Foundation

/// Picks the albums out of the video's text with Claude, through the Claude API. Only the transcript
/// and the screen text leave the phone, and Claude gets the same instructions as the on-device model.
nonisolated enum ClaudeExtractor {
    enum Model: String, CaseIterable, Identifiable {
        case haiku = "claude-haiku-5-5"
        case sonnet = "claude-sonnet-5-5"
        case opus = "claude-opus-5-5"

        var id: String { rawValue }

        var name: String {
            switch self {
            case .haiku: "Claude Haiku 5.5"
            case .sonnet: "Claude Sonnet 5.5"
            case .opus: "Claude Opus 5.5"
            }
        }

        /// Rough cost of one video, at about 4,000 tokens in and 600 out.
        var detail: String {
            switch self {
            case .haiku: "Fastest and cheapest, well under $0.01 a video"
            case .sonnet: "Smarter, about $0.01 a video"
            case .opus: "Smartest and slowest, about $0.02 a video"
            }
        }
    }

    enum ClaudeError: LocalizedError {
        case noKey
        case rejected(status: Int, message: String)
        case refused
        case unreadableAnswer
        case noAlbums

        var errorDescription: String? {
            switch self {
            case .noKey: "No Claude API key is set"
            case .rejected(let status, let message): "Claude API error \(status): \(message)"
            case .refused: "Claude declined the request"
            case .unreadableAnswer: "Claude's answer couldn't be read"
            case .noAlbums: "Claude found no music in this video, twice"
            }
        }
    }

    /// `onProgress` moves steadily while waiting for the answer, which comes back in one piece, so
    /// iOS doesn't stop the background run as stalled.
    static func albums(
        transcript: String, screen moments: [ScreenMoment], model: Model, apiKey: String?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> (title: String, albums: [AlbumMention], descriptions: [AlbumMention: String]) {
        guard let apiKey, !apiKey.isEmpty else { throw ClaudeError.noKey }
        // Claude's context is far larger than the video's text, so nothing is trimmed.
        let screenText = AlbumExtractor.screenBlocks(moments, transcript: transcript).joined(separator: "\n")
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 8000,
            "system": AlbumExtractor.instructions,
            "messages": [["role": "user", "content": AlbumExtractor.prompt(transcript: transcript, screenText: screenText)]],
            // Low effort kept misheard names even when the screen spelled them right ("Cheerling" for
            // "Shearling"); medium gives Claude room to compare the transcript with the screen.
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model != .haiku {
            // If Sonnet or Opus declines, Anthropic retries on a suitable other model rather than failing.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let ticker = Task { @MainActor in
            var seconds = 0.0
            while !Task.isCancelled {
                onProgress(1 - exp(-seconds / 15))
                try? await Task.sleep(for: .seconds(1))
                seconds += 1
            }
        }
        defer { ticker.cancel() }
        // Haiku sometimes answers with an empty list for a video it gets right on other tries (once in
        // nine on the same video), so ask once more before giving up.
        var reply = try await answer(to: request)
        if reply.albums.isEmpty {
            reply = try await answer(to: request)
        }
        guard !reply.albums.isEmpty else { throw ClaudeError.noAlbums }
        var descriptions: [AlbumMention: String] = [:]
        let albums = reply.albums.prefix(AlbumExtractor.maximumEntries).map { entry in
            let mention = AlbumMention(artist: entry.artist, album: entry.album, kind: RecommendationKind(rawValue: entry.kind) ?? .album)
            let description = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keyed by the cleaned-up entry, as the rest of the run sees it.
            if !description.isEmpty { descriptions[AlbumExtractor.withoutCredit(mention)] = description }
            return mention
        }
        let (title, cleaned) = AlbumExtractor.cleaned(title: reply.title, albums: Array(albums))
        return (title, cleaned, descriptions)
    }

    private static func answer(to request: URLRequest) async throws -> Answer {
        let (data, response) = try await URLSession.shared.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? "no details"
            throw ClaudeError.rejected(status: status, message: message)
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        #if DEBUG
        print("Claude's answer (\(message.stopReason ?? "no stop reason")):", message.content.compactMap(\.text).joined())
        #endif
        if message.stopReason == "refusal" { throw ClaudeError.refused }
        guard message.stopReason != "max_tokens",
              let text = message.content.last(where: { $0.type == "text" })?.text,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)) else {
            throw ClaudeError.unreadableAnswer
        }
        return answer
    }

    /// The answer's shape, matching `AlbumList` for the on-device model. The API guarantees Claude's
    /// answer is valid JSON that follows it.
    private static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "A short title for the video, from its headline text if it has one"],
                "albums": [
                    "type": "array",
                    "description": "Every album, song and artist named in the video, in the order they come up",
                    "items": [
                        "type": "object",
                        "properties": [
                            "artist": ["type": "string", "description": "The artist or band name, correctly spelled. If it isn't said, the artist you know made this album, or empty if you don't know"],
                            "album": ["type": "string", "description": "The album title, or the song title for a song recommendation, correctly spelled. Empty for a band recommendation"],
                            "kind": [
                                "type": "string",
                                "enum": ["album", "song", "artist", "mention"],
                                "description": "album: the person recommends this album. song: they recommend this song. artist: they recommend the artist or band without naming an album. mention: it's only named, e.g. for comparison (\"for fans of\") or in passing",
                            ],
                            "description": [
                                "type": "string",
                                "description": "For a recommendation: one or two short sentences on how the person describes the music, in their own terms: its sound, mood or story, and what they compare it to (\"for fans of …\") if they do. Only what they say: no remarks about what they don't say. Empty for a mention",
                            ],
                        ],
                        "required": ["artist", "album", "kind", "description"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["title", "albums"],
            "additionalProperties": false,
        ]
    }

    private struct Answer: Decodable {
        struct Entry: Decodable {
            let artist: String
            let album: String
            let kind: String
            let description: String
        }

        let title: String
        let albums: [Entry]
    }

    private struct Message: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

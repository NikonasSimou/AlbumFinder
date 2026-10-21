import Foundation
import FoundationModels

@Generable
nonisolated struct AlbumMention: Equatable {
    @Guide(description: "The artist or band name, correctly spelled")
    var artist: String
    @Guide(description: "The album title, correctly spelled")
    var album: String
}

@Generable
nonisolated struct AlbumList {
    @Guide(description: "A short title for the video, from its headline text if it has one, e.g. \"8 Albums You Need This Fall\"")
    var title: String
    @Guide(description: "Every album recommended in the video, in the order they come up")
    var albums: [AlbumMention]
}

/// Uses Apple's on-device language model to pick the recommended albums out of the video's text.
nonisolated enum AlbumExtractor {
    enum ExtractError: LocalizedError {
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason): reason
            }
        }
    }

    static func albums(transcript: String, onScreenText: [String]) async throws -> (title: String, albums: [AlbumMention]) {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ExtractError.modelUnavailable("Turn on Apple Intelligence in Settings to use Album Finder.")
        case .unavailable(.modelNotReady):
            throw ExtractError.modelUnavailable("Apple Intelligence is still downloading. Try again in a few minutes.")
        case .unavailable:
            throw ExtractError.modelUnavailable("This iPhone doesn't support Apple Intelligence.")
        }

        let session = LanguageModelSession(instructions: """
            You find music album recommendations in short social media videos.
            You get a speech transcript, which may contain misheard words, and text read off the screen, \
            which also contains noise such as usernames, watermarks and captions.
            List every album the person recommends, with its artist. Include albums you don't recognize: \
            they may be new releases you don't know yet. Fix spellings of artists and albums that were \
            clearly misheard. Leave out playlists and anything the person clearly calls a song or single.
            Also give the video a short title, using its headline text if it has one.
            """)

        // The on-device model has a small context window, so cap how much on-screen text we send.
        let screenText = onScreenText.prefix(120).joined(separator: "\n")
        let prompt = """
            Speech transcript:
            \(transcript.isEmpty ? "(no speech)" : String(transcript.prefix(4000)))

            Text shown on screen:
            \(screenText.isEmpty ? "(none)" : screenText)
            """

        let response = try await session.respond(to: prompt, generating: AlbumList.self)
        var unique: [AlbumMention] = []
        for mention in response.content.albums where !unique.contains(mention) {
            unique.append(mention)
        }
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "Untitled video" : title, unique)
    }
}

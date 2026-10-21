import Foundation
import FoundationModels

@Generable
nonisolated struct AlbumMention: Equatable {
    @Guide(description: "The artist or band name, correctly spelled. If it isn't said, the artist you know made this album, or empty if you don't know")
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
            they may be new releases you don't know yet. Include albums whose artist is only implied \
            (e.g. "Red, Taylor's Version" is Taylor Swift's album), leaving the artist empty if you can't tell. \
            Fix spellings of artists and albums that were clearly misheard, e.g. "Fortet" is Four Tet. \
            Leave out playlists and anything the person clearly calls a song or single.
            Also give the video a short title, using its headline text if it has one.
            """)

        // The on-device model has a small context window (about 4,000 tokens), so cap the text we send.
        let screenLines = joiningArtistLines(withoutSpokenCaptions(onScreenText, transcript: transcript))
        let screenText = String(screenLines.joined(separator: "\n").prefix(4000))
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

    /// These videos often caption the speech one word at a time ("RIFFS", "FORMULA"). Those lines only
    /// repeat the transcript and can crowd album titles out of the prompt, so drop bare words it contains.
    /// Lines with punctuation stay, e.g. "- Tinashe", which ties an artist to the album above it.
    static func withoutSpokenCaptions(_ lines: [String], transcript: String) -> [String] {
        let spoken = Set(transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return lines.filter { line in
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            let isBareWord = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber }
            return !(isBareWord && spoken.contains(word))
        }
    }

    /// Overlays often show a title with the artist on the next line ("Pugnello" / "- Gilla Band").
    /// Joining them into one line keeps the model from pairing a title with the wrong artist.
    static func joiningArtistLines(_ lines: [String]) -> [String] {
        var joined: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let previous = joined.last, let dash = trimmed.first, "-–—".contains(dash) {
                joined[joined.count - 1] = "\(previous) \(trimmed)"
            } else {
                joined.append(line)
            }
        }
        return joined
    }

    /// The "Title - Artist" overlays, without "12."-style ranking numbers. Overlays don't agree on
    /// which side is the artist, so the lookup should try both.
    static func screenPairs(_ onScreenText: [String], transcript: String) -> [AlbumMention] {
        joiningArtistLines(withoutSpokenCaptions(onScreenText, transcript: transcript)).compactMap { line in
            guard let dash = line.ranges(of: #/\s[-\u{2013}\u{2014}]\s/#).last else { return nil }
            let album = line[..<dash.lowerBound].replacing(#/^\s*\d+\.\s*/#, with: "").trimmingCharacters(in: .whitespaces)
            let artist = line[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !album.isEmpty, !artist.isEmpty else { return nil }
            return AlbumMention(artist: artist, album: album)
        }
    }
}

extension AlbumMention {
    /// Whether the two share an artist or album name (either way round), ignoring case and punctuation.
    nonisolated func overlaps(_ other: AlbumMention) -> Bool {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let names = [key(artist), key(album)].filter { !$0.isEmpty }
        return [key(other.artist), key(other.album)].contains { names.contains($0) }
    }
}

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
    @Guide(description: "A short title for the video, from its headline text if it has one")
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

        let instructions = """
            You find music album recommendations in short social media videos.
            You get a speech transcript, which may contain misheard words, and text read off the screen, \
            which also contains noise such as usernames, watermarks and captions.
            List every album the person recommends, with its artist. Only list albums that come up in this \
            video's transcript or screen text. Include albums you don't recognize: they may be new releases \
            you don't know yet. If the artist is only implied by the album title, give the artist you know \
            made it, or leave the artist empty if you can't tell.
            Fix artist and album names that were clearly misheard. When the screen text spells a name \
            differently from the transcript, use the screen spelling: speech recognition often mishears \
            names, and turns titles in other languages into English-sounding words. On-screen subtitles \
            can break a word, or a name, across two lines.
            Leave out albums mentioned only for comparison or as reference points ("if you like X", \
            "it sounds like X"), even when their cover is shown.
            Include singles, EPs and tracks recommended as releases in their own right, but not songs \
            mentioned as highlights of an album. Leave out playlists.
            Also give the video a short title, using its headline text if it has one.
            """
        let screenText = joiningArtistLines(withoutSpokenCaptions(onScreenText, transcript: transcript)).joined(separator: "\n")
        let prompt = await fittedPrompt(instructions: instructions, transcript: transcript, screenText: screenText)

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: AlbumList.self)
        var unique: [AlbumMention] = []
        for mention in response.content.albums.map(withoutCredit) where !unique.contains(mention) {
            unique.append(mention)
        }
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "Untitled video" : title, unique)
    }

    /// The model sometimes copies a whole overlay as the title ("Magazine by YHWH Nailgun (2026)"),
    /// so drop a trailing year and a trailing "by <the same artist>".
    static func withoutCredit(_ mention: AlbumMention) -> AlbumMention {
        var album = mention.album.replacing(#/\s*\((?:19|20)\d{2}\)\s*$/#, with: "")
        if let by = album.ranges(of: #/\s+by\s+/#.ignoresCase()).last,
           album[by.upperBound...].lowercased().trimmingCharacters(in: .whitespaces) == mention.artist.lowercased() {
            album = String(album[..<by.lowerBound])
        }
        return AlbumMention(artist: mention.artist, album: album)
    }

    /// Whether the artist or album appears anywhere in the video's text, ignoring spaces and punctuation.
    /// The model sometimes makes up an entry, so one that fails this wasn't in the video.
    static func appears(_ mention: AlbumMention, in text: String) -> Bool {
        func letters(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let videoText = letters(text)
        return [mention.artist, mention.album].map(letters).contains { $0.count >= 4 && videoText.contains($0) }
    }

    /// The on-device model's context window (about 4,000 tokens) holds the instructions, the answer
    /// format, the prompt and the answer, so shorten the prompt until it fits with room for a long
    /// answer. Screen text goes first: recommendations are usually spoken, so the transcript matters more.
    static func fittedPrompt(instructions: String, transcript: String, screenText: String) async -> String {
        func prompt(_ transcript: String, _ screenText: String) -> String {
            """
            Speech transcript:
            \(transcript.isEmpty ? "(no speech)" : transcript)

            Text shown on screen:
            \(screenText.isEmpty ? "(none)" : screenText)
            """
        }
        // Counting needs iOS 26.4; before that, estimate about 3 characters per token.
        func tokens(_ text: String) async -> Int {
            guard #available(iOS 26.4, *) else { return text.count / 3 }
            return (try? await SystemLanguageModel.default.tokenCount(for: text)) ?? text.count / 3
        }
        var format = 300
        if #available(iOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: AlbumList.generationSchema) {
            format = count
        }
        let answer = 800  // about 25 albums
        let budget = SystemLanguageModel.default.contextSize - (await tokens(instructions)) - format - answer

        var transcript = transcript, screenText = screenText
        for _ in 0..<6 {
            let candidate = prompt(transcript, screenText)
            let used = await tokens(candidate)
            if used <= budget { return candidate }
            // Cut the overflowing share of characters, plus a little, from screen text, then the transcript.
            let cut = candidate.count * (used - budget) / used + 50
            if !screenText.isEmpty {
                screenText = String(screenText.prefix(max(0, screenText.count - cut)))
            } else {
                transcript = String(transcript.prefix(max(0, transcript.count - cut)))
            }
        }
        return prompt(transcript, screenText)
    }

    /// These videos often caption the speech, one word at a time ("RIFFS", "FORMULA") or as subtitles.
    /// Those lines only repeat the transcript and can crowd album titles out of the prompt, so drop
    /// bare words and longer lines made entirely of words the transcript has. Lines with a dash stay,
    /// e.g. "- Tinashe", which ties an artist to the album above it.
    static func withoutSpokenCaptions(_ lines: [String], transcript: String) -> [String] {
        func words(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let spoken = Set(words(transcript))
        return lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineWords = words(trimmed)
            let isBareWord = lineWords.count == 1 && trimmed.allSatisfy { $0.isLetter || $0.isNumber }
            let isSubtitle = lineWords.count >= 3 && !trimmed.contains(#/\s[-\u{2013}\u{2014}]\s|^[-\u{2013}\u{2014}]/#)
            return !((isBareWord || isSubtitle) && lineWords.allSatisfy(spoken.contains))
        }
    }

    /// Overlays often show a title with the artist on the next line ("Pugnello" / "- Gilla Band").
    /// Joining them into one line keeps the model from pairing a title with the wrong artist.
    static func joiningArtistLines(_ lines: [String]) -> [String] {
        var joined: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isCredit = trimmed.first.map { "-–—".contains($0) } == true || trimmed.lowercased().hasPrefix("by ")
            if let previous = joined.last, isCredit {
                // A credit read twice ("by Emily A. Sprague", "by Enily A. Sprague") only joins once.
                if !previous.contains(#/\s[-\u{2013}\u{2014}]\s|\sby\s/#.ignoresCase()) {
                    joined[joined.count - 1] = "\(previous) \(trimmed)"
                }
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
            let line = line.replacing(#/^\s*\d+\.\s*/#, with: "").replacing(#/\s*\((?:19|20)\d{2}\)\s*$/#, with: "")
            func pair(_ album: Substring, _ artist: Substring) -> AlbumMention? {
                let album = album.trimmingCharacters(in: .whitespaces), artist = artist.trimmingCharacters(in: .whitespaces)
                return album.isEmpty || artist.isEmpty ? nil : AlbumMention(artist: artist, album: album)
            }
            if let dash = line.ranges(of: #/\s[-\u{2013}\u{2014}]\s/#).last {
                return pair(line[..<dash.lowerBound], line[dash.upperBound...])
            }
            // "Title by Artist", kept short so prose ("released by her own label") isn't taken for one.
            guard let by = line.ranges(of: #/\s+by\s+/#.ignoresCase()).last,
                  line[..<by.lowerBound].split(separator: " ").count <= 6,
                  line[by.upperBound...].split(separator: " ").count <= 4
            else { return nil }
            return pair(line[..<by.lowerBound], line[by.upperBound...])
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

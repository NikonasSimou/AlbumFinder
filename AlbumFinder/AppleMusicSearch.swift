import Foundation

nonisolated struct AlbumMatch {
    let mention: AlbumMention
    /// nil when the iTunes catalog had nothing that looked like this album.
    let album: CatalogAlbum?

    /// The album page in Apple Music, or an Apple Music search when there was no confident match.
    var link: URL {
        if let album { return album.url }
        var search = URLComponents(string: "https://music.apple.com/search")!
        search.queryItems = [URLQueryItem(name: "term", value: "\(mention.artist) \(mention.album)")]
        return search.url!
    }
}

nonisolated struct CatalogAlbum: Decodable {
    let artistName: String
    let collectionName: String
    let collectionViewUrl: URL
    let artworkUrl100: URL?
    /// Set on song results: the track, which `collectionName` is the album of.
    let trackName: String?

    /// The API returns 100px artwork; the same URL serves larger sizes.
    var largeArtworkURL: URL? {
        artworkUrl100.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
    }

    /// Song results link to their album with "?i=<track>" appended; drop it to open the album itself.
    var url: URL {
        var components = URLComponents(url: collectionViewUrl, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url ?? collectionViewUrl
    }
}

/// Looks albums up with the public iTunes Search API (no key or developer account needed).
nonisolated enum AppleMusicSearch {
    private struct Response: Decodable {
        let results: [CatalogAlbum]
    }

    static func match(_ mention: AlbumMention) async throws -> AlbumMatch {
        let term = "\(mention.artist) \(mention.album)".trimmingCharacters(in: .whitespaces)
        // Album search only covers albums sold on the iTunes Store. Apple Music-only albums
        // (e.g. Frank Ocean's "Blonde") only show up as the album of a song result.
        async let albums = search(term, entity: "album", limit: 25)
        async let songs = search(term, entity: "song", limit: 25)
        if let best = best(in: try await albums + songs, for: mention) {
            return AlbumMatch(mention: mention, album: best)
        }
        // Combined searches sometimes bury an album (e.g. Nick Drake's "Pink Moon")
        // that a search for just the artist finds.
        if !mention.artist.isEmpty {
            let byArtist = try await search(mention.artist, entity: "album", limit: 200)
            // Within one artist's releases a loosely similar title is safe to accept, which catches
            // foreign titles heard as English words ("Desire Disaster" for "Désir des astres").
            if let best = best(in: byArtist, for: mention) ?? best(in: byArtist, for: mention, looseTitles: true) {
                return AlbumMatch(mention: mention, album: best)
            }
        }
        // Search isn't forgiving about spelling, so a misheard artist ("Poppy Akroyd" for Ackroyd)
        // finds nothing. Searching the title alone still turns it up, and scoring tolerates the artist.
        async let albumsByTitle = search(mention.album, entity: "album", limit: 50)
        async let songsByTitle = search(mention.album, entity: "song", limit: 50)
        let byTitle = try await albumsByTitle + songsByTitle
        return AlbumMatch(mention: mention, album: best(in: byTitle, for: mention, lastResort: true))
    }

    /// The artist's releases, for picking one by its cover when the title didn't match.
    static func releases(by artist: String) async throws -> [CatalogAlbum] {
        try await search(artist, entity: "album", limit: 200).filter { artistSimilarity($0, artist) > 0 }
    }

    /// Search results include tribute albums, karaoke versions and other artists' albums,
    /// so only accept a result whose artist and title both resemble what was mentioned.
    /// On a tie, the earlier result wins: it's ranked higher by Apple.
    private static func best(
        in results: [CatalogAlbum], for mention: AlbumMention, lastResort: Bool = false, looseTitles: Bool = false
    ) -> CatalogAlbum? {
        var best: (album: CatalogAlbum, score: Int)?
        for album in results {
            let score = score(album, against: mention, lastResort: lastResort, looseTitles: looseTitles)
            if score >= 2, score > (best?.score ?? 0) {
                best = (album, score)
            }
        }
        return best?.album
    }

    private static func search(_ term: String, entity: String, limit: Int) async throws -> [CatalogAlbum] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(Response.self, from: data).results
    }

    /// 2 points per field for an exact match, 1 when they're close, and a bonus point when the
    /// title matches word for word, so "Rumours" beats "Rumours (Live)". With no artist, the title
    /// alone decides and Apple's ranking breaks ties.
    /// As a `lastResort`:
    /// - a recommended track (e.g. Poppy Ackroyd's "Continuum") matches the album it's on. Any earlier
    ///   and "Pink Moon" would match a compilation with that song.
    /// - an exact title of four or more words matches whoever the artist is, since the person may be
    ///   named instead of their project (Mark Nelson for Pan•American).
    /// `looseTitles` accepts titles up to about a third different.
    private static func score(_ album: CatalogAlbum, against mention: AlbumMention, lastResort: Bool, looseTitles: Bool) -> Int {
        let trackTitle = lastResort ? album.trackName.map { min(1, similarity($0, mention.album)) } ?? 0 : 0
        var title = max(similarity(album.collectionName, mention.album), trackTitle)
        if title == 0, looseTitles, isClose(album.collectionName, mention.album, tolerance: 3) {
            title = 1
        }
        var artist = mention.artist.isEmpty ? 1 : artistSimilarity(album, mention.artist)
        if artist == 0, lastResort, title == 2, mention.album.split(separator: " ").count >= 4 {
            artist = 1
        }
        // With the exact title, allow a more misheard artist, e.g. "Cocktail Twins" for "Cocteau Twins".
        if artist == 0, title == 2, isClose(album.artistName, mention.artist, tolerance: 3) {
            artist = 1
        }
        guard artist > 0, title > 0 else { return 0 }
        let verbatim = album.collectionName.lowercased() == mention.album.lowercased() ? 1 : 0
        return artist + title + verbatim
    }

    /// Credits like "Fabiano do Nascimento & Vittor Santos e Orquestra" are compared per artist too.
    private static func artistSimilarity(_ album: CatalogAlbum, _ artist: String) -> Int {
        let credited = [album.artistName] + album.artistName.split(separator: #/\s*(?:&|,|\bfeat\.|\bft\.|\bwith\b|\band\b|\be\b|\bx\b)\s*/#).map(String.init)
        return credited.map { similarity($0, artist) }.max() ?? 0
    }

    private static func similarity(_ a: String, _ b: String) -> Int {
        let a = normalized(a), b = normalized(b)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 2 }
        if a.contains(b) || b.contains(a) { return 1 }
        // Tolerate a misheard letter or two, e.g. "Fortet" for "Four Tet".
        return isClose(a, b, tolerance: 5) ? 1 : 0
    }

    /// At most one edit per `tolerance` characters (and at least one) apart.
    private static func isClose(_ a: String, _ b: String, tolerance: Int) -> Bool {
        let a = normalized(a), b = normalized(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return editDistance(a, b) <= max(1, min(a.count, b.count) / tolerance)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let b = Array(b)
        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            for (j, charB) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (charA == charB ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Lowercase, drop accents, "(Deluxe Edition)" and " - Single"-style suffixes, a leading "the", and punctuation.
    private static func normalized(_ s: String) -> String {
        var s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let bracket = s.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            s = String(s[..<bracket])
        }
        for suffix in [" - single", " - ep"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        s = s.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s.replacingOccurrences(of: " ", with: "")
    }
}

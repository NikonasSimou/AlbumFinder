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
        // Album search only covers albums sold on the iTunes Store. Apple Music-only albums
        // (e.g. Frank Ocean's "Blonde") only show up as the album of a song result.
        async let albums = search(mention, entity: "album")
        async let songs = search(mention, entity: "song")
        let results = try await albums + songs

        // Search results include tribute albums, karaoke versions and other artists' albums,
        // so only accept a result whose artist and title both resemble what was mentioned.
        // On a tie, the earlier result wins: it's ranked higher by Apple.
        var best: (album: CatalogAlbum, score: Int)?
        for album in results {
            let score = score(album, against: mention)
            if score >= 2, score > (best?.score ?? 0) {
                best = (album, score)
            }
        }
        return AlbumMatch(mention: mention, album: best?.album)
    }

    private static func search(_ mention: AlbumMention, entity: String) async throws -> [CatalogAlbum] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(mention.artist) \(mention.album)"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(Response.self, from: data).results
    }

    /// 2 points per field for an exact match, 1 when one contains the other, and a bonus point
    /// when the title matches word for word, so "Rumours" beats "Rumours (Live)".
    private static func score(_ album: CatalogAlbum, against mention: AlbumMention) -> Int {
        let artist = similarity(album.artistName, mention.artist)
        let title = similarity(album.collectionName, mention.album)
        guard artist > 0, title > 0 else { return 0 }
        let verbatim = album.collectionName.lowercased() == mention.album.lowercased() ? 1 : 0
        return artist + title + verbatim
    }

    private static func similarity(_ a: String, _ b: String) -> Int {
        let a = normalized(a), b = normalized(b)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 2 }
        return a.contains(b) || b.contains(a) ? 1 : 0
    }

    /// Lowercase, drop "(Deluxe Edition)"-style suffixes, a leading "the", and punctuation.
    private static func normalized(_ s: String) -> String {
        var s = s.lowercased()
        if let bracket = s.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            s = String(s[..<bracket])
        }
        s = s.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s.replacingOccurrences(of: " ", with: "")
    }
}

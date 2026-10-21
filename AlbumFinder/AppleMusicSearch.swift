import Foundation

struct AlbumMatch: Identifiable {
    let id = UUID()
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

    var url: URL { collectionViewUrl }
}

/// Looks albums up with the public iTunes Search API (no key or developer account needed).
nonisolated enum AppleMusicSearch {
    private struct Response: Decodable {
        let results: [CatalogAlbum]
    }

    static func match(_ mention: AlbumMention) async throws -> AlbumMatch {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(mention.artist) \(mention.album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let results = try JSONDecoder().decode(Response.self, from: data).results

        // Search results include tribute albums, karaoke versions and other artists' albums,
        // so only accept a result whose artist and title both resemble what was mentioned.
        let best = results
            .map { ($0, score($0, against: mention)) }
            .filter { $0.1 >= 2 }
            .max { $0.1 < $1.1 }?.0
        return AlbumMatch(mention: mention, album: best)
    }

    /// 2 points per field for an exact match, 1 when one contains the other.
    private static func score(_ album: CatalogAlbum, against mention: AlbumMention) -> Int {
        let artist = similarity(album.artistName, mention.artist)
        let title = similarity(album.collectionName, mention.album)
        guard artist > 0, title > 0 else { return 0 }
        return artist + title
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
